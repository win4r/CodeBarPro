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
