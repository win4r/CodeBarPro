//
//  ClaudeUsageProbe.swift
//  CodeBarPro
//

import Foundation
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
    private static let serviceName = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let fallbackUserAgentVersion = "2.1.0"
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    nonisolated static func fetchRateLimits(claudeVersion: String?) async -> ProviderRateLimitFetchResult {
        guard let credential = loadCredential() else {
            return .unavailable
        }

        do {
            let usage = try await fetchOAuthUsage(
                accessToken: credential.accessToken,
                claudeVersion: claudeVersion)
            let rateLimits = try rateLimits(from: usage, observedAt: Date())
            return ProviderRateLimitFetchResult(
                rateLimits: rateLimits,
                source: "Claude OAuth",
                failureReason: nil)
        } catch {
            return ProviderRateLimitFetchResult(
                rateLimits: nil,
                source: nil,
                failureReason: error.localizedDescription)
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
            throw ClaudeUsageProbeError.httpStatus(httpResponse.statusCode)
        }

        return try decodeOAuthUsage(data)
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

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        fiveHour = Self.decodeWindow(in: container, keys: ["five_hour"])
        sevenDay = Self.decodeWindow(in: container, keys: ["seven_day"])
        sevenDaySonnet = Self.decodeWindow(in: container, keys: ["seven_day_sonnet"])
        sevenDayOpus = Self.decodeWindow(in: container, keys: ["seven_day_opus"])
    }

    private static func decodeWindow(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = Self.decodeDouble(for: .utilization, in: container)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }

    private static func decodeDouble(
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
    case httpStatus(Int)
    case missingSessionUsage

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Claude usage response was invalid."
        case let .httpStatus(statusCode):
            return "Claude usage endpoint returned HTTP \(statusCode)."
        case .missingSessionUsage:
            return "Claude usage response did not include session usage."
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
