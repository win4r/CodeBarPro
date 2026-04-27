//
//  ProviderProbe.swift
//  CodeBarPro
//

import Darwin
import Foundation

protocol ProviderProbing: Sendable {
    nonisolated func snapshot(for provider: UsageProvider, enabled: Bool) async -> ProviderSnapshot
}

struct LocalProviderProbe: ProviderProbing, Sendable {
    nonisolated func snapshot(for provider: UsageProvider, enabled: Bool) async -> ProviderSnapshot {
        guard enabled else {
            return ProviderSnapshot.placeholder(for: provider, enabled: false)
        }

        guard let executable = CommandLocator.resolve(provider.commandName) else {
            var snapshot = ProviderSnapshot.placeholder(for: provider, enabled: true)
            snapshot.state = .missingCLI(provider.commandName)
            snapshot.updatedAt = Date()
            return snapshot
        }

        let version: String
        do {
            let result = try CommandRunner.run(executable: executable, arguments: ["--version"])
            version = result.trimmedOutput.isEmpty ? "\(provider.commandName) found" : result.trimmedOutput
        } catch {
            var snapshot = ProviderSnapshot.placeholder(for: provider, enabled: true)
            snapshot.state = .failed(error.localizedDescription)
            snapshot.updatedAt = Date()
            return snapshot
        }

        let summary = LocalUsageScanner.scan(provider: provider)
        return Self.makeSnapshot(
            provider: provider,
            enabled: enabled,
            version: version,
            summary: summary)
    }

    private nonisolated static func makeSnapshot(
        provider: UsageProvider,
        enabled: Bool,
        version: String,
        summary: LocalUsageScanner.Summary)
        -> ProviderSnapshot
    {
        let primary: UsageMetric
        let secondary: UsageMetric
        if provider == .codex,
           let rateLimits = summary.rateLimits,
           let primaryLimit = rateLimits.primary,
           let secondaryLimit = rateLimits.secondary
        {
            primary = Self.rateLimitMetric(primaryLimit)
            secondary = Self.rateLimitMetric(secondaryLimit)
        } else {
            primary = Self.metric(
                title: "Today",
                tokens: summary.todayTokens,
                events: summary.todayEvents,
                reset: Calendar.current.startOfNextDay())
            secondary = Self.metric(
                title: "Last 30 days",
                tokens: summary.last30DaysTokens,
                events: summary.last30DaysEvents,
                reset: nil)
        }

        let notes: String?
        if summary.scannedFiles == 0 {
            notes = "No local JSONL activity logs found."
        } else if summary.truncatedFileCount > 0 {
            notes = "Scanned the 1,500 most recent JSONL logs; skipped \(summary.truncatedFileCount) older logs."
        } else if provider == .codex, summary.rateLimits != nil {
            notes = "Tokens: today \(NumberFormat.compactInteger(summary.todayTokens)), last 30 days \(NumberFormat.compactInteger(summary.last30DaysTokens))."
        } else if summary.last30DaysTokens == 0 {
            notes = "Found logs, but no token counters were detected."
        } else {
            notes = nil
        }

        return ProviderSnapshot(
            provider: provider,
            isEnabled: enabled,
            state: .ready(version),
            primary: primary,
            secondary: secondary,
            updatedAt: summary.lastActivity ?? Date(),
            localLogCount: summary.scannedFiles,
            notes: notes)
    }

    private nonisolated static func metric(title: String, tokens: Int, events: Int, reset: Date?) -> UsageMetric {
        if tokens > 0 {
            return UsageMetric(title: title, used: Double(tokens), limit: nil, unit: .tokens, resetsAt: reset)
        }

        return UsageMetric(title: title, used: Double(events), limit: nil, unit: .events, resetsAt: reset)
    }

    private nonisolated static func rateLimitMetric(_ window: LocalUsageScanner.RateLimitWindow) -> UsageMetric {
        UsageMetric(
            title: rateLimitTitle(window.windowMinutes),
            used: window.usedPercent,
            limit: 100,
            unit: .percent,
            resetsAt: window.resetsAt)
    }

