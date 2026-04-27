//
//  ClaudeUsageProbe.swift
//  CodeBarPro
//

import Foundation
import Darwin
import Security
import CommonCrypto

struct ProviderRateLimitFetchResult: Equatable, Sendable {
    var rateLimits: LocalUsageScanner.RateLimitSnapshot?
    var supplementalMetrics: [UsageMetric] = []
    var source: String?
    var failureReason: String?

    nonisolated static var unavailable: ProviderRateLimitFetchResult {
        ProviderRateLimitFetchResult(rateLimits: nil, supplementalMetrics: [], source: nil, failureReason: nil)
    }
}

enum ClaudeUsageProbe {
    enum FallbackSource: Equatable, Sendable {
        case cli
        case web
    }

    nonisolated static let appFallbackSourcesAfterOAuth: [FallbackSource] = [.cli, .web]

    private nonisolated static let serviceName = "Claude Code-credentials"
    private nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private nonisolated static let claudeWebBaseURL = "https://claude.ai/api"
    private nonisolated static let betaHeader = "oauth-2025-04-20"
    private nonisolated static let fallbackUserAgentVersion = "2.1.0"
    private nonisolated static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    private nonisolated static let sessionWindowMinutes = 5 * 60
    private nonisolated static let weeklyWindowMinutes = 7 * 24 * 60
    private nonisolated static let defaultRateLimitBackoff: TimeInterval = 15 * 60
    private nonisolated static let retryAfterUntilDefaultsKey = "claudeOAuthUsageRetryAfterUntil"

