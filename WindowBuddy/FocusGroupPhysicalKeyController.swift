import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hidsystem

struct FocusGroupCycleCommand: Equatable, Hashable {
    let groupNumber: Int
    let reverse: Bool
}

struct FocusGroupPhysicalKeyBinding: Equatable {
    static let capsLockKeyCode = Int64(kVK_CapsLock)
    static let remappedCapsLockKeyCode = Int64(kVK_F17)

    var groupOneKey: FocusGroupPhysicalKey
    var groupTwoKey: FocusGroupPhysicalKey

    private static let shortcutModifierMask: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift
    ]

    init(groupOneKey: FocusGroupPhysicalKey = .groupOneDefault,
         groupTwoKey: FocusGroupPhysicalKey = .groupTwoDefault) {
        self.groupOneKey = groupOneKey
        self.groupTwoKey = groupTwoKey
    }

    var usesCapsLock: Bool {
        Int64(groupOneKey.keyCode) == Self.capsLockKeyCode ||
            Int64(groupTwoKey.keyCode) == Self.capsLockKeyCode
    }

    func groupNumber(keyCode: Int64,
                     capsLockToF17MappingActive: Bool) -> Int? {
        if keyCode == Self.remappedCapsLockKeyCode,
           capsLockToF17MappingActive {
            if Int64(groupOneKey.keyCode) == Self.capsLockKeyCode {
                return 1
            }
            if Int64(groupTwoKey.keyCode) == Self.capsLockKeyCode {
                return 2
            }
        }

        if keyCode == Int64(groupOneKey.keyCode) {
            return 1
        }
        if keyCode == Int64(groupTwoKey.keyCode) {
            return 2
        }

        return nil
    }

    func command(keyCode: Int64,
                 flags: CGEventFlags,
                 capsLockToF17MappingActive: Bool) -> FocusGroupCycleCommand? {
        guard let groupNumber = groupNumber(keyCode: keyCode,
                                            capsLockToF17MappingActive: capsLockToF17MappingActive) else {
            return nil
        }

        let shortcutModifiers = flags.intersection(Self.shortcutModifierMask)
        if shortcutModifiers.isEmpty {
            return FocusGroupCycleCommand(groupNumber: groupNumber, reverse: false)
        }
        if shortcutModifiers == .maskCommand {
            return FocusGroupCycleCommand(groupNumber: groupNumber, reverse: true)
        }

        return nil
    }
}

final class FocusGroupPhysicalKeyController {
    typealias Handler = @MainActor (FocusGroupCycleCommand) -> Void

    private static let expectedCarbonHandledCommands: Set<FocusGroupCycleCommand> = [
        FocusGroupCycleCommand(groupNumber: 1, reverse: false),
        FocusGroupCycleCommand(groupNumber: 1, reverse: true),
        FocusGroupCycleCommand(groupNumber: 2, reverse: false),
        FocusGroupCycleCommand(groupNumber: 2, reverse: true)
    ]

    private let handler: Handler
    private let capsLockStateController = CapsLockStateController()
    private var binding = FocusGroupPhysicalKeyBinding()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var carbonHandledCommands: Set<FocusGroupCycleCommand> = []
    private var consumedKeyDownCodes: Set<Int64> = []
    private var suppressedRecordingKeyUpCodes: Set<Int64> = []
    private var isStarted = false
    private var reconciliationIsScheduled = false
    private var capsLockMappingHealthTimer: Timer?
    private var capsLockMappingHealthCheckIsRunning = false

    init(handler: @escaping Handler) {
        self.handler = handler
        capsLockStateController.keyboardMappingDidReconcile = { [weak self] in
            self?.scheduleCapsLockRemappingUpdate()
        }
        FocusGroupPhysicalKeyRecordingCoordinator.shared.recordingStateDidChange = { [weak self] isRecording in
            guard let self else {
                return
            }

            if isRecording {
                // Install the recorder tap before the next keyboard event can reach
                // an existing Carbon registration. Cleanup remains deferred so the
                // captured key's matching release can be consumed as well.
                self.synchronizeCapsLockRemapping()
                self.reconcileEventTap()
                self.turnCapsLockOffIfNeeded()
                self.updateCapsLockMappingHealthTimer()
            } else {
                self.scheduleCapsLockRemappingUpdate()
            }
        }
    }

