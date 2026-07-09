//
//  WindowBuddyApp.swift
//  WindowOrchestrator
//
//  Created by H on 30/05/2026.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct WindowBuddyApp: App {
    @NSApplicationDelegateAdaptor(WindowBuddyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class WindowBuddyAppDelegate: NSObject, NSApplicationDelegate {
    private let model = WindowBuddyModel()
    private let settingsPresenter = WindowBuddySettingsWindowPresenter()
    private let finderLastWindowHider = FinderLastWindowHider()
    private var hotKeyController: WindowBuddyHotKeyController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.applyActivationPolicy()
        configureHotKeys()
        configureStatusItem()
        finderLastWindowHider.start()
        model.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func configureHotKeys() {
        let controller = WindowBuddyHotKeyController { [weak self] action in
            guard let self else {
                return
            }

            switch action {
            case .fillFrontmostWindowAndTemporarilyRemoveFromTiling:
                model.fillFrontmostWindowAndTemporarilyRemoveFromTiling()
            case .restoreMostRecentlyRemovedWindowToTiling:
                model.restoreMostRecentlyRemovedWindowToTiling()
            case .resizeAutoTiledWindows:
                model.resizeAutoTiledWindows()
            case .toggleFocusGroups:
                model.toggleFocusGroups()
            case .openSettings:
                openSettings()
            }
        }
        controller.start()
        hotKeyController = controller
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarImage()
        item.button?.action = #selector(openSettingsFromStatusItem)
        item.button?.target = self
        statusItem = item
    }

    @objc private func openSettingsFromStatusItem() {
        openSettings()
    }

    private func openSettings() {
        settingsPresenter.show(model: model)
    }

    private static func menuBarImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "WindowOrchestrator")
        image?.isTemplate = true
        return image
    }
}

@MainActor
private final class WindowBuddySettingsWindowPresenter {
    private var windowController: NSWindowController?

    func show(model: WindowBuddyModel) {
        let controller = windowController ?? makeWindowController(model: model)
        windowController = controller

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
    }

    private func makeWindowController(model: WindowBuddyModel) -> NSWindowController {
        let hostingController = NSHostingController(rootView: WindowBuddySettingsView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WindowOrchestrator Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(NSSize(width: 680, height: 680))
        window.minSize = NSSize(width: 680, height: 680)
        window.center()

        return NSWindowController(window: window)
    }
}

enum WindowBuddyHotKeyAction {
    case fillFrontmostWindowAndTemporarilyRemoveFromTiling
    case restoreMostRecentlyRemovedWindowToTiling
    case resizeAutoTiledWindows
    case toggleFocusGroups
    case openSettings
}

private final class WindowBuddyHotKeyController {
    fileprivate static let signature: OSType = 0x57424459
    fileprivate typealias Handler = @MainActor (WindowBuddyHotKeyAction) -> Void

    private enum Identifier: UInt32 {
        case fillFrontmostWindowAndTemporarilyRemoveFromTiling = 1
        case restoreMostRecentlyRemovedWindowToTiling = 2
        case resizeAutoTiledWindows = 4
        case toggleFocusGroups = 6
        case openSettings = 8

        var action: WindowBuddyHotKeyAction {
            switch self {
            case .fillFrontmostWindowAndTemporarilyRemoveFromTiling:
                .fillFrontmostWindowAndTemporarilyRemoveFromTiling
            case .restoreMostRecentlyRemovedWindowToTiling:
                .restoreMostRecentlyRemovedWindowToTiling
            case .resizeAutoTiledWindows:
                .resizeAutoTiledWindows
            case .toggleFocusGroups:
                .toggleFocusGroups
            case .openSettings:
                .openSettings
            }
        }
    }

    private let handler: Handler
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard eventHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            windowBuddyHotKeyCallback,
                            1,
                            &eventType,
                            userData,
                            &eventHandler)

        registerHotKey(keyCode: UInt32(kVK_UpArrow),
                       modifiers: UInt32(optionKey),
                       identifier: .fillFrontmostWindowAndTemporarilyRemoveFromTiling)
        registerHotKey(keyCode: UInt32(kVK_DownArrow),
                       modifiers: UInt32(optionKey),
                       identifier: .restoreMostRecentlyRemovedWindowToTiling)
        registerHotKey(keyCode: UInt32(kVK_ANSI_7),
                       modifiers: UInt32(cmdKey | shiftKey),
                       identifier: .resizeAutoTiledWindows)
        registerHotKey(keyCode: UInt32(kVK_ANSI_6),
                       modifiers: UInt32(cmdKey | shiftKey),
                       identifier: .toggleFocusGroups)
        registerHotKey(keyCode: UInt32(kVK_ANSI_8),
                       modifiers: UInt32(cmdKey | shiftKey),
                       identifier: .openSettings)
    }

    func stop() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys = []

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func handleHotKey(identifier: UInt32) {
        guard let identifier = Identifier(rawValue: identifier) else {
            return
        }

        Task { @MainActor in
            handler(identifier.action)
        }
    }

    private func registerHotKey(keyCode: UInt32,
                                modifiers: UInt32,
                                identifier: Identifier) {
        let hotKeyID = EventHotKeyID(signature: Self.signature,
                                     id: identifier.rawValue)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                          modifiers,
                                          hotKeyID,
                                          GetApplicationEventTarget(),
                                          0,
                                          &hotKey)

        guard status == noErr,
              let hotKey else {
            return
        }

        hotKeys.append(hotKey)
    }
}

private let windowBuddyHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event,
          let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr,
          hotKeyID.signature == WindowBuddyHotKeyController.signature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<WindowBuddyHotKeyController>.fromOpaque(userData).takeUnretainedValue()
    controller.handleHotKey(identifier: hotKeyID.id)
    return noErr
}