    private nonisolated static func rateLimitTitle(_ windowMinutes: Int) -> String {
        switch windowMinutes {
        case 300:
            return "5h limit"
        case 10_080:
            return "Weekly limit"
        case let minutes where minutes % 1_440 == 0:
            return "\(minutes / 1_440)d limit"
        case let minutes where minutes % 60 == 0:
            return "\(minutes / 60)h limit"
        default:
            return "\(windowMinutes)m limit"
        }
    }
}

enum CommandRunError: Error, LocalizedError, Sendable {
    case failed(command: String, exitCode: Int32, output: String)
    case timedOut(command: String, seconds: TimeInterval)

    nonisolated var errorDescription: String? {
        switch self {
        case let .failed(command, exitCode, output):
            let detail = output.isEmpty ? "no output" : output
            return "\(command) exited with code \(exitCode): \(detail)"
        case let .timedOut(command, seconds):
            return "\(command) did not exit within \(NumberFormat.decimal(seconds)) seconds."
        }
    }
}

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    nonisolated var trimmedOutput: String {
        let text = stdout.isEmpty ? stderr : stdout
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommandRunner {
    nonisolated static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 5)
        throws -> CommandResult
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CommandLocator.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let captureQueue = DispatchQueue(
            label: "CodeBarPro.CommandRunner.pipeCapture",
            qos: .utility,
            attributes: .concurrent)
        let stdoutCapture = PipeCapture(fileHandle: stdout.fileHandleForReading)
        let stderrCapture = PipeCapture(fileHandle: stderr.fileHandleForReading)
        stdoutCapture.start(on: captureQueue)
        stderrCapture.start(on: captureQueue)

        do {
            try process.run()
        } catch {
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            _ = stdoutCapture.wait()
            _ = stderrCapture.wait()
            throw error
        }

        guard waitForExit(process, timeout: timeout) else {
            terminate(process)
            throw CommandRunError.timedOut(command: executable, seconds: timeout)
        }

        let stdoutData = stdoutCapture.wait()
        let stderrData = stderrCapture.wait()
        let result = CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self))
        guard result.exitCode == 0 else {
            throw CommandRunError.failed(
                command: executable,
                exitCode: result.exitCode,
                output: result.trimmedOutput)
        }
        return result
    }

    private nonisolated static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = nil
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        guard process.isRunning else { return true }

        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        guard !waitForExit(process, timeout: 0.5), process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, timeout: 0.5)
    }

    private final class PipeCapture: @unchecked Sendable {
        private let fileHandle: FileHandle
        private let group = DispatchGroup()
        private let lock = NSLock()
        nonisolated(unsafe) private var capturedData = Data()

        nonisolated init(fileHandle: FileHandle) {
            self.fileHandle = fileHandle
        }

        nonisolated func start(on queue: DispatchQueue) {
            group.enter()
            queue.async { [self] in
                let data = self.fileHandle.readDataToEndOfFile()
                self.lock.lock()
                self.capturedData = data
                self.lock.unlock()
                self.group.leave()
            }
        }

        nonisolated func wait() -> Data {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return capturedData
        }
    }
}

