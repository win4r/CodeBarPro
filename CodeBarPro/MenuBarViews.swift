//
//  MenuBarViews.swift
//  CodeBarPro
//

import AppKit
import SwiftUI

struct MenuBarLabel: View {
    var snapshot: ProviderSnapshot
    var showUsedAmount = false

    var body: some View {
        HStack(spacing: 5) {
            MeterGlyph(primary: snapshot.primary.percentRemaining, secondary: snapshot.secondary.percentRemaining)
                .frame(width: 18, height: 18)
            Text(labelText)
        }
        .help(snapshot.state.title)
    }

    private var labelText: String {
        showUsedAmount ? snapshot.primary.formattedValue : snapshot.provider.displayName
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 10) {
                ForEach(store.orderedSnapshots) { snapshot in
                    ProviderCard(snapshot: snapshot)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Button {
                    SettingsWindowOpener.open()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.blue.opacity(0.16))
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("CodeBar Pro")
                    .font(.headline)
                Text(store.isRefreshing ? "Refreshing provider usage" : "Local provider activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

struct ProviderCard: View {
    var snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: snapshot.provider.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 24)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.provider.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                StatusPill(state: snapshot.state)
            }

            MetricRow(metric: snapshot.primary)
            MetricRow(metric: snapshot.secondary)

            if let notes = snapshot.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(snapshot.isEnabled ? 1 : 0.58)
    }

    private var iconColor: Color {
        if snapshot.state.isReady { return .blue }
        if case .failed = snapshot.state { return .red }
        return .secondary
    }

    private var statusText: String {
        if let detail = snapshot.state.detail {
            return detail
        }
        if let updatedAt = snapshot.updatedAt {
            return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
        }
        return snapshot.state.title
    }
}

struct MetricRow: View {
    var metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: metric.percentUsed ?? 0, total: 1)
                .tint(metric.percentUsed == nil ? .secondary : .blue)
        }
    }

    private var valueText: String {
        let suffix = metric.unit == .tokens ? "tokens" : "events"
        return "\(metric.formattedValue) \(suffix)"
    }
}

struct StatusPill: View {
    var state: ProviderConnectionState

    var body: some View {
        Text(state.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch state {
        case .ready:
            return .green
        case .failed, .missingCLI:
            return .red
        case .refreshing:
            return .blue
        case .disabled:
            return .secondary
        }
    }

    private var background: Color {
        foreground.opacity(0.14)
    }
}

struct MeterGlyph: View {
    var primary: Double?
    var secondary: Double?

    var body: some View {
        VStack(spacing: 3) {
            meter(value: primary, height: 8)
            meter(value: secondary, height: 3)
        }
        .padding(.horizontal, 1)
        .accessibilityHidden(true)
    }

    private func meter(value: Double?, height: CGFloat) -> some View {
        GeometryReader { proxy in
            let progress = value ?? 0.72
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.22))
                Capsule()
                    .fill(.primary)
                    .frame(width: max(2, proxy.size.width * progress))
            }
        }
        .frame(height: height)
    }
}

#Preview {
    MenuContentView(store: UsageStore())
}