    deinit {
        stop()
    }

    static func normalizedRecordedKeyCode(_ keyCode: UInt16) -> UInt16 {
        guard keyCode == UInt16(kVK_F17),
              CapsLockStateController().hasCapsLockToF17Mapping() else {
            return keyCode
        }

        return UInt16(kVK_CapsLock)
    }

    static func turnCapsLockOff() {
        CapsLockStateController().turnOff()
    }

    func updateBindings(groupOneKey: FocusGroupPhysicalKey,
                        groupTwoKey: FocusGroupPhysicalKey) {
        binding = FocusGroupPhysicalKeyBinding(groupOneKey: groupOneKey,
                                                groupTwoKey: groupTwoKey)
        turnCapsLockOffIfNeeded()
        scheduleCapsLockRemappingUpdate()
    }

    func updateCarbonHandledCommands(_ commands: Set<FocusGroupCycleCommand>) {
        carbonHandledCommands = commands
        scheduleCapsLockRemappingUpdate()
    }

    func start() {
        isStarted = true
        capsLockStateController.startMonitoringKeyboardChanges()
        synchronizeCapsLockRemapping()
        reconcileEventTap()
        turnCapsLockOffIfNeeded()
        updateCapsLockMappingHealthTimer()
    }

    func stop() {
        isStarted = false
        reconciliationIsScheduled = false
        capsLockMappingHealthTimer?.invalidate()
        capsLockMappingHealthTimer = nil
        removeEventTap()
        capsLockStateController.stopMonitoringKeyboardChanges()
        capsLockStateController.setRemappingEnabled(false)
        capsLockStateController.turnOff()
        consumedKeyDownCodes.removeAll()
        suppressedRecordingKeyUpCodes.removeAll()
    }

