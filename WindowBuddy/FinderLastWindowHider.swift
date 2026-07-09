//
//  FinderLastWindowHider.swift
//  WindowBuddy
//
//  Created by Codex on 07/06/2026.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class FinderLastWindowHider {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let commandWKeyCode = CGKeyCode(kVK_ANSI_W)
    private static let commandHKeyCode = CGKeyCode(kVK_ANSI_H)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else {
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: eventMask,
                                              callback: finderLastWindowHiderCallback,
                                              userInfo: userInfo) else {
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    fileprivate func handleEvent(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.commandWKeyCode,
              event.flags.contains(.maskCommand),
              !event.flags.contains(.maskControl),
              !event.flags.contains(.maskAlternate),
              !event.flags.contains(.maskShift),
              shouldConvertFinderCloseToHide() else {
            return Unmanaged.passUnretained(event)
        }

        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(Self.commandHKeyCode))
        return Unmanaged.passUnretained(event)
    }

    private func shouldConvertFinderCloseToHide() -> Bool {
        guard AXIsProcessTrusted(),
              let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == Self.finderBundleIdentifier,
              finder.activationPolicy == .regular else {
            return false
        }

        let applicationElement = AXUIElementCreateApplication(finder.processIdentifier)
        guard visibleStandardWindowCount(for: applicationElement) == 1 else {
            return false
        }

        return true
    }

    private func visibleStandardWindowCount(for applicationElement: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(applicationElement,
                                                  kAXWindowsAttribute as CFString,
                                                  &value)
        guard error == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }

        return windows.filter(isVisibleStandardWindow).count
    }

    private func isVisibleStandardWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute as CFString, for: window) == kAXWindowRole,
              stringAttribute(kAXSubroleAttribute as CFString, for: window) == kAXStandardWindowSubrole else {
            return false
        }

        if let isMinimized = boolAttribute(kAXMinimizedAttribute as CFString, for: window),
           isMinimized {
            return false
        }

        return true
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private func boolAttribute(_ attribute: CFString, for element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }

        return value as? Bool
    }
}

private let finderLastWindowHiderCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let hider = Unmanaged<FinderLastWindowHider>.fromOpaque(userInfo).takeUnretainedValue()
    return hider.handleEvent(proxy: proxy,
                             type: type,
                             event: event)
}
