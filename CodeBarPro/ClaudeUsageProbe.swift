//
//  ClaudeUsageProbe.swift
//  CodeBarPro
//

import Foundation
import Darwin
import Security

struct ProviderRateLimitFetchResult: Equatable, Sendable {
    var rateLimits: LocalUsageScanner.RateLimitSnapshot?
    var source: String?
    var failureReason: String?

    nonisolated static var unavailable: ProviderRateLimitFetchResult {
        ProviderRateLimitFetchResult(rateLimits: nil, source: nil, failureReason: nil)
    }
}

enum ClaudeUsageProbe {
    private nonisolated static let serviceName = "Claude Code-credentials"
    private nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private nonisolated static let betaHeader = "oauth-2025-04-20"
    private nonisolated static let fallbackUserAgentVersion = "2.1.0"
    private nonisolated static let sessionWindowMinutes = 5 * 60
    private nonisolated static let weeklyWindowMinutes = 7 * 24 * 60
    private nonisolated static let defaultRateLimitBackoff: TimeInterval = 15 * 60
    private nonisolated static let retryAfterUntilDefaultsKey = "claudeOAuthUsageRetryAfterUntil"

    nonisolated static func fetchRateLimits(claudeVersion: String?) async -> ProviderRateLimitFetchResult {
        let now = Date()
        let oauthBackoff = oauthBackoffUntil(now: now)
        var oauthFailure: String?

        if let oauthBackoff {
            oauthFailure = "Claude usage endpoint is rate limited until \(formatTime(oauthBackoff))."
        } else if let credential = loadCredential() {
            do {
                let usage = try await fetchOAuthUsage(
                    accessToken: credential.accessToken,
                    claudeVersion: claudeVersion)
                clearOAuthBackoff()
                let rateLimits = try rateLimits(from: usage, observedAt: now)
                return ProviderRateLimitFetchResult(
                    rateLimits: rateLimits,
                    source: "Claude OAuth",
                    failureReason: nil)
            } catch let error as ClaudeUsageProbeError {
                if case let .httpStatus(statusCode, retryAfter) = error, statusCode == 429 {
                    recordOAuthBackoff(retryAfter: retryAfter, now: now)
                }
                oauthFailure = error.localizedDescription
            } catch {
                oauthFailure = error.localizedDescription
            }
        }

        do {
            let rateLimits = try await fetchCLIRateLimits(observedAt: now)
            return ProviderRateLimitFetchResult(
                rateLimits: rateLimits,
                source: "Claude CLI /usage",
                failureReason: nil)
        } catch {
            let failureReason = [oauthFailure, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: " Claude CLI fallback failed: ")
            return ProviderRateLimitFetchResult(
                rateLimits: nil,
                source: nil,
                failureReason: failureReason.isEmpty ? nil : failureReason)
        }
    }

    nonisolated static func credential(from data: Data) -> ClaudeOAuthCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let root = object["claudeAiOauth"] as? [String: Any] ?? object
        guard let accessToken = stringValue(root["accessToken"] ?? root["access_token"]),
              !accessToken.isEmpty
        else {
            return nil
        }

