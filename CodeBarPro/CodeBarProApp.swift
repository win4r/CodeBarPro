//
//  CodeBarProApp.swift
//  CodeBarPro
//
//  Native macOS menu bar app for local provider usage monitoring.
//

import AppKit
import SwiftUI

@main
struct CodeBarProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: UsageStore

    init() {
        let store = UsageStore()
        _store = StateObject(wrappedValue: store)
        appDelegate.configure(store: store)
    }

    var body: some Scene {
        Settings {
            SettingsView(store: store)
                .frame(width: 560, height: 440)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusController: StatusItemController?

    func configure(store: UsageStore) {
        self.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let store else { return }

        if !ProcessInfo.processInfo.isRunningTests {
            store.startAutoRefresh()
        }
        statusController = StatusItemController(store: store)
    }
}

extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
