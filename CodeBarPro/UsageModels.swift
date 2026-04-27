//
//  UsageModels.swift
//  CodeBarPro
//

import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        }
    }

    nonisolated var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .codex:
            return "terminal"
        case .claude:
            return "sparkles"
        }
    }
}

enum ProviderConnectionState: Equatable, Sendable {
    case disabled
    case refreshing
    case ready(String)
    case missingCLI(String)
    case failed(String)

    nonisolated var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .refreshing:
            return "Refreshing"
        case .ready:
            return "Ready"
        case .missingCLI:
            return "CLI Missing"
        case .failed:
            return "Error"
        }
    }

    nonisolated var detail: String? {
        switch self {
        case .disabled, .refreshing:
            return nil
        case let .ready(version):
            return version
        case let .missingCLI(command):
            return "\(command) was not found in PATH."
        case let .failed(message):
            return message
        }
    }

    nonisolated var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct UsageMetric: Equatable, Sendable {
    enum Unit: String, Sendable {
        case tokens
        case events
        case percent
        case currency
    }

    var title: String
    var used: Double
    var limit: Double?
    var unit: Unit
    var currencyCode: String? = nil
    var resetsAt: Date? = nil

    nonisolated var percentUsed: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    nonisolated var percentRemaining: Double? {
        percentUsed.map { 1 - $0 }
    }

    nonisolated var formattedValue: String {
        switch unit {
        case .tokens:
            return NumberFormat.compactInteger(Int(used))
        case .events:
            return NumberFormat.integer(Int(used))
        case .percent:
            return "\(NumberFormat.decimal(used))%"
        case .currency:
            return NumberFormat.currency(used, code: currencyCode)
        }
    }
}

struct ProviderSnapshot: Equatable, Identifiable, Sendable {
    var id: UsageProvider { provider }
    var provider: UsageProvider
    var isEnabled: Bool
    var state: ProviderConnectionState
    var primary: UsageMetric
    var secondary: UsageMetric
    var additionalMetrics: [UsageMetric] = []
    var updatedAt: Date?
    var localLogCount: Int
    var notes: String?

    nonisolated static func placeholder(for provider: UsageProvider, enabled: Bool) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            isEnabled: enabled,
            state: enabled ? .refreshing : .disabled,
            primary: UsageMetric(
                title: "Today",
                used: 0,
                limit: nil,
                unit: .events,
                resetsAt: Calendar.current.startOfNextDay()),
            secondary: UsageMetric(
                title: "Last 30 days",
                used: 0,
                limit: nil,
                unit: .events,
                currencyCode: nil,
                resetsAt: nil),
            updatedAt: nil,
            localLogCount: 0,
            notes: nil)
    }
}

enum RefreshCadence: Int, CaseIterable, Identifiable, Sendable {
    case manual = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900

    nonisolated var id: Int { rawValue }

    nonisolated var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .oneMinute:
            return "1 min"
        case .twoMinutes:
            return "2 min"
        case .fiveMinutes:
            return "5 min"
        case .fifteenMinutes:
            return "15 min"
        }
    }

    nonisolated var interval: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

extension Calendar {
    nonisolated func startOfNextDay(from date: Date = Date()) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: start) ?? date
    }
}

enum NumberFormat {
    nonisolated static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    nonisolated static func compactInteger(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return integer(value)
    }

    nonisolated static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    nonisolated static func currency(_ value: Double, code: String?) -> String {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let prefix = normalizedCode == "USD" || normalizedCode == nil ? "$" : "\(normalizedCode!) "
        return "\(prefix)\(String(format: "%.2f", value))"
    }
}