        return ClaudeOAuthCredential(
            accessToken: accessToken,
            rateLimitTier: stringValue(root["rateLimitTier"] ?? root["rate_limit_tier"]),
            subscriptionType: stringValue(root["subscriptionType"] ?? root["subscription_type"]))
    }

    nonisolated static func decodeOAuthUsage(_ data: Data) throws -> ClaudeOAuthUsageResponse {
        try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
    }

    nonisolated static func rateLimits(
        from usage: ClaudeOAuthUsageResponse,
        observedAt: Date)
        throws -> LocalUsageScanner.RateLimitSnapshot
    {
        guard let primary = rateLimitWindow(usage.fiveHour, windowMinutes: sessionWindowMinutes) else {
            throw ClaudeUsageProbeError.missingSessionUsage
        }

        let secondary = rateLimitWindow(usage.sevenDay, windowMinutes: weeklyWindowMinutes)
        return LocalUsageScanner.RateLimitSnapshot(
            primary: primary,
            secondary: secondary,
            observedAt: observedAt)
    }

    nonisolated static func normalizedClaudeVersion(_ versionString: String?) -> String {
        guard let raw = versionString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return fallbackUserAgentVersion
        }

        let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        return token.isEmpty ? fallbackUserAgentVersion : token
    }

    nonisolated static func rateLimits(
        fromCLIUsageOutput output: String,
        observedAt: Date)
        throws -> LocalUsageScanner.RateLimitSnapshot
    {
        let clean = stripANSICodes(output)
        if let usageError = usageError(in: clean) {
            throw ClaudeUsageProbeError.cliUsageFailed(usageError)
        }

        let panel = latestUsagePanel(in: clean) ?? clean
        let lines = panel.components(separatedBy: .newlines)
        let context = LabelSearchContext(lines: lines)

        guard let primaryUsed = percentUsed(
            labelSubstrings: ["Current session"],
            context: context)
        else {
            throw ClaudeUsageProbeError.cliUsageFailed("Claude CLI /usage did not include Current session.")
        }

        let secondaryUsed = percentUsed(
            labelSubstrings: ["Current week (all models)", "Current week"],
            context: context)

        return LocalUsageScanner.RateLimitSnapshot(
            primary: LocalUsageScanner.RateLimitWindow(
                usedPercent: primaryUsed,
                windowMinutes: sessionWindowMinutes,
                resetsAt: resetDate(
                    labelSubstrings: ["Current session"],
                    context: context,
                    now: observedAt)),
            secondary: secondaryUsed.map {
                LocalUsageScanner.RateLimitWindow(
                    usedPercent: $0,
                    windowMinutes: weeklyWindowMinutes,
                    resetsAt: resetDate(
                        labelSubstrings: ["Current week (all models)", "Current week"],
                        context: context,
                        now: observedAt))
            },
            observedAt: observedAt)
    }

    nonisolated static func retryAfterSeconds(from value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }

    nonisolated static func recordOAuthBackoff(
        retryAfter: TimeInterval?,
        now: Date = Date(),
        userDefaults: UserDefaults = .standard)
    {
        let interval = max(1, retryAfter ?? defaultRateLimitBackoff)
        userDefaults.set(now.addingTimeInterval(interval).timeIntervalSince1970, forKey: retryAfterUntilDefaultsKey)
    }

    nonisolated static func oauthBackoffUntil(
        now: Date = Date(),
        userDefaults: UserDefaults = .standard)
        -> Date?
    {
        let timestamp = userDefaults.double(forKey: retryAfterUntilDefaultsKey)
        guard timestamp > 0 else { return nil }
        let until = Date(timeIntervalSince1970: timestamp)
        guard until > now else {
            userDefaults.removeObject(forKey: retryAfterUntilDefaultsKey)
            return nil
        }
        return until
    }

    private nonisolated static func loadCredential() -> ClaudeOAuthCredential? {
        keychainCredential() ?? fileCredential()
    }

    private nonisolated static func keychainCredential() -> ClaudeOAuthCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return credential(from: data)
    }

    private nonisolated static func fileCredential() -> ClaudeOAuthCredential? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return credential(from: data)
    }

    private nonisolated static func fetchOAuthUsage(
        accessToken: String,
        claudeVersion: String?)
        async throws -> ClaudeOAuthUsageResponse
    {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "claude-code/\(normalizedClaudeVersion(claudeVersion))",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageProbeError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw ClaudeUsageProbeError.httpStatus(
                httpResponse.statusCode,
                retryAfter: retryAfterSeconds(from: httpResponse.value(forHTTPHeaderField: "Retry-After")))
        }

        return try decodeOAuthUsage(data)
    }

    private nonisolated static func fetchCLIRateLimits(
        observedAt: Date,
        timeout: TimeInterval = 14)
        async throws -> LocalUsageScanner.RateLimitSnapshot
    {
        guard let claudeBinary = CommandLocator.resolve("claude") else {
            throw ClaudeUsageProbeError.claudeCLINotFound
        }

        let output = try await ClaudePTYUsageRunner.captureUsage(binary: claudeBinary, timeout: timeout)
        return try rateLimits(fromCLIUsageOutput: output, observedAt: observedAt)
    }

    private nonisolated static func rateLimitWindow(
        _ window: ClaudeOAuthUsageWindow?,
        windowMinutes: Int)
        -> LocalUsageScanner.RateLimitWindow?
    {
        guard let usedPercent = window?.utilization else { return nil }
        return LocalUsageScanner.RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: window?.resetsAt.flatMap(parseISO8601Date))
    }

    private nonisolated static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private nonisolated static func resetDate(
        labelSubstrings: [String],
        context: LabelSearchContext,
        now: Date)
        -> Date?
    {
        for label in labelSubstrings {
            guard let startIndex = context.normalizedLines.firstIndex(where: {
                $0.contains(normalizedForLabelSearch(label))
            }) else {
                continue
            }

            for line in context.lines.dropFirst(startIndex).prefix(14) {
                guard let reset = resetText(in: line) else { continue }
                return parseResetDate(reset, now: now)
            }
        }
        return nil
    }

    private nonisolated static func percentUsed(
        labelSubstrings: [String],
        context: LabelSearchContext)
        -> Double?
    {
        for label in labelSubstrings {
            guard let startIndex = context.normalizedLines.firstIndex(where: {
                $0.contains(normalizedForLabelSearch(label))
            }) else {
                continue
            }

            for line in context.lines.dropFirst(startIndex).prefix(12) {
                if let percent = percentUsed(from: line) {
                    return percent
                }
            }
        }
        return nil
    }

    private nonisolated static func percentUsed(from line: String) -> Double? {
        guard !isLikelyStatusContextLine(line),
              let rawPercent = firstPercent(in: line)
        else {
            return nil
        }

        let clamped = max(0, min(100, rawPercent))
        let lower = line.lowercased()
        let usedKeywords = ["used", "spent", "consumed"]
        let remainingKeywords = ["left", "remaining", "available"]

        if usedKeywords.contains(where: lower.contains) {
            return clamped
        }
        if remainingKeywords.contains(where: lower.contains) {
            return 100 - clamped
        }
        return nil
    }

    private nonisolated static func firstPercent(in line: String) -> Double? {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return Double(line[valueRange])
    }

    private nonisolated static func resetText(in line: String) -> String? {
        guard let range = line.range(of: "Resets", options: [.caseInsensitive]) else { return nil }
        return String(line[range.lowerBound...])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " )")))
    }

    private nonisolated static func parseResetDate(_ text: String, now: Date) -> Date? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let timeZone = extractTimeZone(from: &raw) ?? TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.defaultDate = now

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for format in ["MMM d h:mma", "MMM d h:mm a", "MMM d, h:mma", "MMM d, h:mm a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                components.second = 0
                return calendar.date(from: components)
            }
        }

        for format in ["h:mma", "h:mm a", "HH:mm", "H:mm"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: raw) else { continue }
            let components = calendar.dateComponents([.hour, .minute], from: time)
            guard let anchored = calendar.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: 0,
                of: now)
            else {
                return nil
            }
            return anchored >= now ? anchored : calendar.date(byAdding: .day, value: 1, to: anchored)
        }

        return nil
    }

    private nonisolated static func extractTimeZone(from text: inout String) -> TimeZone? {
        guard let range = text.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return nil }
        let id = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        text.removeSubrange(range)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeZone(identifier: id)
    }

    private nonisolated static func latestUsagePanel(in text: String) -> String? {
        guard let settingsRange = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = text[settingsRange.lowerBound...]
        guard tail.range(of: "Usage", options: .caseInsensitive) != nil else { return nil }
        return String(tail)
    }

    private nonisolated static func usageError(in text: String) -> String? {
        let lower = text.lowercased()
        let compact = lower.filter { !$0.isWhitespace }
        if lower.contains("rate_limit_error") || lower.contains("rate limited") || compact.contains("ratelimited") {
            return "Claude CLI usage endpoint is rate limited right now."
        }
        if lower.contains("authentication_error") {
            return "Claude CLI authentication error. Run `claude login`."
        }
        if lower.contains("token_expired") || lower.contains("token has expired") {
            return "Claude CLI token expired. Run `claude login`."
        }
        if compact.contains("failedtoloadusagedata") || lower.contains("failed to load usage data") {
            return "Claude CLI could not load usage data."
        }
        return nil
    }

    private nonisolated static func stripANSICodes(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    fileprivate nonisolated static func normalizedForLabelSearch(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private nonisolated static func isLikelyStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        return ["opus", "sonnet", "haiku", "default"].contains(where: lower.contains)
    }

    private nonisolated static func clearOAuthBackoff(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: retryAfterUntilDefaultsKey)
    }

    private nonisolated static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