    private func installEventTapIfNeeded() {
        if let eventTap, CFMachPortIsValid(eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        removeEventTap()
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: eventMask,
                                              callback: focusGroupPhysicalKeyCallback,
                                              userInfo: userInfo) else {
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    private func removeEventTap() {
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

    private var hasCompleteCarbonHandling: Bool {
        Self.expectedCarbonHandledCommands.isSubset(of: carbonHandledCommands)
    }

    private var eventTapIsRequired: Bool {
        guard isStarted else {
            return false
        }

        if FocusGroupPhysicalKeyRecordingCoordinator.shared.isRecording ||
            !suppressedRecordingKeyUpCodes.isEmpty ||
            !consumedKeyDownCodes.isEmpty ||
            !hasCompleteCarbonHandling {
            return true
        }

        // Carbon receives Caps as F17. If the HID mapping could not be installed,
        // keep the tap as a raw-Caps fallback instead of losing that key entirely.
        return binding.usesCapsLock &&
            !capsLockStateController.hasCompleteCapsLockToF17Mapping()
    }

    private func reconcileEventTap() {
        if eventTapIsRequired {
            installEventTapIfNeeded()
        } else {
            removeEventTap()
        }
    }

    fileprivate func handleEvent(type: CGEventType,
                                 event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            turnCapsLockOffIfNeeded()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            scheduleCapsLockRemappingUpdate()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if suppressedRecordingKeyUpCodes.contains(keyCode) {
            if type == .keyUp {
                suppressedRecordingKeyUpCodes.remove(keyCode)
                scheduleCapsLockRemappingUpdate()
                return nil
            }
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            if type == .keyDown {
                // A new non-repeat press means the earlier key-up was lost (for example,
                // because a keyboard disconnected). Start a fresh press lifecycle.
                suppressedRecordingKeyUpCodes.remove(keyCode)
                scheduleCapsLockRemappingUpdate()
            }
        }

        if type == .keyUp,
           consumedKeyDownCodes.remove(keyCode) != nil {
            scheduleCapsLockRemappingUpdate()
            return nil
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
           consumedKeyDownCodes.contains(keyCode) {
            return nil
        }

        if type == .keyDown,
           consumedKeyDownCodes.remove(keyCode) != nil {
            // Treat a fresh down after a lost release as a new lifecycle. This avoids
            // consuming the eventual release of a newly registered Carbon hotkey.
            scheduleCapsLockRemappingUpdate()
        }

        if FocusGroupPhysicalKeyRecordingCoordinator.shared.prepareToCapture() {
            return handleRecordingEvent(type: type,
                                        event: event,
                                        keyCode: keyCode)
        }

        // When Caps is configured, F17 is reserved as its HID-level alias. Avoid a
        // per-keypress IOHID property query on this latency-sensitive path.
        let capsLockToF17MappingActive = keyCode == FocusGroupPhysicalKeyBinding.remappedCapsLockKeyCode &&
            binding.usesCapsLock
        guard binding.groupNumber(keyCode: keyCode,
                                  capsLockToF17MappingActive: capsLockToF17MappingActive) != nil else {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == FocusGroupPhysicalKeyBinding.capsLockKeyCode {
            return handleCapsLockEvent(type: type,
                                       event: event,
                                       capsLockToF17MappingActive: capsLockToF17MappingActive)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        guard let command = binding.command(keyCode: keyCode,
                                            flags: event.flags,
                                            capsLockToF17MappingActive: capsLockToF17MappingActive) else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }

        if carbonHandledCommands.contains(command) {
            // Let the matching RegisterEventHotKey registration consume this event. That
            // path has the same foreground-activation behavior as the established
            // Cmd+Shift+6/7 shortcuts.
            return Unmanaged.passUnretained(event)
        }

        consumedKeyDownCodes.insert(keyCode)
        perform(command)
        return nil
    }

    private func handleRecordingEvent(type: CGEventType,
                                      event: CGEvent,
                                      keyCode: Int64) -> Unmanaged<CGEvent>? {
        if keyCode == FocusGroupPhysicalKeyBinding.capsLockKeyCode,
           type == .flagsChanged {
            let isOnTransition = event.flags.contains(.maskAlphaShift)
            capsLockStateController.turnOff()

            if isOnTransition {
                FocusGroupPhysicalKeyRecordingCoordinator.shared.capture(.groupTwoDefault)
            }
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }

        if keyCode == Int64(kVK_Escape) {
            suppressedRecordingKeyUpCodes.insert(keyCode)
            FocusGroupPhysicalKeyRecordingCoordinator.shared.cancel()
            return nil
        }

        let normalizedKeyCode: UInt16
        if keyCode == FocusGroupPhysicalKeyBinding.remappedCapsLockKeyCode,
           capsLockStateController.hasCapsLockToF17Mapping() {
            normalizedKeyCode = UInt16(kVK_CapsLock)
        } else {
            guard let convertedKeyCode = UInt16(exactly: keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            normalizedKeyCode = convertedKeyCode
        }

        guard let key = FocusGroupPhysicalKey(keyCode: normalizedKeyCode) else {
            return Unmanaged.passUnretained(event)
        }

        suppressedRecordingKeyUpCodes.insert(keyCode)
        FocusGroupPhysicalKeyRecordingCoordinator.shared.capture(key)
        return nil
    }

    private func handleCapsLockEvent(type: CGEventType,
                                     event: CGEvent,
                                     capsLockToF17MappingActive: Bool) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            // Caps Lock toggles in HIDSystem before this Quartz event tap. Reset it and only act on
            // the physical "on" transition; the reset generates an "off" transition to ignore.
            let shouldPerformCommand = event.flags.contains(.maskAlphaShift)
            capsLockStateController.turnOff()
            scheduleCapsLockRemappingUpdate()

            if shouldPerformCommand,
               let command = binding.command(keyCode: FocusGroupPhysicalKeyBinding.capsLockKeyCode,
                                             flags: event.flags,
                                             capsLockToF17MappingActive: capsLockToF17MappingActive) {
                perform(command)
            }
            return nil
        }

        if type == .keyDown || type == .keyUp {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func turnCapsLockOffIfNeeded() {
        if binding.usesCapsLock || FocusGroupPhysicalKeyRecordingCoordinator.shared.isRecording {
            capsLockStateController.turnOff()
        }
    }

    private func synchronizeCapsLockRemapping() {
        let fallbackCanConsumeF17 = isStarted && (
            !hasCompleteCarbonHandling ||
                FocusGroupPhysicalKeyRecordingCoordinator.shared.isRecording ||
                eventTap.map(CFMachPortIsValid) == true
        )
        let shouldRemapCapsLock = binding.usesCapsLock &&
            (carbonCanHandleCapsLock || fallbackCanConsumeF17)
        capsLockStateController.setRemappingEnabled(shouldRemapCapsLock)
    }

    private var carbonCanHandleCapsLock: Bool {
        let capsLockGroupNumber: Int
        if Int64(binding.groupOneKey.keyCode) == FocusGroupPhysicalKeyBinding.capsLockKeyCode {
            capsLockGroupNumber = 1
        } else if Int64(binding.groupTwoKey.keyCode) == FocusGroupPhysicalKeyBinding.capsLockKeyCode {
            capsLockGroupNumber = 2
        } else {
            return false
        }

        return carbonHandledCommands.contains(
            FocusGroupCycleCommand(groupNumber: capsLockGroupNumber, reverse: false)
        ) || carbonHandledCommands.contains(
            FocusGroupCycleCommand(groupNumber: capsLockGroupNumber, reverse: true)
        )
    }

    private func scheduleCapsLockRemappingUpdate() {
        // Binding changes can be delivered while the recorded key is still held.
        // Reconcile on the next run-loop turn so key-down and key-up use one mapping.
        guard !reconciliationIsScheduled else {
            return
        }

        reconciliationIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.reconciliationIsScheduled = false
            self.synchronizeCapsLockRemapping()
            self.reconcileEventTap()
            self.turnCapsLockOffIfNeeded()
            self.updateCapsLockMappingHealthTimer()
        }
    }

    private func updateCapsLockMappingHealthTimer() {
        let shouldMonitor = isStarted &&
            binding.usesCapsLock
        guard shouldMonitor else {
            capsLockMappingHealthTimer?.invalidate()
            capsLockMappingHealthTimer = nil
            return
        }
        guard capsLockMappingHealthTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkCapsLockMappingHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        capsLockMappingHealthTimer = timer
    }

    private func checkCapsLockMappingHealth() {
        guard !capsLockMappingHealthCheckIsRunning else {
            return
        }

        capsLockMappingHealthCheckIsRunning = true
        Task.detached(priority: .utility) {
            let mappingIsComplete = CapsLockStateController.systemHasCompleteCapsLockToF17Mapping()
            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }

                self.capsLockMappingHealthCheckIsRunning = false
                guard self.capsLockMappingHealthTimer != nil,
                      !mappingIsComplete else {
                    return
                }

                // The keyboard service may appear late at launch, or either an owned or
                // external mapping may disappear later. Reassert the requested mapping.
                self.synchronizeCapsLockRemapping()
                self.reconcileEventTap()
                self.turnCapsLockOffIfNeeded()
                self.updateCapsLockMappingHealthTimer()
            }
        }
    }

    private func perform(_ command: FocusGroupCycleCommand) {
        Task { @MainActor [handler] in
            handler(command)
        }
    }
}

final class CapsLockStateController {
    private typealias RawKeyMapping = [String: NSNumber]

    private struct StoredKeyMapping: Codable, Equatable {
        let source: UInt64
        let destination: UInt64

        nonisolated init(source: UInt64, destination: UInt64) {
            self.source = source
            self.destination = destination
        }

        nonisolated init?(_ mapping: RawKeyMapping) {
            guard let source = mapping[kIOHIDKeyboardModifierMappingSrcKey]?.uint64Value,
                  let destination = mapping[kIOHIDKeyboardModifierMappingDstKey]?.uint64Value else {
                return nil
            }

            self.source = source
            self.destination = destination
        }

        nonisolated var rawValue: RawKeyMapping {
            [
                kIOHIDKeyboardModifierMappingSrcKey: NSNumber(value: source),
                kIOHIDKeyboardModifierMappingDstKey: NSNumber(value: destination)
            ]
        }
    }

    private struct RecoverySnapshot: Codable {
        let registryID: UInt64
        let originalCapsLockMappings: [StoredKeyMapping]
    }

    private struct RecoveryJournal: Codable {
        let version: Int
        let bootSessionIdentifier: String?
        let snapshots: [RecoverySnapshot]
    }

    private struct KeyboardServiceRecord {
        let registryID: UInt64
        let service: IOHIDServiceClient
    }

    private static let recoveryJournalVersion = 1
    private static let recoveryJournalDefaultsKey = "WindowBuddy.focusGroupCapsLockRemapRecovery.v1"
    nonisolated private static let capsLockUsage = (UInt64(kHIDPage_KeyboardOrKeypad) << 32) |
        UInt64(kHIDUsage_KeyboardCapsLock)
    nonisolated private static let f17Usage = (UInt64(kHIDPage_KeyboardOrKeypad) << 32) |
        UInt64(kHIDUsage_KeyboardF17)

    private let eventSystemClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let userDefaults: UserDefaults
    private var recoverySnapshots: [UInt64: [StoredKeyMapping]]
    private var isMonitoringKeyboardChanges = false
    private var isRemappingEnabled = false
    private var keyboardChangeGeneration = 0
    var keyboardMappingDidReconcile: (() -> Void)?
    private(set) var isUsingExternalCapsLockToF17Mapping = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        recoverySnapshots = Self.loadRecoverySnapshots(from: userDefaults)
    }

    deinit {
        stopMonitoringKeyboardChanges()
    }

    func startMonitoringKeyboardChanges() {
        guard !isMonitoringKeyboardChanges else {
            return
        }

        let keyboardMatching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(hidManager, keyboardMatching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager,
                                                   capsLockKeyboardDeviceChanged,
                                                   context)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager,
                                                  capsLockKeyboardDeviceChanged,
                                                  context)

        guard IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }

        IOHIDManagerScheduleWithRunLoop(hidManager,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)
        isMonitoringKeyboardChanges = true
    }

