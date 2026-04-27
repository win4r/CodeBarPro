//
//  CodeBarProTests.swift
//  CodeBarProTests
//

import Foundation
import Testing
@testable import CodeBarPro

struct CodeBarProTests {
    @Test func tokenScannerUsesDirectTotalsWhenPresent() {
        let object: [String: Any] = [
            "message": [
                "usage": [
                    "input_tokens": 30,
                    "output_tokens": 12,
                    "total_tokens": 100,
                ],
            ],
        ]

        #expect(LocalUsageScanner.tokenTotal(in: object) == 100)
    }

    @Test func tokenScannerSumsKnownTokenKeys() {
        let object: [String: Any] = [
            "usage": [
                "input_tokens": 30,
                "output_tokens": 12,
                "cache_creation_input_tokens": 8,
                "cache_read_input_tokens": 50,
            ],
        ]

        #expect(LocalUsageScanner.tokenTotal(in: object) == 100)
    }

    @Test func codexScannerUsesLastTokenUsageInsteadOfRunningTotal() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-04-26T12:00:00Z","payload":{"info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":10}}}}
        {"timestamp":"2026-04-26T12:01:00Z","payload":{"info":{"total_token_usage":{"total_tokens":1015},"last_token_usage":{"input_tokens":5,"output_tokens":10}}}}
        """

        try #require(jsonl.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let summary = LocalUsageScanner.scan(roots: [root], provider: .codex, now: now)
        #expect(summary.todayTokens == 25)
        #expect(summary.last30DaysTokens == 25)
    }

    @Test func claudeScannerUsesMessageUsageOnly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-04-26T12:00:00Z","message":{"usage":{"input_tokens":3,"output_tokens":7}},"toolUseResult":{"totalTokens":999}}
        """