private struct LabelSearchContext {
    var lines: [String]
    var normalizedLines: [String]

    nonisolated init(lines: [String]) {
        self.lines = lines
        normalizedLines = lines.map { ClaudeUsageProbe.normalizedForLabelSearch($0) }
    }
}

private enum ClaudePTYUsageRunner {
    private nonisolated static let command = "/usage\r"

    nonisolated static func captureUsage(binary: String, timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .utility) {
            try captureUsageSynchronously(binary: binary, timeout: timeout)
        }.value
    }

    private nonisolated static func captureUsageSynchronously(binary: String, timeout: TimeInterval) throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw ClaudeUsageProbeError.cliUsageFailed("Could not open PTY.")
        }
        defer {
            if master >= 0 {
                close(master)
            }
        }

        let flags = fcntl(master, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = []
        process.environment = environment()
        process.currentDirectoryURL = probeWorkingDirectoryURL()

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
            try? slaveHandle.close()
        } catch {
            try? slaveHandle.close()
            throw ClaudeUsageProbeError.cliUsageFailed("Could not launch Claude CLI: \(error.localizedDescription)")
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let startedAt = Date()
        var commandSent = false
        var lastEnterAt = Date.distantPast
        var completedAt: Date?

        while Date().timeIntervalSince(startedAt) < timeout {
            let elapsed = Date().timeIntervalSince(startedAt)
            if !commandSent, elapsed >= 0.7 {
                writeString(command, to: master)
                commandSent = true
                lastEnterAt = Date()
            } else if commandSent, Date().timeIntervalSince(lastEnterAt) >= 0.8 {
                writeString("\r", to: master)
                lastEnterAt = Date()
            }

            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                let text = String(decoding: output, as: UTF8.self)
                if looksComplete(text) || looksFailed(text) {
                    if completedAt == nil {
                        completedAt = Date()
                    } else if Date().timeIntervalSince(completedAt!) >= 1.2 {
                        break
                    }
                }
            } else if count == 0 {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }

            if !process.isRunning, commandSent {
                break
            }
            usleep(50_000)
        }

        terminate(process)

        let text = String(decoding: output, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeUsageProbeError.cliUsageFailed("Claude CLI /usage produced no output.")
        }
        return text
    }

    private nonisolated static func writeString(_ string: String, to fileDescriptor: Int32) {
        let bytes = Array(string.utf8)
        _ = bytes.withUnsafeBytes { pointer in
            write(fileDescriptor, pointer.baseAddress, bytes.count)
        }
    }

    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private nonisolated static func environment() -> [String: String] {
        var environment = CommandLocator.environment
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "40"
        return environment
    }

    private nonisolated static func probeWorkingDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = base
            .appendingPathComponent("CodeBarPro", isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return fileManager.temporaryDirectory
        }
    }

    private nonisolated static func looksComplete(_ text: String) -> Bool {
        let lower = text.lowercased()
        let normalized = lower.filter { !$0.isWhitespace }
        let hasUsageLabel = normalized.contains("currentsession")
        let hasPercentMeaning = lower.contains("used")
            || lower.contains("left")
            || lower.contains("remaining")
            || lower.contains("available")
        return hasUsageLabel && lower.contains("%") && hasPercentMeaning
    }

    private nonisolated static func looksFailed(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("failed to load usage data")
            || lower.contains("rate_limit_error")
            || lower.contains("rate limited")
            || lower.contains("authentication_error")
            || lower.contains("token_expired")
    }
}