enum CommandLocator {
    nonisolated static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["HOME"] = home
        environment["PATH"] = searchDirectories().map(\.path).joined(separator: ":")
        return environment
    }

    nonisolated static func resolve(_ command: String) -> String? {
        for directory in searchDirectories() {
            let candidate = directory.appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private nonisolated static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories.append(contentsOf: envPath.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        directories.append(contentsOf: commonShellDirectories())
        directories.append(contentsOf: nodeVersionDirectories())

        var seen = Set<String>()
        return directories.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private nonisolated static func commonShellDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            home.appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    private nonisolated static func nodeVersionDirectories() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        return versions
            .sorted(by: isNewerNodeVersion)
            .map { $0.appendingPathComponent("bin", isDirectory: true) }
    }

    private nonisolated static func isNewerNodeVersion(_ lhs: URL, than rhs: URL) -> Bool {
        let lhsComponents = nodeVersionComponents(lhs.lastPathComponent)
        let rhsComponents = nodeVersionComponents(rhs.lastPathComponent)
        let count = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }

        return lhs.lastPathComponent > rhs.lastPathComponent
    }

    private nonisolated static func nodeVersionComponents(_ version: String) -> [Int] {
        let trimmedVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return trimmedVersion.split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum LocalUsageScanner {
    struct RateLimitWindow: Equatable, Sendable {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
    }

    struct RateLimitSnapshot: Equatable, Sendable {
        var primary: RateLimitWindow?
        var secondary: RateLimitWindow?
        var observedAt: Date
    }

    struct Summary: Equatable, Sendable {
        var todayTokens: Int = 0
        var last30DaysTokens: Int = 0
        var todayEvents: Int = 0
        var last30DaysEvents: Int = 0
        var scannedFiles: Int = 0
        var truncatedFileCount: Int = 0
        var lastActivity: Date?
        var rateLimits: RateLimitSnapshot?

        nonisolated init(
            todayTokens: Int = 0,
            last30DaysTokens: Int = 0,
            todayEvents: Int = 0,
            last30DaysEvents: Int = 0,
            scannedFiles: Int = 0,
            truncatedFileCount: Int = 0,
            lastActivity: Date? = nil,
            rateLimits: RateLimitSnapshot? = nil)
        {
            self.todayTokens = todayTokens
            self.last30DaysTokens = last30DaysTokens
            self.todayEvents = todayEvents
            self.last30DaysEvents = last30DaysEvents
            self.scannedFiles = scannedFiles
            self.truncatedFileCount = truncatedFileCount
            self.lastActivity = lastActivity
            self.rateLimits = rateLimits
        }
    }

    nonisolated static func scan(provider: UsageProvider, now: Date = Date()) -> Summary {
        let roots = logRoots(for: provider)
        return scan(roots: roots, provider: provider, now: now)
    }

    nonisolated static func scan(roots: [URL], now: Date = Date()) -> Summary {
        scan(roots: roots, tokenProvider: nil, now: now)
    }

    nonisolated static func scan(roots: [URL], provider: UsageProvider, now: Date = Date()) -> Summary {
        scan(roots: roots, tokenProvider: provider, now: now)
    }

    private nonisolated static func scan(
        roots: [URL],
        tokenProvider: UsageProvider?,
        now: Date)
        -> Summary
    {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -29, to: now) ?? now
        let searchResult = jsonlFiles(under: roots, modifiedAfter: since)
        var summary = Summary()
        summary.truncatedFileCount = searchResult.truncatedCount
        let cacheScope = tokenProvider?.rawValue ?? "generic"

        for file in searchResult.files {
            summary.scannedFiles += 1
            let fileSummary = summaryCache.summary(for: file, scope: cacheScope) {
                summarize(
                    file.url,
                    provider: tokenProvider,
                    fallbackDate: file.modifiedAt,
                    calendar: calendar,
                    since: since,
                    now: now)
            }
            summary.todayTokens += fileSummary.todayTokens
            summary.last30DaysTokens += fileSummary.last30DaysTokens
            summary.todayEvents += fileSummary.todayEvents
            summary.last30DaysEvents += fileSummary.last30DaysEvents
            summary.lastActivity = latest(summary.lastActivity, fileSummary.lastActivity)
            summary.rateLimits = latestRateLimits(summary.rateLimits, fileSummary.rateLimits)
        }

        return summary
    }

    nonisolated static func tokenTotal(in object: Any, provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            return codexTokenTotal(in: object)
        case .claude:
            return claudeTokenTotal(in: object)
        }
    }

    nonisolated static func tokenTotal(in object: Any) -> Int {
        if let dictionary = object as? [String: Any] {
            if let directTotal = intValue(for: "total_tokens", in: dictionary)
                ?? intValue(for: "totalTokens", in: dictionary)
            {
                return directTotal
            }

            if let usage = preferredUsageObject(in: dictionary) {
                let usageTotal = tokenTotal(in: usage)
                if usageTotal > 0 {
                    return usageTotal
                }
            }

            return dictionary.reduce(0) { partial, element in
                let key = normalizedTokenKey(element.key)
                if tokenKeys.contains(key), let value = intValue(element.value) {
                    return partial + value
                }
                return partial + tokenTotal(in: element.value)
            }
        }

        if let array = object as? [Any] {
            return array.reduce(0) { $0 + tokenTotal(in: $1) }
        }

        return 0
    }

    private nonisolated static func codexTokenTotal(in object: Any) -> Int {
        guard let dictionary = object as? [String: Any],
              let payload = value(forNormalizedKey: "payload", in: dictionary) as? [String: Any],
              let info = value(forNormalizedKey: "info", in: payload) as? [String: Any],
              let lastUsage = value(forNormalizedKey: "lasttokenusage", in: info)
        else {
            return 0
        }

        return tokenTotal(in: lastUsage)
    }

    private nonisolated static func claudeTokenTotal(in object: Any) -> Int {
        guard let dictionary = object as? [String: Any],
              let usage = preferredUsageObject(in: dictionary)
        else {
            return 0
        }

        return tokenTotal(in: usage)
    }

    private nonisolated static func logRoots(for provider: UsageProvider) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .codex:
            return [
                home.appendingPathComponent(".codex", isDirectory: true),
            ]
        case .claude:
            return [
                home.appendingPathComponent(".claude/projects", isDirectory: true),
            ]
        }
    }

    private nonisolated static func summarize(
        _ url: URL,
        provider: UsageProvider?,
        fallbackDate: Date,
        calendar: Calendar,
        since: Date,
        now: Date)
        -> FileSummary
    {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileSummary(lastActivity: fallbackDate)
        }
        defer { try? handle.close() }

        var summary = FileSummary(lastActivity: fallbackDate)
        var lineData = Data()

        while true {
            let chunk = try? handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else { break }

            for byte in chunk {
                if byte == newline || byte == carriageReturn {
                    processLine(
                        lineData,
                        provider: provider,
                        summary: &summary,
                        fallbackDate: fallbackDate,
                        calendar: calendar,
                        since: since,
                        now: now)
                    lineData.removeAll(keepingCapacity: true)
                } else {
                    lineData.append(byte)
                }
            }
        }

        processLine(
            lineData,
            provider: provider,
            summary: &summary,
            fallbackDate: fallbackDate,
            calendar: calendar,
            since: since,
            now: now)

        return summary
    }

    private nonisolated static func processLine(
        _ lineData: Data,
        provider: UsageProvider?,
        summary: inout FileSummary,
        fallbackDate: Date,
        calendar: Calendar,
        since: Date,
        now: Date)
    {
        guard !lineData.isEmpty else { return }
        guard let json = try? JSONSerialization.jsonObject(with: lineData) else { return }
        let eventDate = recordDate(in: json) ?? fallbackDate
        summary.lastActivity = latest(summary.lastActivity, eventDate)
        if provider == .codex,
           let rateLimits = rateLimitSnapshot(in: json, observedAt: eventDate)
        {
            summary.rateLimits = latestRateLimits(summary.rateLimits, rateLimits)
        }
        guard eventDate <= now, eventDate >= since else { return }

        let tokens = provider.map { tokenTotal(in: json, provider: $0) } ?? tokenTotal(in: json)
        summary.last30DaysTokens += tokens
        summary.last30DaysEvents += 1

        if calendar.isDate(eventDate, inSameDayAs: now) {
            summary.todayTokens += tokens
            summary.todayEvents += 1
        }
    }

    private nonisolated static func jsonlFiles(under roots: [URL], modifiedAfter since: Date) -> FileSearchResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var files: [ScannedFile] = []
        var seenPaths = Set<String>()

        func appendIfNeeded(_ file: ScannedFile) {
            let path = file.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seenPaths.insert(path).inserted else { return }
            files.append(file)
        }

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            if root.pathExtension == "jsonl", let file = scannedFile(root, keys: keys, since: since) {
                appendIfNeeded(file)
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let file = scannedFile(url, keys: keys, since: since) else { continue }
                appendIfNeeded(file)
            }
        }

        let sortedFiles = files.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path < $1.url.path
        }
        let selectedFiles = Array(sortedFiles.prefix(maxScannedFiles))
        return FileSearchResult(
            files: selectedFiles,
            truncatedCount: max(0, sortedFiles.count - selectedFiles.count))
    }

    private nonisolated static func scannedFile(_ url: URL, keys: [URLResourceKey], since: Date) -> ScannedFile? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate,
              let byteCount = values.fileSize,
              modifiedAt >= since
        else {
            return nil
        }

        return ScannedFile(url: url, modifiedAt: modifiedAt, byteCount: Int64(byteCount))
    }

    private nonisolated static func recordDate(in object: Any) -> Date? {
        if let dictionary = object as? [String: Any] {
            for key in timestampKeys {
                if let value = value(forNormalizedKey: key, in: dictionary),
                   let date = dateValue(value)
                {
                    return date
                }
            }

            for key in dictionary.keys.sorted() where !timestampKeys.contains(normalizedTokenKey(key)) {
                if let value = dictionary[key], let date = recordDate(in: value) {
                    return date
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let date = recordDate(in: value) {
                    return date
                }
            }
        }

        return nil
    }

    private nonisolated static func dateValue(_ value: Any) -> Date? {
        if let date = value as? Date {
            return date
        }

        if let string = value as? String {
            return parseDateString(string)
        }

        if let number = value as? NSNumber {
            let rawValue = number.doubleValue
            guard rawValue > 1_000_000_000 else { return nil }
            let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        }

        return nil
    }

    private nonisolated static func preferredUsageObject(in dictionary: [String: Any]) -> Any? {
        for key in usageKeys {
            if let value = value(forNormalizedKey: key, in: dictionary) {
                return value
            }
        }

        for key in usageContainerKeys {
            if let nested = value(forNormalizedKey: key, in: dictionary) as? [String: Any],
               let usage = preferredUsageObject(in: nested)
            {
                return usage
            }
        }

        return nil
    }

    private nonisolated static func value(forNormalizedKey normalizedKey: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { normalizedTokenKey($0.key) == normalizedKey }?.value
    }

    private nonisolated static func parseDateString(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for options in isoDateOptions {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in fallbackDateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private nonisolated static func rateLimitSnapshot(in object: Any, observedAt: Date) -> RateLimitSnapshot? {
        guard let dictionary = object as? [String: Any] else { return nil }
        let payload = value(forNormalizedKey: "payload", in: dictionary) as? [String: Any]
        let root = payload ?? dictionary
        guard let rateLimits = value(forNormalizedKey: "ratelimits", in: root) as? [String: Any] else {
            return nil
        }

        let primary = rateLimitWindow(in: value(forNormalizedKey: "primary", in: rateLimits))
        let secondary = rateLimitWindow(in: value(forNormalizedKey: "secondary", in: rateLimits))
        guard primary != nil || secondary != nil else { return nil }
        return RateLimitSnapshot(primary: primary, secondary: secondary, observedAt: observedAt)
    }

    private nonisolated static func rateLimitWindow(in object: Any?) -> RateLimitWindow? {
        guard let dictionary = object as? [String: Any],
              let usedPercentValue = value(forNormalizedKey: "usedpercent", in: dictionary),
              let usedPercent = doubleValue(usedPercentValue),
              let windowMinutesValue = value(forNormalizedKey: "windowminutes", in: dictionary),
              let windowMinutes = intValue(windowMinutesValue)
        else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: value(forNormalizedKey: "resetsat", in: dictionary).flatMap(dateValue))
    }

    private nonisolated static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    private nonisolated static func latestRateLimits(
        _ lhs: RateLimitSnapshot?,
        _ rhs: RateLimitSnapshot?)
        -> RateLimitSnapshot?
    {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs.observedAt >= rhs.observedAt ? lhs : rhs
    }

    private nonisolated static func intValue(for key: String, in dictionary: [String: Any]) -> Int? {
        guard let value = dictionary[key] else { return nil }
        return intValue(value)
    }

    private nonisolated static func intValue(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private nonisolated static func normalizedTokenKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "").lowercased()
    }

    private nonisolated static let tokenKeys: Set<String> = [
        "inputtokens",
        "outputtokens",
        "cachecreationinputtokens",
        "cachereadinputtokens",
        "cachecreationtokens",
        "cachereadtokens",
        "cachedinputtokens",
        "reasoningoutputtokens",
    ]

    private nonisolated static let usageKeys: [String] = [
        "usage",
        "tokenusage",
    ]

    private nonisolated static let usageContainerKeys: [String] = [
        "message",
        "response",
        "result",
        "event",
    ]

    private nonisolated static let timestampKeys: [String] = [
        "timestamp",
        "createdat",
        "updatedat",
        "time",
        "date",
        "ts",
    ]

    private nonisolated static let isoDateOptions: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime, .withFractionalSeconds],
        [.withInternetDateTime],
    ]

    private nonisolated static let fallbackDateFormats: [String] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
    ]

    private struct FileSummary: Sendable {
        var todayTokens: Int = 0
        var last30DaysTokens: Int = 0
        var todayEvents: Int = 0
        var last30DaysEvents: Int = 0
        var lastActivity: Date?
        var rateLimits: RateLimitSnapshot?

        nonisolated init(
            todayTokens: Int = 0,
            last30DaysTokens: Int = 0,
            todayEvents: Int = 0,
            last30DaysEvents: Int = 0,
            lastActivity: Date? = nil,
            rateLimits: RateLimitSnapshot? = nil)
        {
            self.todayTokens = todayTokens
            self.last30DaysTokens = last30DaysTokens
            self.todayEvents = todayEvents
            self.last30DaysEvents = last30DaysEvents
            self.lastActivity = lastActivity
            self.rateLimits = rateLimits
        }
    }

    private struct ScannedFile: Sendable {
        var url: URL
        var modifiedAt: Date
        var byteCount: Int64
    }

    private struct FileSearchResult: Sendable {
        var files: [ScannedFile]
        var truncatedCount: Int
    }

    private final class SummaryCache: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var summaries: [String: CachedFileSummary] = [:]

        nonisolated func summary(for file: ScannedFile, scope: String, load: () -> FileSummary) -> FileSummary {
            let path = file.url.standardizedFileURL.resolvingSymlinksInPath().path
            let key = "\(scope):\(path)"

            lock.lock()
            if let cached = summaries[key],
               cached.modifiedAt == file.modifiedAt,
               cached.byteCount == file.byteCount
            {
                lock.unlock()
                return cached.summary
            }
            lock.unlock()

            let loaded = load()
            guard let currentFile = currentScannedFile(file.url),
                  currentFile.modifiedAt == file.modifiedAt,
                  currentFile.byteCount == file.byteCount
            else {
                return loaded
            }

            lock.lock()
            summaries[key] = CachedFileSummary(
                modifiedAt: currentFile.modifiedAt,
                byteCount: currentFile.byteCount,
                summary: loaded)
            lock.unlock()

            return loaded
        }

        private nonisolated func currentScannedFile(_ url: URL) -> ScannedFile? {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                let byteCount = values.fileSize
            else {
                return nil
            }

            return ScannedFile(url: url, modifiedAt: modifiedAt, byteCount: Int64(byteCount))
        }
    }

    private struct CachedFileSummary: Sendable {
        var modifiedAt: Date
        var byteCount: Int64
        var summary: FileSummary
    }

    private nonisolated static let summaryCache = SummaryCache()
    private nonisolated static let maxScannedFiles = 1_500
    private nonisolated static let newline = UInt8(ascii: "\n")
    private nonisolated static let carriageReturn = UInt8(ascii: "\r")
}
