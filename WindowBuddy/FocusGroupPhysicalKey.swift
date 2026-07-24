import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct FocusGroupPhysicalKey: Equatable, Hashable {
    static let groupOneDefault = FocusGroupPhysicalKey(validatedKeyCode: UInt16(kVK_ISO_Section))
    static let groupTwoDefault = FocusGroupPhysicalKey(validatedKeyCode: UInt16(kVK_CapsLock))

    let keyCode: UInt16

    init?(keyCode: UInt16) {
        guard DockMoverShortcut.keyLabel(for: keyCode) != nil else {
            return nil
        }

        self.keyCode = keyCode
    }

    private init(validatedKeyCode keyCode: UInt16) {
        self.keyCode = keyCode
    }

    var displayText: String {
        if keyCode != UInt16(kVK_ISO_Section),
           Self.layoutDependentPrintableKeyCodes.contains(keyCode),
           let currentInputSourceLabel = Self.currentInputSourceLabel(for: keyCode) {
            return currentInputSourceLabel
        }

        return DockMoverShortcut.keyLabel(for: keyCode) ?? "Key \(keyCode)"
    }

    static func conflicts(_ first: FocusGroupPhysicalKey,
                          _ second: FocusGroupPhysicalKey) -> Bool {
        if first == second {
            return true
        }

        // A Caps Lock -> F17 HID mapping makes these two codes indistinguishable.
        let capsLockKeyCode = UInt16(kVK_CapsLock)
        let f17KeyCode = UInt16(kVK_F17)
        return (first.keyCode == capsLockKeyCode && second.keyCode == f17KeyCode) ||
            (first.keyCode == f17KeyCode && second.keyCode == capsLockKeyCode)
    }

    private static func currentInputSourceLabel(for keyCode: UInt16) -> String? {
        guard let cgEvent = CGEvent(keyboardEventSource: nil,
                                    virtualKey: CGKeyCode(keyCode),
                                    keyDown: true),
              let characters = NSEvent(cgEvent: cgEvent)?.charactersIgnoringModifiers,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar) &&
                      !(0xE000...0xF8FF).contains(Int(scalar.value))
              }) else {
            return nil
        }

        return characters.uppercased()
    }

    private static let layoutDependentPrintableKeyCodes: Set<UInt16> = [
        UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_B), UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_D),
        UInt16(kVK_ANSI_E), UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_G), UInt16(kVK_ANSI_H),
        UInt16(kVK_ANSI_I), UInt16(kVK_ANSI_J), UInt16(kVK_ANSI_K), UInt16(kVK_ANSI_L),
        UInt16(kVK_ANSI_M), UInt16(kVK_ANSI_N), UInt16(kVK_ANSI_O), UInt16(kVK_ANSI_P),
        UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_R), UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_T),
        UInt16(kVK_ANSI_U), UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_X),
        UInt16(kVK_ANSI_Y), UInt16(kVK_ANSI_Z),
        UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
        UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7),
        UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
        UInt16(kVK_ANSI_Equal), UInt16(kVK_ANSI_Minus),
        UInt16(kVK_ANSI_RightBracket), UInt16(kVK_ANSI_LeftBracket),
        UInt16(kVK_ANSI_Quote), UInt16(kVK_ANSI_Semicolon), UInt16(kVK_ANSI_Backslash),
        UInt16(kVK_ANSI_Comma), UInt16(kVK_ANSI_Slash), UInt16(kVK_ANSI_Period),
        UInt16(kVK_ANSI_Grave)
    ]
}

@MainActor
final class FocusGroupPhysicalKeyRecordingCoordinator {
    static let shared = FocusGroupPhysicalKeyRecordingCoordinator()

    private struct Session {
        let identifier: UUID
        let isValid: () -> Bool
        let onCapture: (FocusGroupPhysicalKey) -> Void
        let onCancel: () -> Void
    }

    private var activeSession: Session?
    var recordingStateDidChange: ((Bool) -> Void)?

    private init() {}

    var isRecording: Bool {
        activeSession != nil
    }

    func begin(isValid: @escaping () -> Bool,
               onCapture: @escaping (FocusGroupPhysicalKey) -> Void,
               onCancel: @escaping () -> Void) -> UUID {
        let previousSession = activeSession
        activeSession = nil
        previousSession?.onCancel()

        let identifier = UUID()
        activeSession = Session(identifier: identifier,
                                isValid: isValid,
                                onCapture: onCapture,
                                onCancel: onCancel)
        recordingStateDidChange?(true)
        return identifier
    }

    func prepareToCapture() -> Bool {
        guard let session = activeSession else {
            return false
        }
        guard session.isValid() else {
            activeSession = nil
            recordingStateDidChange?(false)
            session.onCancel()
            return false
        }

        return true
    }

    func isActive(_ identifier: UUID) -> Bool {
        activeSession?.identifier == identifier
    }

    @discardableResult
    func capture(_ key: FocusGroupPhysicalKey,
                 for identifier: UUID? = nil) -> Bool {
        guard let session = activeSession,
              identifier == nil || identifier == session.identifier else {
            return false
        }

        activeSession = nil
        recordingStateDidChange?(false)
        session.onCapture(key)
        return true
    }

    @discardableResult
    func cancel(_ identifier: UUID? = nil) -> Bool {
        guard let session = activeSession,
              identifier == nil || identifier == session.identifier else {
            return false
        }

        activeSession = nil
        recordingStateDidChange?(false)
        session.onCancel()
        return true
    }

    func end(_ identifier: UUID) {
        guard activeSession?.identifier == identifier else {
            return
        }

        activeSession = nil
        recordingStateDidChange?(false)
    }
}