    func stopMonitoringKeyboardChanges() {
        keyboardChangeGeneration &+= 1
        guard isMonitoringKeyboardChanges else {
            return
        }

        IOHIDManagerUnscheduleFromRunLoop(hidManager,
                                          CFRunLoopGetMain(),
                                          CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        isMonitoringKeyboardChanges = false
    }

    func setRemappingEnabled(_ enabled: Bool) {
        isRemappingEnabled = enabled
        if enabled {
            installCapsLockToF17Mapping()
            turnOff()
        } else {
            isUsingExternalCapsLockToF17Mapping = false
            restoreOwnedCapsLockMappings()
        }
    }

    @discardableResult
    func turnOff() -> Bool {
        let services = keyboardServices()
        var allUpdatesSucceeded = true
        for service in services {
            let didUpdate = IOHIDServiceClientSetProperty(
                service,
                kIOHIDServiceCapsLockStateKey as CFString,
                kCFBooleanFalse
            )
            allUpdatesSucceeded = didUpdate && allUpdatesSucceeded
        }

        return !services.isEmpty && allUpdatesSucceeded
    }

    func hasCapsLockToF17Mapping() -> Bool {
        keyboardServices().contains { service in
            guard let mappings = keyMappings(for: service) else {
                return false
            }

            return mappings.contains(where: Self.isCapsLockToF17Mapping)
        }
    }

    func hasCompleteCapsLockToF17Mapping() -> Bool {
        let services = keyboardServices()
        guard !services.isEmpty else {
            return false
        }

        return services.allSatisfy { service in
            guard let mappings = keyMappings(for: service) else {
                return false
            }

            return mappings.contains(where: Self.isCapsLockToF17Mapping)
        }
    }

    nonisolated static func systemHasCompleteCapsLockToF17Mapping() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) else {
            return false
        }

