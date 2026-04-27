//
//  StatusItemController.swift
//  CodeBarPro
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configurePopover()
        configureButton()
        observeStore()
        updateButton()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: MenuContentView(store: store))
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    private func observeStore() {
        store.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateButton()
                }
            }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let snapshot = store.primarySnapshot
        let symbol = snapshot.state.isReady ? "chart.bar.xaxis" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "CodeBar Pro")
        image?.isTemplate = true
        button.image = image
        button.title = store.preferences.showUsedInMenuBar ? " \(snapshot.primary.formattedValue)" : " CodeBar Pro"
        button.toolTip = "CodeBar Pro - \(snapshot.provider.displayName): \(snapshot.state.title)"
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

enum SettingsWindowOpener {
    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