        try #require(jsonl.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let summary = LocalUsageScanner.scan(roots: [root], provider: .claude, now: now)
        #expect(summary.todayTokens == 10)
        #expect(summary.last30DaysTokens == 10)
    }

    @Test func numberFormatUsesBillionsForLargeValues() {
        #expect(NumberFormat.compactInteger(19_075_400_000) == "19.1B")
    }

    @Test func codexScannerCapturesLatestRateLimitPercentages() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-04-26T12:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":3,"window_minutes":300,"resets_at":1777269311},"secondary":{"used_percent":1,"window_minutes":10080,"resets_at":1777805182}},"info":{"last_token_usage":{"total_tokens":10}}}}
        {"timestamp":"2026-04-26T12:01:00Z","payload":{"rate_limits":{"primary":{"used_percent":7,"window_minutes":300,"resets_at":1777269311},"secondary":{"used_percent":4,"window_minutes":10080,"resets_at":1777805182}},"info":{"last_token_usage":{"total_tokens":15}}}}
        """

        try #require(jsonl.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let summary = LocalUsageScanner.scan(roots: [root], provider: .codex, now: now)
        #expect(summary.rateLimits?.primary?.usedPercent == 7)
        #expect(summary.rateLimits?.primary?.windowMinutes == 300)
        #expect(summary.rateLimits?.secondary?.usedPercent == 4)
        #expect(summary.rateLimits?.secondary?.windowMinutes == 10_080)
    }

    @Test func claudeCredentialParserReadsNestedOAuthCredential() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-test",
            "refreshToken": "refresh",
            "rateLimitTier": "claude_pro",
            "subscriptionType": "pro"
          }
        }
        """

        let credential = ClaudeUsageProbe.credential(from: try #require(json.data(using: .utf8)))

        #expect(credential?.accessToken == "sk-ant-oat-test")
        #expect(credential?.rateLimitTier == "claude_pro")
        #expect(credential?.subscriptionType == "pro")
    }

    @Test func claudeOAuthUsageMapsSessionAndWeeklyPercentages() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 28.5,
            "resets_at": "2026-04-27T02:00:00Z"
          },
          "seven_day": {
            "utilization": 61,
            "resets_at": "2026-04-30T02:00:00Z"
          }
        }
        """

        let usage = try ClaudeUsageProbe.decodeOAuthUsage(try #require(json.data(using: .utf8)))
        let observedAt = try date("2026-04-27T01:00:00Z")
        let primaryReset = try date("2026-04-27T02:00:00Z")
        let rateLimits = try ClaudeUsageProbe.rateLimits(from: usage, observedAt: observedAt)

        #expect(rateLimits.primary?.usedPercent == 28.5)
        #expect(rateLimits.primary?.windowMinutes == 300)
        #expect(rateLimits.primary?.resetsAt == primaryReset)
        #expect(rateLimits.secondary?.usedPercent == 61)
        #expect(rateLimits.secondary?.windowMinutes == 10_080)
        #expect(rateLimits.observedAt == observedAt)
    }

    @Test func claudeSnapshotPrefersOAuthRateLimitPercentages() {
        let summary = LocalUsageScanner.Summary(
            todayTokens: 1_200_000,
            last30DaysTokens: 2_500_000,
            todayEvents: 3,
            last30DaysEvents: 4,
            scannedFiles: 2)
        let externalRateLimits = ProviderRateLimitFetchResult(
            rateLimits: LocalUsageScanner.RateLimitSnapshot(
                primary: LocalUsageScanner.RateLimitWindow(
                    usedPercent: 28,
                    windowMinutes: 300,
                    resetsAt: nil),
                secondary: LocalUsageScanner.RateLimitWindow(
                    usedPercent: 61,
                    windowMinutes: 10_080,
                    resetsAt: nil),
                observedAt: Date()),
            source: "Claude OAuth",
            failureReason: nil)

        let snapshot = LocalProviderProbe.makeSnapshot(
            provider: .claude,
            enabled: true,
            version: "2.1.119 (Claude Code)",
            summary: summary,
            externalRateLimits: externalRateLimits)

        #expect(snapshot.primary.title == "Session limit")
        #expect(snapshot.primary.formattedValue == "28%")
        #expect(snapshot.primary.percentUsed == 0.28)
        #expect(snapshot.secondary.title == "Weekly limit")
        #expect(snapshot.secondary.formattedValue == "61%")
        #expect(snapshot.notes?.contains("Claude OAuth.") == true)
    }

    @Test func claudeSnapshotUsesSessionPercentageWhenWeeklyUnavailable() {
        let summary = LocalUsageScanner.Summary(
            todayTokens: 1_200,
            last30DaysTokens: 9_800,
            todayEvents: 1,
            last30DaysEvents: 5,
            scannedFiles: 2)
        let externalRateLimits = ProviderRateLimitFetchResult(
            rateLimits: LocalUsageScanner.RateLimitSnapshot(
                primary: LocalUsageScanner.RateLimitWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: nil),
                secondary: nil,
                observedAt: Date()),
            source: "Claude CLI /usage",
            failureReason: nil)

        let snapshot = LocalProviderProbe.makeSnapshot(
            provider: .claude,
            enabled: true,
            version: "2.1.119 (Claude Code)",
            summary: summary,
            externalRateLimits: externalRateLimits)

        #expect(snapshot.primary.title == "Session limit")
        #expect(snapshot.primary.formattedValue == "12%")
        #expect(snapshot.secondary.title == "Last 30 days")
        #expect(snapshot.secondary.formattedValue == "9.8K")
        #expect(snapshot.notes?.contains("Claude CLI /usage.") == true)
    }

    @Test func claudeSnapshotFallsBackToTokenTotalsWhenQuotaUnavailable() {
        let summary = LocalUsageScanner.Summary(
            todayTokens: 1_200,
            last30DaysTokens: 9_800,
            todayEvents: 1,
            last30DaysEvents: 5,
            scannedFiles: 2)
        let externalRateLimits = ProviderRateLimitFetchResult(
            rateLimits: nil,
            source: nil,
            failureReason: "Claude usage endpoint returned HTTP 429.")

        let snapshot = LocalProviderProbe.makeSnapshot(
            provider: .claude,
            enabled: true,
            version: "2.1.119 (Claude Code)",
            summary: summary,
            externalRateLimits: externalRateLimits)

        #expect(snapshot.primary.title == "Today")
        #expect(snapshot.primary.formattedValue == "1.2K")
        #expect(snapshot.secondary.title == "Last 30 days")
        #expect(snapshot.notes == "Claude usage endpoint returned HTTP 429. Showing local token totals.")
    }

    @Test func claudeCLIUsageOutputMapsRemainingPercentages() throws {
        let output = """
        Settings: Usage

        Current session
        92% remaining
        Resets at 7:30 PM

        Current week (all models)
        64% left
        Resets Apr 30 at 10:00 AM
        """
        let observedAt = try date("2026-04-27T18:00:00Z")

        let rateLimits = try ClaudeUsageProbe.rateLimits(fromCLIUsageOutput: output, observedAt: observedAt)

        #expect(rateLimits.primary?.usedPercent == 8)
        #expect(rateLimits.primary?.windowMinutes == 300)
        #expect(rateLimits.secondary?.usedPercent == 36)
        #expect(rateLimits.secondary?.windowMinutes == 10_080)
    }

    @Test func claudeCLIUsageOutputMapsUsedPercentages() throws {
        let output = """
        Current session
        11.5% used

        Current week
        25% consumed
        """

        let rateLimits = try ClaudeUsageProbe.rateLimits(
            fromCLIUsageOutput: output,
            observedAt: try date("2026-04-27T18:00:00Z"))

        #expect(rateLimits.primary?.usedPercent == 11.5)
        #expect(rateLimits.secondary?.usedPercent == 25)
    }

    @Test func claudeOAuthRetryAfterBackoffExpires() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = try date("2026-04-27T18:00:00Z")
        ClaudeUsageProbe.recordOAuthBackoff(retryAfter: 120, now: now, userDefaults: defaults)

        #expect(ClaudeUsageProbe.retryAfterSeconds(from: "120", now: now) == 120)
        #expect(ClaudeUsageProbe.oauthBackoffUntil(now: now, userDefaults: defaults) == now.addingTimeInterval(120))
        #expect(ClaudeUsageProbe.oauthBackoffUntil(
            now: now.addingTimeInterval(121),
            userDefaults: defaults) == nil)
    }

    @Test func percentageMetricsFormatAndProgressCorrectly() {
        let metric = UsageMetric(
            title: "5h limit",
            used: 7,
            limit: 100,
            unit: .percent,
            resetsAt: nil)

        #expect(metric.formattedValue == "7%")
        #expect(metric.percentUsed == 0.07)
    }

    @Test func commandLocatorChecksNVMDirectories() {
        let resolved = CommandLocator.resolve("codex")
        #expect(resolved == nil || resolved?.hasSuffix("/codex") == true)
    }

    @Test func commandRunnerTimesOutBlockedProcesses() throws {
        var didTimeOut = false

        do {
            _ = try CommandRunner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.5)
        } catch CommandRunError.timedOut {
            didTimeOut = true
        }

        #expect(didTimeOut)
    }

    @Test func commandRunnerUsesCliEnvironment() throws {
        let result = try CommandRunner.run(executable: "/usr/bin/env", arguments: [], timeout: 2)
        let lines = result.stdout.split(separator: "\n")
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(lines.contains("HOME=\(home)"))
        #expect(lines.contains { $0.hasPrefix("PATH=") && $0.contains("/usr/bin") })
    }

    @Test func commandRunnerDrainsLargeOutput() throws {
        let result = try CommandRunner.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", "print \"x\" x 200000"],
            timeout: 2)

        #expect(result.stdout.count == 200_000)
    }

    @Test func commandRunnerThrowsOnNonZeroExit() throws {
        var exitCode: Int32?

        do {
            _ = try CommandRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "echo bad >&2; exit 3"],
                timeout: 2)
        } catch CommandRunError.failed(_, let code, _) {
            exitCode = code
        }

        #expect(exitCode == 3)
    }

    @Test func preferencesDefaultToFiveMinuteCadenceWhenUnset() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.refreshCadence == .fiveMinutes)
    }

    @Test func preferencesPreserveEmptyEnabledProviders() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([], forKey: "enabledProviders")

        let preferences = AppPreferences(userDefaults: defaults)
        #expect(preferences.enabledProviders.isEmpty)
    }

    @Test func preferencesPreserveManualCadenceWhenExplicitlyStored() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: defaults)
        preferences.refreshCadence = .manual

        let reloaded = AppPreferences(userDefaults: defaults)
        #expect(reloaded.refreshCadence == .manual)
    }

    @Test func usageScannerBucketsJSONLRecordsByTimestamp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-04-26T12:00:00Z","usage":{"total_tokens":10}}
        {"timestamp":"2026-04-20T12:00:00Z","usage":{"input_tokens":20}}
        """

        try #require(jsonl.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let summary = LocalUsageScanner.scan(roots: [root], now: now)
        #expect(summary.todayTokens == 10)
        #expect(summary.last30DaysTokens == 30)
        #expect(summary.todayEvents == 1)
        #expect(summary.last30DaysEvents == 2)
    }

    @Test func usageScannerDeduplicatesNestedRoots() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionsRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        let file = sessionsRoot.appendingPathComponent("session.jsonl")
        let jsonl = #"{"timestamp":"2026-04-26T12:00:00Z","usage":{"total_tokens":42}}"#
        try #require(jsonl.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let summary = LocalUsageScanner.scan(roots: [sessionsRoot, codexRoot], now: now)
        #expect(summary.scannedFiles == 1)
        #expect(summary.todayTokens == 42)
        #expect(summary.last30DaysTokens == 42)
    }

    @Test func usageScannerScansMostRecentFilesWhenCapped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let jsonl = #"{"timestamp":"2026-04-26T12:00:00Z","usage":{"total_tokens":1}}"#

        for index in 0..<1_502 {
            let file = root.appendingPathComponent(String(format: "%04d.jsonl", index))
            try #require(jsonl.data(using: .utf8)).write(to: file)
            let modifiedAt = now.addingTimeInterval(TimeInterval(-index))
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        }

        let summary = LocalUsageScanner.scan(roots: [root], now: now)
        #expect(summary.scannedFiles == 1_500)
        #expect(summary.truncatedFileCount == 2)
        #expect(summary.todayTokens == 1_500)
        #expect(summary.last30DaysTokens == 1_500)
    }

    @Test func usageScannerInvalidatesCachedFileSummariesWhenFileChanges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try date("2026-04-26T15:00:00Z")
        let file = root.appendingPathComponent("session.jsonl")
        let initialJSONL = #"{"timestamp":"2026-04-26T12:00:00Z","usage":{"total_tokens":1}}"#
        try #require(initialJSONL.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let initialSummary = LocalUsageScanner.scan(roots: [root], now: now)
        #expect(initialSummary.todayTokens == 1)

        let updatedJSONL = #"{"timestamp":"2026-04-26T12:00:00Z","usage":{"total_tokens":700}}"#
        try #require(updatedJSONL.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let updatedSummary = LocalUsageScanner.scan(roots: [root], now: now)
        #expect(updatedSummary.todayTokens == 700)
        #expect(updatedSummary.last30DaysTokens == 700)
    }

    @Test func tokenScannerPrefersUsageObjectOverSiblingTokenCounters() {
        let object: [String: Any] = [
            "message": [
                "usage": [
                    "total_tokens": 25,
                ],
            ],
            "metadata": [
                "input_tokens": 999,
                "output_tokens": 999,
            ],
        ]

        #expect(LocalUsageScanner.tokenTotal(in: object) == 25)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "CodeBarProTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func date(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else {
            throw CocoaError(.coderInvalidValue)
        }
        return date
    }
}