        var foundKeyboard = false
        for case let service as IOHIDServiceClient in services as NSArray
        where IOHIDServiceClientConformsTo(service,
                                           UInt32(kHIDPage_GenericDesktop),
                                           UInt32(kHIDUsage_GD_Keyboard)) != 0 {
            foundKeyboard = true
            guard let property = IOHIDServiceClientCopyProperty(
                service,
                kIOHIDUserKeyUsageMapKey as CFString
            ),
                let mappings = property as? [[String: NSNumber]],
                mappings.contains(where: Self.isCapsLockToF17Mapping) else {
                return false
            }
        }

        return foundKeyboard
    }

    fileprivate func keyboardDeviceListChanged() {
        guard isRemappingEnabled else {
            return
        }

        keyboardChangeGeneration &+= 1
        let generation = keyboardChangeGeneration
        // IOHIDManager can announce a device just before its event service appears.
        // A short deferral lets the per-service mapping be applied on the first try.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.isRemappingEnabled,
                  self.keyboardChangeGeneration == generation else {
                return
            }
            self.installCapsLockToF17Mapping()
            self.turnOff()
            self.keyboardMappingDidReconcile?()
        }
    }

    private func installCapsLockToF17Mapping() {
        for record in keyboardServiceRecords() {
            guard let currentMappings = keyMappings(for: record.service) else {
                continue
            }

            if recoverySnapshots[record.registryID] != nil {
                if Self.hasOnlyOwnedCapsLockMapping(currentMappings) {
                    continue
                }

                // Another remapper replaced the Caps source after our write. Relinquish
                // the stale snapshot before considering the new live value.
                recoverySnapshots.removeValue(forKey: record.registryID)
                persistRecoverySnapshots()
            }

            // An identical pre-existing Caps -> F17 mapping is external. Use it, but do
            // not claim ownership or remove it when WindowBuddy stops.
            if currentMappings.contains(where: Self.isCapsLockToF17Mapping) {
                continue
            }

            let rawCapsLockMappings = currentMappings.filter(Self.hasCapsLockSource)
            let storedCapsLockMappings = rawCapsLockMappings.compactMap(StoredKeyMapping.init)
            guard storedCapsLockMappings.count == rawCapsLockMappings.count else {
                continue
            }

            let replacementMappings = currentMappings.filter { !Self.hasCapsLockSource($0) } + [
                StoredKeyMapping(source: Self.capsLockUsage,
                                 destination: Self.f17Usage).rawValue
            ]

            // Persist before changing the system property so a crash between the two
            // operations can be repaired on the next launch.
            recoverySnapshots[record.registryID] = storedCapsLockMappings
            persistRecoverySnapshots()

            guard setKeyMappings(replacementMappings, for: record.service) else {
                recoverySnapshots.removeValue(forKey: record.registryID)
                persistRecoverySnapshots()
                continue
            }
        }

        refreshExternalCapsLockMappingState()
    }

    private func refreshExternalCapsLockMappingState() {
        isUsingExternalCapsLockToF17Mapping = keyboardServiceRecords().contains { record in
            guard recoverySnapshots[record.registryID] == nil,
                  let mappings = keyMappings(for: record.service) else {
                return false
            }

            return mappings.contains(where: Self.isCapsLockToF17Mapping)
        }
    }

    private func restoreOwnedCapsLockMappings() {
        guard !recoverySnapshots.isEmpty else {
            return
        }

        let servicesByRegistryID = Dictionary(
            uniqueKeysWithValues: keyboardServiceRecords().map { ($0.registryID, $0.service) }
        )

        for (registryID, originalCapsLockMappings) in recoverySnapshots {
            guard let service = servicesByRegistryID[registryID] else {
                // UserKeyMapping is scoped to the lifetime of the keyboard service.
                recoverySnapshots.removeValue(forKey: registryID)
                continue
            }
            guard let currentMappings = keyMappings(for: service) else {
                continue
            }
            guard Self.hasOnlyOwnedCapsLockMapping(currentMappings) else {
                // A different app now owns the Caps source. Never overwrite its change.
                recoverySnapshots.removeValue(forKey: registryID)
                continue
            }

            let restoredMappings = currentMappings.filter { !Self.hasCapsLockSource($0) } +
                originalCapsLockMappings.map(\.rawValue)
            guard setKeyMappings(restoredMappings, for: service) else {
                continue
            }

            recoverySnapshots.removeValue(forKey: registryID)
        }

        persistRecoverySnapshots()
    }

    nonisolated private static func hasCapsLockSource(_ mapping: RawKeyMapping) -> Bool {
        mapping[kIOHIDKeyboardModifierMappingSrcKey]?.uint64Value == capsLockUsage
    }

    nonisolated private static func isCapsLockToF17Mapping(_ mapping: RawKeyMapping) -> Bool {
        hasCapsLockSource(mapping) &&
            mapping[kIOHIDKeyboardModifierMappingDstKey]?.uint64Value == f17Usage
    }

    nonisolated private static func hasOnlyOwnedCapsLockMapping(_ mappings: [RawKeyMapping]) -> Bool {
        let capsLockMappings = mappings.filter(hasCapsLockSource)
        return capsLockMappings.count == 1 &&
            capsLockMappings.first.map(isCapsLockToF17Mapping) == true
    }

    private func keyMappings(for service: IOHIDServiceClient) -> [RawKeyMapping]? {
        guard let property = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDUserKeyUsageMapKey as CFString
        ) else {
            return []
        }

        return property as? [RawKeyMapping]
    }

    private func setKeyMappings(_ mappings: [RawKeyMapping],
                                for service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientSetProperty(
            service,
            kIOHIDUserKeyUsageMapKey as CFString,
            mappings as CFArray
        )
    }

    private func keyboardServiceRecords() -> [KeyboardServiceRecord] {
        keyboardServices().compactMap { service in
            guard let registryID = IOHIDServiceClientGetRegistryID(service) as? NSNumber else {
                return nil
            }

            return KeyboardServiceRecord(registryID: registryID.uint64Value,
                                         service: service)
        }
    }

    private static func loadRecoverySnapshots(from userDefaults: UserDefaults) -> [UInt64: [StoredKeyMapping]] {
        guard let data = userDefaults.data(forKey: recoveryJournalDefaultsKey),
              let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: data),
              journal.version == recoveryJournalVersion,
              journal.bootSessionIdentifier == bootSessionIdentifier() else {
            return [:]
        }

        return journal.snapshots.reduce(into: [:]) { snapshots, snapshot in
            snapshots[snapshot.registryID] = snapshot.originalCapsLockMappings
        }
    }

    private func persistRecoverySnapshots() {
        guard !recoverySnapshots.isEmpty else {
            userDefaults.removeObject(forKey: Self.recoveryJournalDefaultsKey)
            userDefaults.synchronize()
            return
        }

        let journal = RecoveryJournal(
            version: Self.recoveryJournalVersion,
            bootSessionIdentifier: Self.bootSessionIdentifier(),
            snapshots: recoverySnapshots.keys.sorted().map { registryID in
                RecoverySnapshot(registryID: registryID,
                                 originalCapsLockMappings: recoverySnapshots[registryID] ?? [])
            }
        )
        guard let data = try? JSONEncoder().encode(journal) else {
            return
        }

        userDefaults.set(data, forKey: Self.recoveryJournalDefaultsKey)
        userDefaults.synchronize()
    }

    nonisolated private static func bootSessionIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else {
            return nil
        }

        var bytes = [CChar](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("kern.bootsessionuuid", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return nil
        }

        return String(cString: bytes)
    }

    private func keyboardServices() -> [IOHIDServiceClient] {
        guard let services = IOHIDEventSystemClientCopyServices(eventSystemClient) else {
            return []
        }

        var keyboards: [IOHIDServiceClient] = []
        for case let service as IOHIDServiceClient in services as NSArray
        where IOHIDServiceClientConformsTo(service,
                                           UInt32(kHIDPage_GenericDesktop),
                                           UInt32(kHIDUsage_GD_Keyboard)) != 0 {
            keyboards.append(service)
        }
        return keyboards
    }
}

private let capsLockKeyboardDeviceChanged: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context else {
        return
    }

    Unmanaged<CapsLockStateController>
        .fromOpaque(context)
        .takeUnretainedValue()
        .keyboardDeviceListChanged()
}

private let focusGroupPhysicalKeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<FocusGroupPhysicalKeyController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return controller.handleEvent(type: type, event: event)
}