struct ClaudeOAuthCredential: Equatable, Sendable {
    var accessToken: String
    var rateLimitTier: String?
    var subscriptionType: String?
}

struct ClaudeOAuthUsageResponse: Decodable, Equatable, Sendable {
    var fiveHour: ClaudeOAuthUsageWindow?
    var sevenDay: ClaudeOAuthUsageWindow?
    var sevenDaySonnet: ClaudeOAuthUsageWindow?
    var sevenDayOpus: ClaudeOAuthUsageWindow?

    init(
        fiveHour: ClaudeOAuthUsageWindow?,
        sevenDay: ClaudeOAuthUsageWindow?,
        sevenDaySonnet: ClaudeOAuthUsageWindow? = nil,
        sevenDayOpus: ClaudeOAuthUsageWindow? = nil)
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        fiveHour = Self.decodeWindow(in: container, keys: ["five_hour"])
        sevenDay = Self.decodeWindow(in: container, keys: ["seven_day"])
        sevenDaySonnet = Self.decodeWindow(in: container, keys: ["seven_day_sonnet"])
        sevenDayOpus = Self.decodeWindow(in: container, keys: ["seven_day_opus"])
    }

    private nonisolated static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String])
        -> ClaudeOAuthUsageWindow?
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            if let value = try? container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

struct ClaudeOAuthUsageWindow: Decodable, Equatable, Sendable {
    var utilization: Double?
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = Self.decodeDouble(for: .utilization, in: container)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }

    private nonisolated static func decodeDouble(
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>)
        -> Double?
    {
        if let double = try? container.decodeIfPresent(Double.self, forKey: key) {
            return double
        }
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(int)
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(string)
        }
        return nil
    }
}

enum ClaudeUsageProbeError: Error, LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case missingSessionUsage
    case claudeCLINotFound
    case cliUsageFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Claude usage response was invalid."
        case let .httpStatus(statusCode, _):
            return "Claude usage endpoint returned HTTP \(statusCode)."
        case .missingSessionUsage:
            return "Claude usage response did not include session usage."
        case .claudeCLINotFound:
            return "Claude CLI was not found in PATH."
        case let .cliUsageFailed(message):
            return message
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        return nil
    }
}