    nonisolated static func fetchRateLimits(claudeVersion: String?) async -> ProviderRateLimitFetchResult {
        let now = Date()
        let oauthBackoff = oauthBackoffUntil(now: now)
        var oauthFailure: String?
        var cliFailure: String?
        var webFailure: String?

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
                    supplementalMetrics: supplementalMetrics(from: usage),
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

        for fallbackSource in appFallbackSourcesAfterOAuth {
            switch fallbackSource {
            case .cli:
                do {
                    let rateLimits = try await fetchCLIRateLimits(observedAt: now)
                    return ProviderRateLimitFetchResult(
                        rateLimits: rateLimits,
                        supplementalMetrics: await fetchWebSupplementalMetrics(),
                        source: "Claude CLI /usage",
                        failureReason: nil)
                } catch {
                    cliFailure = error.localizedDescription
                }
            case .web:
                do {
                    let usageResult = try await fetchWebUsageResult(observedAt: now)
                    return ProviderRateLimitFetchResult(
                        rateLimits: usageResult.rateLimits,
                        supplementalMetrics: usageResult.supplementalMetrics,
                        source: "Claude Web",
                        failureReason: nil)
                } catch {
                    webFailure = error.localizedDescription
                }
            }
        }

        let failureReason = [oauthFailure, cliFailure, webFailure]
            .compactMap { $0 }
            .joined(separator: " ")
        return ProviderRateLimitFetchResult(
            rateLimits: nil,
            source: nil,
            failureReason: failureReason.isEmpty ? nil : failureReason)
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
        let modelSpecific = usage.sevenDaySonnet ?? usage.sevenDayOpus
        let modelTitle = usage.sevenDaySonnet == nil && usage.sevenDayOpus != nil
            ? "Opus weekly"
            : "Sonnet weekly"
        let tertiary = rateLimitWindow(
            modelSpecific,
            windowMinutes: weeklyWindowMinutes,
            title: modelTitle)
        return LocalUsageScanner.RateLimitSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
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
        let orderedPercentages = allPercentUsages(in: panel)
        let canInferUnlabeledQuotaWindows = canInferUnlabeledQuotaWindows(in: panel)

        var primaryUsed = percentUsed(
            labelSubstrings: ["Current session"],
            context: context)
        var secondaryUsed = percentUsed(
            labelSubstrings: ["Current week (all models)", "Current week"],
            context: context)
        var modelSpecificUsed = percentUsed(
            labelSubstrings: ["Current week (Opus)", "Current week (Sonnet only)", "Current week (Sonnet)"],
            context: context)

        let hasWeeklyLabel = context.contains("currentweek")
        let hasModelSpecificLabel = context.contains("currentweekopus")
            || context.contains("currentweeksonnet")
        if primaryUsed == nil
            || (hasWeeklyLabel && secondaryUsed == nil)
            || (hasModelSpecificLabel && modelSpecificUsed == nil)
        {
            if primaryUsed == nil, orderedPercentages.indices.contains(0) {
                primaryUsed = orderedPercentages[0]
            }
            if hasWeeklyLabel, secondaryUsed == nil, orderedPercentages.indices.contains(1) {
                secondaryUsed = orderedPercentages[1]
            }
            if hasModelSpecificLabel, modelSpecificUsed == nil, orderedPercentages.indices.contains(2) {
                modelSpecificUsed = orderedPercentages[2]
            }
        }

        guard let primaryUsed else {
            if usageDataStayedLoading(in: clean) {
                throw ClaudeUsageProbeError.cliUsageFailed(
                    "Claude CLI /usage did not return quota percentages; remote usage data stayed loading.")
            }
            throw ClaudeUsageProbeError.cliUsageFailed("Claude CLI /usage did not include Current session.")
        }

        if secondaryUsed == nil,
           !hasWeeklyLabel,
           canInferUnlabeledQuotaWindows,
           orderedPercentages.indices.contains(1)
        {
            secondaryUsed = orderedPercentages[1]
        }
        if modelSpecificUsed == nil,
           !hasModelSpecificLabel,
           canInferUnlabeledQuotaWindows,
           orderedPercentages.indices.contains(2)
        {
            modelSpecificUsed = orderedPercentages[2]
        }

        let modelSpecificTitle = context.contains("currentweekopus")
            ? "Opus weekly"
            : "Sonnet weekly"

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
            tertiary: modelSpecificUsed.map {
                LocalUsageScanner.RateLimitWindow(
                    usedPercent: $0,
                    windowMinutes: weeklyWindowMinutes,
                    resetsAt: resetDate(
                        labelSubstrings: ["Current week (Sonnet only)", "Current week (Sonnet)", "Current week (Opus)"],
                        context: context,
                        now: observedAt),
                    title: modelSpecificTitle)
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
        guard let data = keychainGenericPasswordData(service: serviceName) else {
            return nil
        }
        return credential(from: data)
    }

    private nonisolated static func keychainGenericPasswordData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
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

    private nonisolated static func fetchWebUsageResult(
        observedAt: Date)
        async throws -> (rateLimits: LocalUsageScanner.RateLimitSnapshot, supplementalMetrics: [UsageMetric])
    {
        let cookieHeader = try await Task.detached(priority: .utility) {
            try claudeWebCookieHeader()
        }.value
        let organization = try await fetchWebOrganization(cookieHeader: cookieHeader)
        let usage = try await fetchWebUsage(orgID: organization.id, cookieHeader: cookieHeader)
        var supplemental = supplementalMetrics(from: usage)
        if usage.extraUsageMetric == nil,
           let extraCost = await fetchWebExtraUsageCost(orgID: organization.id, cookieHeader: cookieHeader)
        {
            supplemental.append(extraCost)
        }
        return (try rateLimits(from: usage, observedAt: observedAt), supplemental)
    }

    private nonisolated static func fetchWebSupplementalMetrics() async -> [UsageMetric] {
        do {
            return try await fetchWebUsageResult(observedAt: Date()).supplementalMetrics
        } catch {
            return []
        }
    }

    private nonisolated static func fetchWebOrganization(
        cookieHeader: String)
        async throws -> ClaudeWebOrganization
    {
        guard let url = URL(string: "\(claudeWebBaseURL)/organizations") else {
            throw ClaudeUsageProbeError.invalidResponse
        }

        var request = claudeWebRequest(url: url, cookieHeader: cookieHeader)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageProbeError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let organizations = try JSONDecoder().decode([ClaudeWebOrganization].self, from: data)
            guard let selected = organizations.first(where: { $0.hasChatCapability })
                ?? organizations.first(where: { !$0.isAPIOnly })
                ?? organizations.first
            else {
                throw ClaudeUsageProbeError.webUsageFailed("Claude Web did not return an organization.")
            }
            return selected
        case 401, 403:
            throw ClaudeUsageProbeError.webUsageFailed("Claude Web session is unauthorized or blocked.")
        default:
            throw ClaudeUsageProbeError.webUsageFailed("Claude Web returned HTTP \(httpResponse.statusCode).")
        }
    }

