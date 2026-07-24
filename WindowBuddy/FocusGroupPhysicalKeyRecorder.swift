import AppKit
import Carbon.HIToolbox
import SwiftUI

struct FocusGroupPhysicalKeyRecorder: NSViewRepresentable {
    let key: FocusGroupPhysicalKey
    let onCommit: (FocusGroupPhysicalKey) -> Bool

    func makeNSView(context: Context) -> FocusGroupPhysicalKeyRecorderTextField {
        let textField = FocusGroupPhysicalKeyRecorderTextField()
        textField.key = key
        textField.onCommit = onCommit
        textField.refreshDisplay()
        return textField
    }

    func updateNSView(_ textField: FocusGroupPhysicalKeyRecorderTextField,
                      context: Context) {
        textField.key = key
        textField.onCommit = onCommit
        textField.refreshDisplay()
    }
}

final class FocusGroupPhysicalKeyRecorderTextField: NSTextField {
    private enum Metrics {
        static let controlHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 7
        static let horizontalInset: CGFloat = 14
    }

    var key: FocusGroupPhysicalKey = .groupOneDefault {
        didSet {
            refreshDisplay()
        }
    }

    var onCommit: ((FocusGroupPhysicalKey) -> Bool)?

    private var recordingSessionIdentifier: UUID?
    private var localEventMonitor: Any?
    private weak var observedWindow: NSWindow?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.controlHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        finishRecording()
        NotificationCenter.default.removeObserver(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }

    override func becomeFirstResponder() -> Bool {
        startRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleLocalEvent(event) {
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !handleLocalEvent(event) {
            super.flagsChanged(with: event)
        }
    }

    func refreshDisplay() {
        if recordingSessionIdentifier != nil {
            stringValue = "Press one key"
            textColor = .secondaryLabelColor
        } else {
            stringValue = key.displayText
            textColor = .labelColor
        }

        updateChrome()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        focusRingType = .none
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        lineBreakMode = .byTruncatingTail
        cell = FocusGroupPhysicalKeyRecorderTextFieldCell(textCell: "")
        cell?.alignment = .center
        cell?.font = font
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = "Click, then press one physical key. Press Escape to cancel."
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Metrics.cornerRadius
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(inputSourceDidChange),
                                               name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                                               object: nil)
        updateChrome()
    }

    private func startRecording() {
        guard recordingSessionIdentifier == nil else {
            installLocalEventMonitorIfNeeded()
            return
        }

        FocusGroupPhysicalKeyController.turnCapsLockOff()
        recordingSessionIdentifier = FocusGroupPhysicalKeyRecordingCoordinator.shared.begin(
            isValid: { [weak self] in
                guard let self else {
                    return false
                }

                return self.recordingSessionIdentifier != nil &&
                    self.window?.isKeyWindow == true &&
                    NSApp.isActive
            },
            onCapture: { [weak self] key in
                self?.commit(key)
            },
            onCancel: { [weak self] in
                self?.finishRecording()
            }
        )
        installLocalEventMonitorIfNeeded()
        installDeactivationObserversIfNeeded()
        refreshDisplay()
    }

    private func finishRecording() {
        let identifier = recordingSessionIdentifier
        recordingSessionIdentifier = nil
        removeLocalEventMonitor()
        removeDeactivationObservers()

        if let identifier {
            FocusGroupPhysicalKeyRecordingCoordinator.shared.end(identifier)
        }

        refreshDisplay()
    }

    private func commit(_ key: FocusGroupPhysicalKey) {
        finishRecording()
        window?.makeFirstResponder(nil)
        if onCommit?(key) == true {
            self.key = key
        } else {
            refreshDisplay()
        }
    }

    private func installDeactivationObserversIfNeeded() {
        guard observedWindow == nil,
              let window else {
            return
        }

        observedWindow = window
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cancelRecordingForDeactivation),
                                               name: NSWindow.didResignKeyNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cancelRecordingForDeactivation),
                                               name: NSWindow.didMiniaturizeNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cancelRecordingForDeactivation),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cancelRecordingForDeactivation),
                                               name: NSApplication.didResignActiveNotification,
                                               object: NSApp)
    }

    private func removeDeactivationObservers() {
        let notificationCenter = NotificationCenter.default
        if let observedWindow {
            notificationCenter.removeObserver(self,
                                              name: NSWindow.didResignKeyNotification,
                                              object: observedWindow)
            notificationCenter.removeObserver(self,
                                              name: NSWindow.didMiniaturizeNotification,
                                              object: observedWindow)
            notificationCenter.removeObserver(self,
                                              name: NSWindow.willCloseNotification,
                                              object: observedWindow)
        }
        notificationCenter.removeObserver(self,
                                          name: NSApplication.didResignActiveNotification,
                                          object: NSApp)
        observedWindow = nil
    }

    @objc
    private func cancelRecordingForDeactivation(_ notification: Notification) {
        finishRecording()
    }

    @objc
    private func inputSourceDidChange(_ notification: Notification) {
        refreshDisplay()
    }

    private func installLocalEventMonitorIfNeeded() {
        guard localEventMonitor == nil else {
            return
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self,
                  self.recordingSessionIdentifier != nil,
                  self.window?.isKeyWindow == true else {
                return event
            }

            return self.handleLocalEvent(event) ? nil : event
        }
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else {
            return
        }

        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard let identifier = recordingSessionIdentifier,
              FocusGroupPhysicalKeyRecordingCoordinator.shared.isActive(identifier) else {
            return false
        }

        if event.type == .flagsChanged {
            guard event.keyCode == UInt16(kVK_CapsLock),
                  event.modifierFlags.contains(.capsLock) else {
                return false
            }

            FocusGroupPhysicalKeyController.turnCapsLockOff()
            return FocusGroupPhysicalKeyRecordingCoordinator.shared.capture(.groupTwoDefault,
                                                                              for: identifier)
        }

        guard event.type == .keyDown else {
            return false
        }
        if event.keyCode == UInt16(kVK_Escape) {
            return FocusGroupPhysicalKeyRecordingCoordinator.shared.cancel(identifier)
        }
        guard !event.isARepeat else {
            return true
        }

        let normalizedKeyCode = FocusGroupPhysicalKeyController.normalizedRecordedKeyCode(event.keyCode)
        guard let key = FocusGroupPhysicalKey(keyCode: normalizedKeyCode) else {
            NSSound.beep()
            return true
        }

        return FocusGroupPhysicalKeyRecordingCoordinator.shared.capture(key,
                                                                         for: identifier)
    }

    private func updateChrome() {
        guard let layer else {
            return
        }

        layer.backgroundColor = NSColor.controlColor.cgColor
        layer.borderWidth = recordingSessionIdentifier == nil ? 0 : 2
        layer.borderColor = recordingSessionIdentifier == nil
            ? NSColor.clear.cgColor
            : NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        layer.shadowOpacity = 0
    }
}

private final class FocusGroupPhysicalKeyRecorderTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        var drawingRect = super.drawingRect(forBounds: rect)
        drawingRect.origin.y += max(0, (drawingRect.height - textSize.height) / 2)
        drawingRect.size.height = min(drawingRect.height, textSize.height)
        return drawingRect.insetBy(dx: 14, dy: 0)
    }
}
