//
//  AppPreferences.swift
//  CodeBarPro
//

import Combine
import Foundation

final class AppPreferences: ObservableObject {
    @Published var enabledProviders: Set<UsageProvider> {
        didSet { saveEnabledProviders() }
    }

    @Published var refreshCadence: RefreshCadence {
        didSet { userDefaults.set(refreshCadence.rawValue, forKey: Keys.refreshCadence) }
    }

    @Published var showUsedInMenuBar: Bool {
        didSet { userDefaults.set(showUsedInMenuBar, forKey: Keys.showUsedInMenuBar) }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let storedProviders = userDefaults.stringArray(forKey: Keys.enabledProviders)
        if let storedProviders {
            enabledProviders = Set(storedProviders.compactMap(UsageProvider.init(rawValue:)))
        } else {
            enabledProviders = Set(UsageProvider.allCases)
        }

        if let cadenceValue = userDefaults.object(forKey: Keys.refreshCadence) as? Int {
            refreshCadence = RefreshCadence(rawValue: cadenceValue) ?? .fiveMinutes
        } else {
            refreshCadence = .fiveMinutes
        }
        showUsedInMenuBar = userDefaults.object(forKey: Keys.showUsedInMenuBar) as? Bool ?? false
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        enabledProviders.contains(provider)
    }

    func setEnabled(_ isEnabled: Bool, for provider: UsageProvider) {
        if isEnabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
    }

    private func saveEnabledProviders() {
        let rawValues = enabledProviders.map(\.rawValue).sorted()
        userDefaults.set(rawValues, forKey: Keys.enabledProviders)
    }

    private enum Keys {
        static let enabledProviders = "enabledProviders"
        static let refreshCadence = "refreshCadence"
        static let showUsedInMenuBar = "showUsedInMenuBar"
    }
}
