//
//  UsageStore.swift
//  CodeBarPro
//

import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [UsageProvider: ProviderSnapshot]
    @Published private(set) var isRefreshing = false
    @Published var preferences: AppPreferences

    private let probe: any ProviderProbing
    private var refreshTask: Task<Void, Never>?
    private var needsRefreshAfterCurrent = false
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(preferences: AppPreferences(), probe: LocalProviderProbe())
    }

    init(preferences: AppPreferences, probe: any ProviderProbing) {
        self.preferences = preferences
        self.probe = probe
        self.snapshots = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map {
            ($0, ProviderSnapshot.placeholder(for: $0, enabled: preferences.isEnabled($0)))
        })
        observePreferences()
    }

    deinit {
        refreshTask?.cancel()
    }

    var orderedSnapshots: [ProviderSnapshot] {
        UsageProvider.allCases.compactMap { snapshots[$0] }
    }

    var enabledSnapshots: [ProviderSnapshot] {
        orderedSnapshots.filter(\.isEnabled)
    }

    var primarySnapshot: ProviderSnapshot {
        enabledSnapshots.first ?? orderedSnapshots.first ?? ProviderSnapshot.placeholder(for: .codex, enabled: true)
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                guard let interval = self.preferences.refreshCadence.interval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    func restartAutoRefresh() {
        startAutoRefresh()
    }

    func refresh() async {
        if isRefreshing {
            needsRefreshAfterCurrent = true
            return
        }

        repeat {
            needsRefreshAfterCurrent = false
            await performRefresh()
        } while needsRefreshAfterCurrent && !Task.isCancelled
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let requests = UsageProvider.allCases.map { provider in
            (provider: provider, enabled: preferences.isEnabled(provider))
        }

        for request in requests {
            snapshots[request.provider] = ProviderSnapshot.placeholder(for: request.provider, enabled: request.enabled)
        }

        let probe = self.probe
        await withTaskGroup(of: (UsageProvider, ProviderSnapshot).self) { group in
            for request in requests {
                group.addTask(priority: .utility) {
                    let snapshot = await probe.snapshot(for: request.provider, enabled: request.enabled)
                    return (request.provider, snapshot)
                }
            }

            for await (provider, snapshot) in group {
                snapshots[provider] = snapshot
            }
        }
    }

    func setProvider(_ provider: UsageProvider, enabled: Bool) {
        preferences.setEnabled(enabled, for: provider)
        snapshots[provider] = ProviderSnapshot.placeholder(for: provider, enabled: enabled)
        Task { @MainActor in await refresh() }
    }

    private func observePreferences() {
        preferences.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        preferences.$refreshCadence
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.restartAutoRefresh()
                }
            }
            .store(in: &cancellables)
    }
}
