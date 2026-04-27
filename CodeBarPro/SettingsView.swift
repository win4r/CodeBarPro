//
//  SettingsView.swift
//  CodeBarPro
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TabView {
            providerSettings
                .tabItem {
                    Label("Providers", systemImage: "switch.2")
                }

            displaySettings
                .tabItem {
                    Label("Display", systemImage: "menubar.rectangle")
                }

            aboutPane
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding(20)
    }

    private var providerSettings: some View {
        Form {
            Section("Providers") {
                ForEach(UsageProvider.allCases) { provider in
                    Toggle(isOn: Binding(
                        get: { store.preferences.isEnabled(provider) },
                        set: { store.setProvider(provider, enabled: $0) }))
                    {
                        Label(provider.displayName, systemImage: provider.symbolName)
                    }
                }
            }

            Section("Refresh") {
                Picker("Cadence", selection: Binding(
                    get: { store.preferences.refreshCadence },
                    set: { store.preferences.refreshCadence = $0 }))
                {
                    ForEach(RefreshCadence.allCases) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var displaySettings: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show used amount in menu bar", isOn: $store.preferences.showUsedInMenuBar)
            }

            Section("Local Data") {
                HStack {
                    Button {
                        openHomeSubpath(".codex")
                    } label: {
                        Label("Open .codex", systemImage: "folder")
                    }

                    Button {
                        openHomeSubpath(".claude")
                    } label: {
                        Label("Open .claude", systemImage: "folder")
                    }
                }
            }
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text("CodeBar Pro")
                        .font(.title2.weight(.semibold))
                    Text("Native macOS menu bar usage monitor")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Built as a local-first native macOS utility.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openHomeSubpath(_ path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    SettingsView(store: UsageStore())
}