    private nonisolated static func fetchWebUsage(
        orgID: String,
        cookieHeader: String)
        async throws -> ClaudeOAuthUsageResponse
    {
        guard let url = URL(string: "\(claudeWebBaseURL)/organizations/\(orgID)/usage") else {
            throw ClaudeUsageProbeError.invalidResponse
        }

        var request = claudeWebRequest(url: url, cookieHeader: cookieHeader)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageProbeError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try decodeOAuthUsage(data)
        case 401, 403:
            throw ClaudeUsageProbeError.webUsageFailed("Claude Web session is unauthorized or blocked.")
        default:
            throw ClaudeUsageProbeError.webUsageFailed("Claude Web usage returned HTTP \(httpResponse.statusCode).")
        }
    }

    private nonisolated static func fetchWebExtraUsageCost(
        orgID: String,
        cookieHeader: String)
        async -> UsageMetric?
    {
        guard let url = URL(string: "\(claudeWebBaseURL)/organizations/\(orgID)/overage_spend_limit") else {
            return nil
        }

        var request = claudeWebRequest(url: url, cookieHeader: cookieHeader)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }
            return try JSONDecoder().decode(ClaudeOverageSpendLimitResponse.self, from: data).usageMetric
        } catch {
            return nil
        }
    }

    private nonisolated static func claudeWebRequest(url: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        return request
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

    nonisolated static func claudeWebCookieHeader() throws -> String {
        var lastError: String?
        for source in chromiumCookieSources() {
            do {
                let rows = try chromiumCookieRows(in: source.cookieDatabaseURL)
                guard !rows.isEmpty else { continue }
                let safeStoragePassword = keychainGenericPasswordData(service: source.safeStorageService)
                if let header = cookieHeader(from: rows, safeStoragePassword: safeStoragePassword) {
                    return header
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        if let lastError {
            throw ClaudeUsageProbeError.webUsageFailed("Claude browser cookies were not readable: \(lastError)")
        }
        throw ClaudeUsageProbeError.webUsageFailed("No Claude browser session cookie found.")
    }

    nonisolated static func cookieHeader(
        from rows: [ChromiumCookieRow],
        safeStoragePassword: Data?)
        -> String?
    {
        var cookiesByName: [String: String] = [:]
        var orderedNames: [String] = []

        for row in rows {
            guard !row.name.isEmpty else { continue }
            let value: String?
            if !row.value.isEmpty {
                value = row.value
            } else if let safeStoragePassword {
                value = decryptChromiumCookieValue(
                    encryptedHex: row.encryptedValueHex,
                    hostKey: row.hostKey,
                    safeStoragePassword: safeStoragePassword)
            } else {
                value = nil
            }

            guard let value,
                  !value.isEmpty,
                  cookiesByName[row.name] == nil
            else {
                continue
            }
            cookiesByName[row.name] = value
            orderedNames.append(row.name)
        }

        guard let sessionKey = cookiesByName["sessionKey"],
              sessionKey.hasPrefix("sk-ant-")
        else {
            return nil
        }

        let preferredOrder = ["sessionKey", "cf_clearance", "routingHint", "sessionKeyLC"]
        var headerPairs: [String] = []
        var emitted = Set<String>()

        for name in preferredOrder + orderedNames {
            guard !emitted.contains(name),
                  let value = cookiesByName[name]
            else {
                continue
            }
            emitted.insert(name)
            headerPairs.append("\(name)=\(value)")
        }

        return headerPairs.joined(separator: "; ")
    }

    nonisolated static func decryptChromiumCookieValue(
        encryptedHex: String,
        hostKey: String,
        safeStoragePassword: Data)
        -> String?
    {
        guard var encrypted = data(fromHex: encryptedHex),
              !encrypted.isEmpty
        else {
            return nil
        }

        if encrypted.starts(with: Data("v10".utf8)) || encrypted.starts(with: Data("v11".utf8)) {
            encrypted.removeFirst(3)
        }

        guard let key = chromiumEncryptionKey(password: safeStoragePassword),
              let decrypted = aes128CBCDecrypt(
                  encrypted,
                  key: key,
                  iv: Data(repeating: 0x20, count: kCCBlockSizeAES128))
        else {
            return nil
        }

        let hostDigest = sha256(Data(hostKey.utf8))
        let valueData = decrypted.starts(with: hostDigest)
            ? decrypted.dropFirst(hostDigest.count)
            : decrypted[...]

        return String(data: Data(valueData), encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
    }

    private nonisolated static func rateLimitWindow(
        _ window: ClaudeOAuthUsageWindow?,
        windowMinutes: Int,
        title: String? = nil)
        -> LocalUsageScanner.RateLimitWindow?
    {
        guard let usedPercent = window?.utilization else { return nil }
        return LocalUsageScanner.RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: window?.resetsAt.flatMap(parseISO8601Date),
            title: title)
    }

    nonisolated static func supplementalMetrics(from usage: ClaudeOAuthUsageResponse) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        metrics.append(contentsOf: extraRateWindowMetrics(from: usage))
        if let extraUsage = usage.extraUsageMetric {
            metrics.append(extraUsage)
        }
        return metrics
    }

    private nonisolated static func extraRateWindowMetrics(from usage: ClaudeOAuthUsageResponse) -> [UsageMetric] {
        let definitions: [(title: String, window: ClaudeOAuthUsageWindow?, sourceKey: String?)] = [
            ("Designs", usage.sevenDayDesign, usage.sevenDayDesignSourceKey),
            ("Daily Routines", usage.sevenDayRoutines, usage.sevenDayRoutinesSourceKey),
        ]

        return definitions.compactMap { definition in
            if let window = definition.window,
               let usageWindow = rateLimitWindow(
                   window,
                   windowMinutes: weeklyWindowMinutes,
                   title: definition.title)
            {
                return UsageMetric(
                    title: definition.title,
                    used: usageWindow.usedPercent,
                    limit: 100,
                    unit: .percent,
                    resetsAt: usageWindow.resetsAt)
            }

            guard definition.sourceKey != nil else { return nil }
            return UsageMetric(
                title: definition.title,
                used: 0,
                limit: 100,
                unit: .percent,
                resetsAt: nil)
        }
    }

    nonisolated static func normalizeClaudeExtraUsageAmounts(
        used: Double,
        limit: Double)
        -> (used: Double, limit: Double)
    {
        (used: used / 100.0, limit: limit / 100.0)
    }

    nonisolated static func normalizedCurrencyCode(_ code: String?) -> String {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? "USD" : trimmed!.uppercased()
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

    private nonisolated static func allPercentUsages(in text: String) -> [Double] {
        text.components(separatedBy: .newlines).compactMap { line in
            if let value = percentUsed(from: line) {
                return value
            }
            guard !isLikelyStatusContextLine(line),
                  let rawPercent = firstPercent(in: line)
            else {
                return nil
            }
            return max(0, min(100, rawPercent))
        }
    }

    private nonisolated static func canInferUnlabeledQuotaWindows(in text: String) -> Bool {
        let normalized = normalizedForLabelSearch(text)
        return normalized.contains("usagestats")
            && normalized.contains("resets")
            && (normalized.contains("whatscontributingtoyourlimitsusage")
                || normalized.contains("planusage"))
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

    private nonisolated static func usageDataStayedLoading(in text: String) -> Bool {
        let lower = text.lowercased()
        let compact = lower.filter { !$0.isWhitespace }
        return compact.contains("loadingusagedata")
            && (compact.contains("whatscontributingtoyourlimitsusage")
                || compact.contains("scanninglocalsessions")
                || lower.contains("approximate, based on local sessions"))
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

    private nonisolated static func chromiumCookieSources() -> [ChromiumCookieSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let browserRoots: [(label: String, relativePath: String, safeStorageService: String)] = [
            ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
            ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
            ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
            ("Arc", "Arc/User Data", "Arc Safe Storage"),
        ]

        var sources: [ChromiumCookieSource] = []
        var seen = Set<String>()
        for browser in browserRoots {
            let root = applicationSupport.appendingPathComponent(browser.relativePath, isDirectory: true)
            guard let profileURLs = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else {
                continue
            }

            let likelyProfiles = profileURLs.filter { url in
                let name = url.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile"
            }
            for profile in likelyProfiles {
                for relativeCookiePath in ["Network/Cookies", "Cookies"] {
                    let cookieURL = profile.appendingPathComponent(relativeCookiePath, isDirectory: false)
                    guard FileManager.default.fileExists(atPath: cookieURL.path),
                          seen.insert(cookieURL.path).inserted
                    else {
                        continue
                    }
                    sources.append(ChromiumCookieSource(
                        label: "\(browser.label) \(profile.lastPathComponent)",
                        cookieDatabaseURL: cookieURL,
                        safeStorageService: browser.safeStorageService))
                }
            }
        }
        return sources
    }

    private nonisolated static func chromiumCookieRows(in databaseURL: URL) throws -> [ChromiumCookieRow] {
        let query = """
        SELECT host_key || char(31) || name || char(31) || value || char(31) || hex(encrypted_value)
        FROM cookies
        WHERE host_key IN ('claude.ai', '.claude.ai')
        ORDER BY expires_utc DESC
        """

        let result = try CommandRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-batch", "-readonly", databaseURL.path, query],
            timeout: 3)

        return result.stdout
            .components(separatedBy: .newlines)
            .compactMap { line -> ChromiumCookieRow? in
                let parts = line.components(separatedBy: String(UnicodeScalar(31)!))
                guard parts.count == 4 else { return nil }
                return ChromiumCookieRow(
                    hostKey: parts[0],
                    name: parts[1],
                    value: parts[2],
                    encryptedValueHex: parts[3])
            }
    }

    private nonisolated static func chromiumEncryptionKey(password: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        let keyCount = key.count
        let passwordCount = password.count
        let saltCount = salt.count
        let status = key.withUnsafeMutableBytes { keyPointer in
            password.withUnsafeBytes { passwordPointer in
                salt.withUnsafeBytes { saltPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer.bindMemory(to: Int8.self).baseAddress,
                        passwordCount,
                        saltPointer.bindMemory(to: UInt8.self).baseAddress,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyPointer.bindMemory(to: UInt8.self).baseAddress,
                        keyCount)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private nonisolated static func aes128CBCDecrypt(
        _ data: Data,
        key: Data,
        iv: Data)
        -> Data?
    {
        var output = Data(repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outputLength: size_t = 0
        let dataCount = data.count
        let keyCount = key.count
        let outputCapacity = output.count

        let status = output.withUnsafeMutableBytes { outputPointer in
            data.withUnsafeBytes { dataPointer in
                key.withUnsafeBytes { keyPointer in
                    iv.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress,
                            keyCount,
                            ivPointer.baseAddress,
                            dataPointer.baseAddress,
                            dataCount,
                            outputPointer.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private nonisolated static func sha256(_ data: Data) -> Data {
        var digest = Data(repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestPointer in
            data.withUnsafeBytes { dataPointer in
                _ = CC_SHA256(dataPointer.baseAddress, CC_LONG(data.count), digestPointer.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return digest
    }

    private nonisolated static func data(fromHex hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }

        var data = Data()
        data.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

struct ChromiumCookieRow: Equatable, Sendable {
    var hostKey: String
    var name: String
    var value: String
    var encryptedValueHex: String
}

private struct ChromiumCookieSource: Sendable {
    var label: String
    var cookieDatabaseURL: URL
    var safeStorageService: String
}

private struct ClaudeWebOrganization: Decodable, Sendable {
    var uuid: String
    var name: String?
    var capabilities: [String]?

    nonisolated var id: String { uuid }

    nonisolated var hasChatCapability: Bool {
        Set((capabilities ?? []).map { $0.lowercased() }).contains("chat")
    }

    nonisolated var isAPIOnly: Bool {
        let normalized = Set((capabilities ?? []).map { $0.lowercased() })
        return !normalized.isEmpty && normalized == ["api"]
    }
}

private struct LabelSearchContext {
    var lines: [String]
    var normalizedLines: [String]

    nonisolated init(lines: [String]) {
        self.lines = lines
        normalizedLines = lines.map { ClaudeUsageProbe.normalizedForLabelSearch($0) }
    }

    nonisolated func contains(_ needle: String) -> Bool {
        normalizedLines.contains { $0.contains(needle) }
    }
}

private enum ClaudePTYUsageRunner {
    private nonisolated static let command = "/usage\r"
    private nonisolated static let launchArguments = [
        "--setting-sources", "project",
        "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#,
        "--no-chrome",
    ]

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
        process.arguments = launchArguments
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
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                let text = String(decoding: output, as: UTF8.self)
                if !commandSent, commandPromptReady(text) {
                    Thread.sleep(forTimeInterval: 0.3)
                    writeString(command, to: master)
                    commandSent = true
                    lastEnterAt = Date()
                } else if commandSent,
                          Date().timeIntervalSince(lastEnterAt) >= 1.0,
                          commandInputStillFocused(text)
                {
                    writeString("\r", to: master)
                    lastEnterAt = Date()
                }
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

            if !commandSent, elapsed >= 8 {
                writeString(command, to: master)
                commandSent = true
                lastEnterAt = Date()
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
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
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

    private nonisolated static func commandPromptReady(_ text: String) -> Bool {
        let normalized = normalizedTerminalText(text)
        return text.contains("❯")
            || normalized.contains("welcomeback")
            || normalized.contains("forshortcuts")
    }

    private nonisolated static func commandInputStillFocused(_ text: String) -> Bool {
        let normalized = normalizedTerminalText(text)
        return normalized.hasSuffix("/usage")
    }

    private nonisolated static func normalizedTerminalText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression)
            .lowercased()
            .filter { !$0.isWhitespace }
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
    var sevenDayOAuthApps: ClaudeOAuthUsageWindow?
    var sevenDaySonnet: ClaudeOAuthUsageWindow?
    var sevenDayOpus: ClaudeOAuthUsageWindow?
    var sevenDayDesign: ClaudeOAuthUsageWindow?
    var sevenDayRoutines: ClaudeOAuthUsageWindow?
    var sevenDayDesignSourceKey: String?
    var sevenDayRoutinesSourceKey: String?
    var iguanaNecktie: ClaudeOAuthUsageWindow?
    var extraUsage: ClaudeExtraUsage?

    nonisolated var extraUsageMetric: UsageMetric? {
        extraUsage?.usageMetric
    }

    init(
        fiveHour: ClaudeOAuthUsageWindow?,
        sevenDay: ClaudeOAuthUsageWindow?,
        sevenDayOAuthApps: ClaudeOAuthUsageWindow? = nil,
        sevenDaySonnet: ClaudeOAuthUsageWindow? = nil,
        sevenDayOpus: ClaudeOAuthUsageWindow? = nil,
        sevenDayDesign: ClaudeOAuthUsageWindow? = nil,
        sevenDayRoutines: ClaudeOAuthUsageWindow? = nil,
        sevenDayDesignSourceKey: String? = nil,
        sevenDayRoutinesSourceKey: String? = nil,
        iguanaNecktie: ClaudeOAuthUsageWindow? = nil,
        extraUsage: ClaudeExtraUsage? = nil)
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOAuthApps = sevenDayOAuthApps
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.sevenDayDesign = sevenDayDesign
        self.sevenDayRoutines = sevenDayRoutines
        self.sevenDayDesignSourceKey = sevenDayDesignSourceKey
        self.sevenDayRoutinesSourceKey = sevenDayRoutinesSourceKey
        self.iguanaNecktie = iguanaNecktie
        self.extraUsage = extraUsage
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        fiveHour = Self.decodeWindow(in: container, keys: ["five_hour"])
        sevenDay = Self.decodeWindow(in: container, keys: ["seven_day"])
        sevenDayOAuthApps = Self.decodeWindow(in: container, keys: ["seven_day_oauth_apps"])
        sevenDaySonnet = Self.decodeWindow(in: container, keys: ["seven_day_sonnet"])
        sevenDayOpus = Self.decodeWindow(in: container, keys: ["seven_day_opus"])
        let design = Self.decodeWindowWithSource(in: container, keys: [
            "seven_day_design",
            "seven_day_claude_design",
            "claude_design",
            "design",
            "seven_day_omelette",
            "omelette",
            "omelette_promotional",
        ])
        sevenDayDesign = design.window
        sevenDayDesignSourceKey = design.sourceKey
        let routines = Self.decodeWindowWithSource(in: container, keys: [
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ])
        sevenDayRoutines = routines.window
        sevenDayRoutinesSourceKey = routines.sourceKey
        iguanaNecktie = Self.decodeWindow(in: container, keys: ["iguana_necktie"])
        extraUsage = Self.decodeValue(in: container, keys: ["extra_usage"])
    }

    private nonisolated static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String])
        -> ClaudeOAuthUsageWindow?
    {
        decodeValue(in: container, keys: keys)
    }

    private nonisolated static func decodeWindowWithSource(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String])
        -> (window: ClaudeOAuthUsageWindow?, sourceKey: String?)
    {
        var firstNullKey: String?
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            guard container.contains(key) else { continue }
            if let value = try? container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: key) {
                return (value, keyName)
            }
            firstNullKey = firstNullKey ?? keyName
        }
        return (nil, firstNullKey)
    }

    private nonisolated static func decodeValue<T: Decodable>(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String])
        -> T?
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            if let value = try? container.decodeIfPresent(T.self, forKey: key) {
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

struct ClaudeExtraUsage: Decodable, Equatable, Sendable {
    var isEnabled: Bool?
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        monthlyLimit = Self.decodeDouble(for: .monthlyLimit, in: container)
        usedCredits = Self.decodeDouble(for: .usedCredits, in: container)
        utilization = Self.decodeDouble(for: .utilization, in: container)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
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

    nonisolated var usageMetric: UsageMetric? {
        guard isEnabled == true,
              let usedCredits,
              let monthlyLimit
        else {
            return nil
        }
        let normalized = ClaudeUsageProbe.normalizeClaudeExtraUsageAmounts(
            used: usedCredits,
            limit: monthlyLimit)
        return UsageMetric(
            title: "Extra usage",
            used: normalized.used,
            limit: normalized.limit,
            unit: .currency,
            currencyCode: ClaudeUsageProbe.normalizedCurrencyCode(currency),
            resetsAt: nil)
    }
}

struct ClaudeOverageSpendLimitResponse: Decodable, Equatable, Sendable {
    var monthlyCreditLimit: Double?
    var currency: String?
    var usedCredits: Double?
    var isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case monthlyCreditLimit = "monthly_credit_limit"
        case currency
        case usedCredits = "used_credits"
        case isEnabled = "is_enabled"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monthlyCreditLimit = Self.decodeDouble(for: .monthlyCreditLimit, in: container)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
        usedCredits = Self.decodeDouble(for: .usedCredits, in: container)
        isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
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

    nonisolated var usageMetric: UsageMetric? {
        guard isEnabled == true,
              let usedCredits,
              let monthlyCreditLimit,
              let currencyCode = Self.normalizedCurrencyCode(currency)
        else {
            return nil
        }
        let normalized = ClaudeUsageProbe.normalizeClaudeExtraUsageAmounts(
            used: usedCredits,
            limit: monthlyCreditLimit)
        return UsageMetric(
            title: "Extra usage",
            used: normalized.used,
            limit: normalized.limit,
            unit: .currency,
            currencyCode: currencyCode,
            resetsAt: nil)
    }

    private nonisolated static func normalizedCurrencyCode(_ code: String?) -> String? {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed!.uppercased()
    }
}

enum ClaudeUsageProbeError: Error, LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case missingSessionUsage
    case claudeCLINotFound
    case webUsageFailed(String)
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
        case let .webUsageFailed(message):
            return message
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
