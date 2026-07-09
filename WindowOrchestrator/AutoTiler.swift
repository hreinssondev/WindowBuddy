//
//  AutoTiler.swift
//  WindowBuddy
//
//  Created by Codex on 02/06/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AutoTileVisibilityResult {
    let didHide: Bool
    let affectedApplicationCount: Int
    let skippedWindowCount: Int
}

enum AutoTileLayoutMode: String, CaseIterable, Identifiable {
    case sharedGrid
    case splitOriginal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .sharedGrid: "Grid"
        case .splitOriginal: "Split First"
        }
    }
}

enum AutoTileScreenLayoutMode: String, CaseIterable, Identifiable {
    case halfScreen
    case twoThirdsScreen
    case fullScreen
    case gridScreen
    case verticalScreen

    static let standardCases: [AutoTileScreenLayoutMode] = [
        .gridScreen,
        .halfScreen,
        .twoThirdsScreen,
        .fullScreen,
        .verticalScreen
    ]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .halfScreen: "1/2"
        case .twoThirdsScreen: "2/3"
        case .fullScreen: "4/4"
        case .gridScreen: "1/3"
        case .verticalScreen: "Top/Bottom"
        }
    }

    var primaryFraction: CGFloat {
        switch self {
        case .halfScreen: 0.5
        case .twoThirdsScreen: 2.0 / 3.0
        case .fullScreen: 1.0
        case .gridScreen: 1.0 / 3.0
        case .verticalScreen: 0.5
        }
    }

    var primaryWidthFraction: CGFloat {
        primaryFraction
    }

    var splitDirection: AutoTileSplitDirection {
        switch self {
        case .halfScreen, .twoThirdsScreen, .fullScreen, .gridScreen: .horizontal
        case .verticalScreen: .vertical
        }
    }

    var prioritizesFirstWindow: Bool {
        switch self {
        case .twoThirdsScreen: true
        case .halfScreen, .fullScreen, .gridScreen, .verticalScreen: false
        }
    }
}

enum AutoTileSplitDirection {
    case horizontal
    case vertical
}

enum AutoTileDirection: String, CaseIterable, Identifiable {
    case leftToRight
    case centerOut
    case rightToLeft

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .leftToRight: "Left"
        case .centerOut: "Center"
        case .rightToLeft: "Right"
        }
    }
}

enum AutoTileIgnoredSecondWindowStartMode: String, CaseIterable, Identifiable {
    case normalStart
    case middleStart

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .normalStart: "Right"
        case .middleStart: "Left"
        }
    }
}

enum AutoTileSpeedMode: String, CaseIterable, Identifiable {
    case normal

    var id: String {
        rawValue
    }

    var title: String {
        "Normal"
    }
}

enum AutoTileFocusedResizeMode: String, CaseIterable, Identifiable {
    case resizesWithFocus
    case keepsSizeOnFocus

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .resizesWithFocus: "Resize on Focus"
        case .keepsSizeOnFocus: "Keep Same Size"
        }
    }
}

struct AutoTileTemporaryRemovalResult {
    let applicationName: String
    let frame: CGRect
    let didFillScreen: Bool
    let removedFromTiling: Bool
    let retileResult: AutoTileResult?
}

struct AutoTileTemporaryRestoreResult {
    let applicationName: String
    let retileResult: AutoTileResult
}

enum AutoTileTemporaryRemovalError: LocalizedError {
    case noRemovedWindowToRestore

    var errorDescription: String? {
        switch self {
        case .noRemovedWindowToRestore:
            "There is no full-size window waiting to return to tiling."
        }
    }
}

private struct TemporarilyRemovedAutoTileWindow {
    let id: AutoTileWindowID
    let fingerprint: AutoTileWindowFingerprint?
    let applicationName: String
    let groupIdentifiers: Set<Int>
}

@MainActor
final class AutoTiler {
    typealias Handler = (Result<AutoTileResult, Error>) -> Void

    private let mover: AccessibilityWindowMover
    private let handler: Handler
    private var timer: Timer?
    private var mainAppFocusTimer: Timer?
    private var pendingScanWorkItem: DispatchWorkItem?
    private var pendingFocusedWindowRetileWorkItem: DispatchWorkItem?
    private var knownWindowsByID: [AutoTileWindowID: CGRect] = [:]
    private var tiledWindowIDs: Set<AutoTileWindowID> = []
    private var windowGroupIdentifiersByID: [AutoTileWindowID: Set<Int>] = [:]
    private var orderedWindowIDs: [AutoTileWindowID] = []
    private var orderedWindowIDsByGroup: [Int: [AutoTileWindowID]] = [:]
    private var rememberedWindowSlotsByGroup: [Int: [AutoTileWindowFingerprint: Int]] = [:]
    private var enlargedWindowIDsByGroup: [Int: AutoTileWindowID] = [:]
    private var enlargedWindowFingerprintsByGroup: [Int: AutoTileWindowFingerprint] = [:]
    private var enlargedWindowSlotsByGroup: [Int: Int] = [:]
    private var groupsWithMultipleVisibleWindows: Set<Int> = []
    private var keepsForcedTileLayoutStable = false
    private var forcedTileFramesByWindowID: [AutoTileWindowID: CGRect] = [:]
    private var pendingSettledRetileWorkItems: [DispatchWorkItem] = []
    private var pendingRetileReinforcementWorkItems: [DispatchWorkItem] = []
    private var pendingMainAppRetileWorkItems: [DispatchWorkItem] = []
    private var pendingFocusGroupRetileWorkItems: [DispatchWorkItem] = []
    private var pendingForcedTileRestoreWorkItems: [DispatchWorkItem] = []
    private var lastOpeningContext: AutoTileOpeningContext?
    private var temporarilyRemovedWindowsByID: [AutoTileWindowID: TemporarilyRemovedAutoTileWindow] = [:]
    private var mostRecentlyTemporarilyRemovedWindowID: AutoTileWindowID?
    private var hiddenScreenRevealProcessIdentifiers: Set<pid_t> = []
    private var propagatedHiddenBundleIdentifiers: Set<String> = []
    private var focusGroupSwitchHiddenBundleIdentifiers: Set<String> = []
    private var propagatedUnhiddenBundleIdentifiers: Set<String> = []
    private var manuallyAdjustedWindowIDs: Set<AutoTileWindowID> = []
    private var windowIDsPendingManualEvaluation: Set<AutoTileWindowID> = []
    private var pendingManualAdjustmentWorkItem: DispatchWorkItem?
    private var appliedFrameByWindowID: [AutoTileWindowID: CGRect] = [:]
    private var isApplyingTile = false
    private var isStarted = false
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var observedApplicationsByProcessIdentifier: [pid_t: ObservedApplication] = [:]
    private var lastMainAppFocusReassertion: (bundleIdentifier: String, date: Date)?
    private let eventScanDelay: TimeInterval = 0.03
    private let fallbackScanInterval: TimeInterval = 2.0
    private let mainAppFocusInterval: TimeInterval = 0.5
    private let mainAppFocusReassertionInterval: TimeInterval = 1.2
    private var allowedBundleIdentifiers: Set<String> {
        Set(appGroupIdentifiersByBundleIdentifier.keys)
    }

    var layoutMode: AutoTileLayoutMode {
        didSet {
            guard oldValue != layoutMode else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var focusTileWiderFixedBundleIdentifiers: Set<String> {
        didSet {
            guard oldValue != focusTileWiderFixedBundleIdentifiers else {
                return
            }

            scheduleFocusedWindowRetile()
        }
    }

    var widensFocusedWindow: Bool {
        didSet {
            guard oldValue != widensFocusedWindow else {
                return
            }

            if widensFocusedWindow {
                scheduleFocusedWindowRetile()
            } else {
                enlargedWindowIDsByGroup = [:]
                enlargedWindowFingerprintsByGroup = [:]
                enlargedWindowSlotsByGroup = [:]
                if isRunning {
                    retileVisibleWindows()
                }
            }
        }
    }

    var focusedWindowPrimaryWidthFraction: CGFloat {
        didSet {
            guard oldValue != focusedWindowPrimaryWidthFraction else {
                return
            }

            scheduleFocusedWindowRetile()
        }
    }

    var movesExistingAppWindowsToFocusedGroup: Bool
    var revealsActiveGroupApps: Bool

    var appGroupIdentifiersByBundleIdentifier: [String: Set<Int>] {
        didSet {
            guard oldValue != appGroupIdentifiersByBundleIdentifier else {
                return
            }

            if isRunning {
                refreshKnownWindows()
            }
        }
    }

    var appBundleIdentifiersByGroup: [Int: [String]] {
        didSet {
            guard oldValue != appBundleIdentifiersByGroup else {
                return
            }

            if isRunning {
                refreshKnownWindows()
            }
        }
    }

    var mainAppBundleIdentifiersByGroup: [Int: [String]] {
        didSet {
            mainAppBundleIdentifiersByGroup = normalizedMainAppBundleIdentifiersByGroup(mainAppBundleIdentifiersByGroup)

            guard oldValue != mainAppBundleIdentifiersByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var fillsFirstWindowByGroup: [Int: Bool] {
        didSet {
            guard oldValue != fillsFirstWindowByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var screenLayoutModeByGroup: [Int: AutoTileScreenLayoutMode] {
        didSet {
            guard oldValue != screenLayoutModeByGroup else {
                return
            }

            usesHalfFirstTileSplitByGroup = Dictionary(uniqueKeysWithValues: screenLayoutModeByGroup.map { groupIdentifier, screenLayoutMode in
                (groupIdentifier, screenLayoutMode.splitDirection == .horizontal && screenLayoutMode.primaryWidthFraction == 0.5)
            })

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var maximumColumnCountByGroup: [Int: Int] {
        didSet {
            guard oldValue != maximumColumnCountByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var tileDirectionByGroup: [Int: AutoTileDirection] {
        didSet {
            guard oldValue != tileDirectionByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var usesHalfFirstTileSplitByGroup: [Int: Bool] {
        didSet {
            guard oldValue != usesHalfFirstTileSplitByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var ignoresSecondAppInListByGroup: [Int: Bool] {
        didSet {
            guard oldValue != ignoresSecondAppInListByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var ignoredSecondWindowStartModeByGroup: [Int: AutoTileIgnoredSecondWindowStartMode] {
        didSet {
            guard oldValue != ignoredSecondWindowStartModeByGroup else {
                return
            }

            if isRunning {
                retileVisibleWindows()
            }
        }
    }

    var isRunning: Bool {
        isStarted
    }

    init(mover: AccessibilityWindowMover,
         appGroupIdentifiersByBundleIdentifier: [String: Set<Int>],
         appBundleIdentifiersByGroup: [Int: [String]],
         mainAppBundleIdentifiersByGroup: [Int: [String]],
         layoutMode: AutoTileLayoutMode,
         speedMode: AutoTileSpeedMode = .normal,
         focusTileWiderFixedBundleIdentifiers: Set<String> = [],
         widensFocusedWindow: Bool = false,
         focusedWindowPrimaryWidthFraction: CGFloat = 2.0 / 3.0,
         movesExistingAppWindowsToFocusedGroup: Bool = false,
         revealsActiveGroupApps: Bool = false,
         fillsFirstWindowByGroup: [Int: Bool],
         screenLayoutModeByGroup: [Int: AutoTileScreenLayoutMode] = [:],
         maximumColumnCountByGroup: [Int: Int] = [:],
         tileDirectionByGroup: [Int: AutoTileDirection] = [:],
         usesHalfFirstTileSplitByGroup: [Int: Bool]? = nil,
         ignoresSecondAppInListByGroup: [Int: Bool],
         ignoredSecondWindowStartModeByGroup: [Int: AutoTileIgnoredSecondWindowStartMode],
         handler: @escaping Handler) {
        self.mover = mover
        self.appGroupIdentifiersByBundleIdentifier = appGroupIdentifiersByBundleIdentifier
        self.appBundleIdentifiersByGroup = appBundleIdentifiersByGroup
        self.mainAppBundleIdentifiersByGroup = mainAppBundleIdentifiersByGroup
        self.layoutMode = layoutMode
        self.focusTileWiderFixedBundleIdentifiers = focusTileWiderFixedBundleIdentifiers
        self.widensFocusedWindow = widensFocusedWindow
        self.focusedWindowPrimaryWidthFraction = focusedWindowPrimaryWidthFraction
        self.movesExistingAppWindowsToFocusedGroup = movesExistingAppWindowsToFocusedGroup
        self.revealsActiveGroupApps = revealsActiveGroupApps
        self.fillsFirstWindowByGroup = fillsFirstWindowByGroup
        self.screenLayoutModeByGroup = screenLayoutModeByGroup
        self.maximumColumnCountByGroup = maximumColumnCountByGroup
        self.tileDirectionByGroup = tileDirectionByGroup
        self.usesHalfFirstTileSplitByGroup = usesHalfFirstTileSplitByGroup ??
            Dictionary(uniqueKeysWithValues: screenLayoutModeByGroup.map { groupIdentifier, screenLayoutMode in
                (groupIdentifier, screenLayoutMode.splitDirection == .horizontal && screenLayoutMode.primaryWidthFraction == 0.5)
            })
        self.ignoresSecondAppInListByGroup = ignoresSecondAppInListByGroup
        self.ignoredSecondWindowStartModeByGroup = ignoredSecondWindowStartModeByGroup
        self.handler = handler
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard !isRunning, !allowedBundleIdentifiers.isEmpty else {
            return
        }

        isStarted = true
        installWorkspaceObservers()
        refreshAccessibilityObservers()
        refreshKnownWindows()
        scheduleFallbackScan()
        scheduleMainAppFocusWatch()
        scheduleFocusedWindowRetile()
    }

    private func scheduleFallbackScan() {
        guard isRunning else {
            return
        }

        timer?.invalidate()

        let timer = Timer(timeInterval: fallbackScanInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.timer = nil
                _ = self.scanForNewWindows()
                self.scheduleFallbackScan()
            }
        }

        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleMainAppFocusWatch() {
        mainAppFocusTimer?.invalidate()

        let timer = Timer(timeInterval: mainAppFocusInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertMainAppsForFrontmostApplication()
            }
        }

        mainAppFocusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        isStarted = false

        if !hiddenScreenRevealProcessIdentifiers.isEmpty {
            _ = mover.setApplications(hiddenScreenRevealProcessIdentifiers, hidden: false)
        }

        timer?.invalidate()
        timer = nil
        mainAppFocusTimer?.invalidate()
        mainAppFocusTimer = nil
        pendingScanWorkItem?.cancel()
        pendingScanWorkItem = nil
        pendingFocusedWindowRetileWorkItem?.cancel()
        pendingFocusedWindowRetileWorkItem = nil
        removeWorkspaceObservers()
        removeAccessibilityObservers()
        knownWindowsByID = [:]
        tiledWindowIDs = []
        windowGroupIdentifiersByID = [:]
        orderedWindowIDs = []
        orderedWindowIDsByGroup = [:]
        rememberedWindowSlotsByGroup = [:]
        enlargedWindowIDsByGroup = [:]
        enlargedWindowFingerprintsByGroup = [:]
        enlargedWindowSlotsByGroup = [:]
        groupsWithMultipleVisibleWindows = []
        keepsForcedTileLayoutStable = false
        forcedTileFramesByWindowID = [:]
        pendingSettledRetileWorkItems.forEach { $0.cancel() }
        pendingSettledRetileWorkItems = []
        pendingRetileReinforcementWorkItems.forEach { $0.cancel() }
        pendingRetileReinforcementWorkItems = []
        pendingMainAppRetileWorkItems.forEach { $0.cancel() }
        pendingMainAppRetileWorkItems = []
        pendingFocusGroupRetileWorkItems.forEach { $0.cancel() }
        pendingFocusGroupRetileWorkItems = []
        pendingForcedTileRestoreWorkItems.forEach { $0.cancel() }
        pendingForcedTileRestoreWorkItems = []
        lastOpeningContext = nil
        temporarilyRemovedWindowsByID = [:]
        mostRecentlyTemporarilyRemovedWindowID = nil
        manuallyAdjustedWindowIDs = []
        windowIDsPendingManualEvaluation = []
        pendingManualAdjustmentWorkItem?.cancel()
        pendingManualAdjustmentWorkItem = nil
        appliedFrameByWindowID = [:]
        lastMainAppFocusReassertion = nil
        hiddenScreenRevealProcessIdentifiers = []
        propagatedHiddenBundleIdentifiers = []
        focusGroupSwitchHiddenBundleIdentifiers = []
        propagatedUnhiddenBundleIdentifiers = []
        isApplyingTile = false
    }

    func resetSavedOrder() {
        orderedWindowIDs = []
        orderedWindowIDsByGroup = [:]
        rememberedWindowSlotsByGroup = [:]
        refreshKnownWindows()
        if widensFocusedWindow {
            scheduleFocusedWindowRetile()
        } else {
            retileVisibleWindows()
        }
    }

    func retileVisibleGroup(_ groupIdentifier: Int,
                            cancelsPendingRetiles: Bool = true) throws -> AutoTileResult {
        guard !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty,
              !keepsForcedTileLayoutStable,
              isRunning else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        if cancelsPendingRetiles {
            cancelPendingRetiles()
        }

        let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
        refreshAccessibilityObservers(visibleWindows: visibleWindows)
        synchronizeTemporarilyRemovedWindows(with: visibleWindows)

        let windows = activeAutoTileWindows(from: visibleWindows)
        let windowIDs = Set(windows.map(\.id))
        reconcileWindowGroupIdentifiers(for: windows,
                                        newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)

        let groupWindows = windows.filter { groupIdentifiers(for: $0).contains(groupIdentifier) }
        guard !groupWindows.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        updateGroupWindowOrders(for: windows)
        rememberLeadingWindowSlots(from: windows)
        orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                              windows: windows)
        knownWindowsByID = Self.windowScreenFramesByID(visibleWindows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()

        let affectedScreenFrames = Dictionary(grouping: groupWindows,
                                              by: { AutoTileScreenKey($0.screenVisibleFrame) })
            .values
            .compactMap { $0.first?.screenVisibleFrame }
        guard !affectedScreenFrames.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        return try autoTileGroups(windows: windows,
                                  affectedScreenFrames: affectedScreenFrames,
                                  targetGroupIdentifiers: [groupIdentifier])
    }

    func scheduleFocusGroupRetiles(_ groupIdentifier: Int) {
        pendingFocusGroupRetileWorkItems.forEach { $0.cancel() }
        pendingFocusGroupRetileWorkItems = []

        guard isRunning,
              !keepsForcedTileLayoutStable else {
            return
        }

        for delay in [0.08, 0.22, 0.5, 0.9] {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    guard !self.keepsForcedTileLayoutStable else {
                        return
                    }

                    do {
                        let result = try self.retileVisibleGroup(groupIdentifier,
                                                                 cancelsPendingRetiles: false)
                        if result.tiledWindowCount > 0 {
                            self.handler(.success(result))
                        }
                    } catch {
                        self.handler(.failure(error))
                    }
                }
            }

            pendingFocusGroupRetileWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func suppressFocusGroupSwitchHideNotifications(for bundleIdentifiers: Set<String>) {
        guard !bundleIdentifiers.isEmpty else {
            return
        }

        focusGroupSwitchHiddenBundleIdentifiers.formUnion(bundleIdentifiers)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.focusGroupSwitchHiddenBundleIdentifiers.subtract(bundleIdentifiers)
            }
        }
    }

    func resizeTiledWindowsIncludingOffscreen() throws -> AutoTileResult {
        guard !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty,
              isRunning else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        cancelPendingRetiles()
        clearFocusedPrimaryState()
        keepsForcedTileLayoutStable = true

        let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers,
                                                              includesOffscreenWindows: true)
        refreshAccessibilityObservers(visibleWindows: visibleWindows)
        synchronizeTemporarilyRemovedWindows(with: visibleWindows)

        let windows = activeAutoTileWindows(from: visibleWindows)
        let windowIDs = Set(windows.map(\.id))
        reconcileWindowGroupIdentifiers(for: windows,
                                        newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)
        updateGroupWindowOrders(for: windows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()
        let affectedScreenFrames = Dictionary(grouping: windows, by: { AutoTileScreenKey($0.screenVisibleFrame) })
            .values
            .compactMap { $0.first?.screenVisibleFrame }

        guard !affectedScreenFrames.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        rememberLeadingWindowSlots(from: windows)
        orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                              windows: windows)
        knownWindowsByID = Self.windowScreenFramesByID(visibleWindows)

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        let result = try autoTileGroups(windows: windows,
                                        affectedScreenFrames: affectedScreenFrames)
        captureForcedTileLayoutSnapshot()
        return result
    }

    func toggleScreenCoveringWindowVisibility() throws -> AutoTileVisibilityResult {
        if !hiddenScreenRevealProcessIdentifiers.isEmpty {
            let shownApplicationCount = mover.setApplications(hiddenScreenRevealProcessIdentifiers, hidden: false)
            hiddenScreenRevealProcessIdentifiers = []

            return AutoTileVisibilityResult(didHide: false,
                                            affectedApplicationCount: shownApplicationCount,
                                            skippedWindowCount: 0)
        }

        let processIdentifiers = try mover.visibleApplicationProcessIdentifiersCoveringActiveScreen()
        guard !processIdentifiers.isEmpty else {
            return AutoTileVisibilityResult(didHide: true,
                                            affectedApplicationCount: 0,
                                            skippedWindowCount: 0)
        }

        let hiddenApplicationCount = mover.setApplications(processIdentifiers, hidden: true)
        hiddenScreenRevealProcessIdentifiers = processIdentifiers

        return AutoTileVisibilityResult(didHide: true,
                                        affectedApplicationCount: hiddenApplicationCount,
                                        skippedWindowCount: 0)
    }

    func temporarilyRemoveFromTilingAndFill(_ target: WindowTarget) throws -> AutoTileTemporaryRemovalResult {
        let result = try mover.applyPreferredOpeningSize(target)

        guard isRunning,
              !allowedBundleIdentifiers.isEmpty else {
            return AutoTileTemporaryRemovalResult(applicationName: target.applicationName,
                                                 frame: result.frame,
                                                 didFillScreen: result.didFillScreen,
                                                 removedFromTiling: false,
                                                 retileResult: nil)
        }

        let focusedFallbackWindowID = AutoTileWindowID(processIdentifier: target.processIdentifier,
                                                       elementHash: Int(CFHash(target.window)))
        cancelPendingRetiles()

        let windows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
        refreshAccessibilityObservers(visibleWindows: windows)
        synchronizeTemporarilyRemovedWindows(with: windows)

        var activeWindows = activeAutoTileWindows(from: windows)
        let activeWindowIDs = Set(activeWindows.map(\.id))
        reconcileWindowGroupIdentifiers(for: activeWindows,
                                        newWindowIDs: activeWindowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)
        updateGroupWindowOrders(for: activeWindows)

        guard let focusedWindow = focusedWindow(matching: target,
                                                fallbackID: focusedFallbackWindowID,
                                                in: activeWindows) else {
            knownWindowsByID = Self.windowScreenFramesByID(windows)
            orderedWindowIDs = updatedWindowOrder(currentWindowIDs: activeWindowIDs,
                                                  windows: activeWindows)
            lastOpeningContext = mover.frontmostAutoTileOpeningContext()
            return AutoTileTemporaryRemovalResult(applicationName: target.applicationName,
                                                 frame: result.frame,
                                                 didFillScreen: result.didFillScreen,
                                                 removedFromTiling: false,
                                                 retileResult: nil)
        }

        let groupIdentifiers = groupIdentifiers(for: focusedWindow)
        guard !groupIdentifiers.isEmpty else {
            knownWindowsByID = Self.windowScreenFramesByID(windows)
            orderedWindowIDs = updatedWindowOrder(currentWindowIDs: activeWindowIDs,
                                                  windows: activeWindows)
            lastOpeningContext = mover.frontmostAutoTileOpeningContext()
            return AutoTileTemporaryRemovalResult(applicationName: target.applicationName,
                                                 frame: result.frame,
                                                 didFillScreen: result.didFillScreen,
                                                 removedFromTiling: false,
                                                 retileResult: nil)
        }

        temporarilyRemovedWindowsByID[focusedWindow.id] = TemporarilyRemovedAutoTileWindow(id: focusedWindow.id,
                                                                                          fingerprint: AutoTileWindowFingerprint(focusedWindow),
                                                                                          applicationName: focusedWindow.applicationName,
                                                                                          groupIdentifiers: groupIdentifiers)
        mostRecentlyTemporarilyRemovedWindowID = focusedWindow.id

        for groupIdentifier in groupIdentifiers {
            if enlargedWindowIDsByGroup[groupIdentifier] == focusedWindow.id {
                enlargedWindowIDsByGroup.removeValue(forKey: groupIdentifier)
                enlargedWindowFingerprintsByGroup.removeValue(forKey: groupIdentifier)
                enlargedWindowSlotsByGroup.removeValue(forKey: groupIdentifier)
            }
        }

        activeWindows = activeAutoTileWindows(from: windows)
        let remainingWindowIDs = Set(activeWindows.map(\.id))
        updateGroupWindowOrders(for: activeWindows)
        rememberLeadingWindowSlots(from: activeWindows)
        orderedWindowIDs = updatedWindowOrder(currentWindowIDs: remainingWindowIDs,
                                              windows: activeWindows)
        knownWindowsByID = Self.windowScreenFramesByID(windows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        let retileResult = try autoTileGroups(windows: activeWindows,
                                              affectedScreenFrames: [focusedWindow.screenVisibleFrame],
                                              targetGroupIdentifiers: Array(groupIdentifiers).sorted())

        return AutoTileTemporaryRemovalResult(applicationName: target.applicationName,
                                             frame: result.frame,
                                             didFillScreen: result.didFillScreen,
                                             removedFromTiling: true,
                                             retileResult: retileResult)
    }

    func restoreMostRecentlyRemovedWindowToTiling() throws -> AutoTileTemporaryRestoreResult {
        guard isRunning,
              !allowedBundleIdentifiers.isEmpty,
              let removalID = mostRecentlyTemporarilyRemovedWindowID,
              let removal = temporarilyRemovedWindowsByID[removalID] else {
            throw AutoTileTemporaryRemovalError.noRemovedWindowToRestore
        }

        cancelPendingRetiles()

        let windows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
        refreshAccessibilityObservers(visibleWindows: windows)

        guard let restoredWindow = temporarilyRemovedWindow(matching: removal, in: windows) else {
            temporarilyRemovedWindowsByID.removeValue(forKey: removalID)
            mostRecentlyTemporarilyRemovedWindowID = temporarilyRemovedWindowsByID.keys.first
            throw AutoTileTemporaryRemovalError.noRemovedWindowToRestore
        }

        temporarilyRemovedWindowsByID.removeValue(forKey: removalID)
        temporarilyRemovedWindowsByID.removeValue(forKey: restoredWindow.id)
        mostRecentlyTemporarilyRemovedWindowID = temporarilyRemovedWindowsByID.keys.first

        var activeWindows = activeAutoTileWindows(from: windows)
        let activeWindowIDs = Set(activeWindows.map(\.id))
        reconcileWindowGroupIdentifiers(for: activeWindows,
                                        newWindowIDs: activeWindowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)
        updateGroupWindowOrders(for: activeWindows)
        rememberLeadingWindowSlots(from: activeWindows)
        orderedWindowIDs = updatedWindowOrder(currentWindowIDs: activeWindowIDs,
                                              windows: activeWindows)
        knownWindowsByID = Self.windowScreenFramesByID(windows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()

        if !activeWindows.contains(where: { $0.id == restoredWindow.id }) {
            activeWindows.append(restoredWindow)
        }

        let targetGroupIdentifiers = groupIdentifiers(for: restoredWindow).isEmpty ?
            removal.groupIdentifiers :
            groupIdentifiers(for: restoredWindow)

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        let retileResult = try autoTileGroups(windows: activeWindows,
                                              affectedScreenFrames: [restoredWindow.screenVisibleFrame],
                                              targetGroupIdentifiers: Array(targetGroupIdentifiers).sorted())

        return AutoTileTemporaryRestoreResult(applicationName: removal.applicationName,
                                             retileResult: retileResult)
    }

    func tileFocusedWindowAsPrimary(_ target: WindowTarget,
                                    primaryWidthFraction: CGFloat) throws -> AutoTileResult {
        try applyFocusedWindowPrimary(target,
                                      primaryWidthFraction: primaryWidthFraction,
                                      shouldEnlarge: true,
                                      togglesExistingPrimary: true)
    }

    func retileAroundMovedWindow(_ target: WindowTarget,
                                 movedFrame: CGRect) throws -> AutoTileResult {
        guard !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        let focusedFallbackWindowID = AutoTileWindowID(processIdentifier: target.processIdentifier,
                                                       elementHash: Int(CFHash(target.window)))
        guard isRunning else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        cancelPendingRetiles()
        keepsForcedTileLayoutStable = false
        forcedTileFramesByWindowID = [:]
        manuallyAdjustedWindowIDs.remove(focusedFallbackWindowID)

        let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
        refreshAccessibilityObservers(visibleWindows: visibleWindows)
        synchronizeTemporarilyRemovedWindows(with: visibleWindows)

        var windows = activeAutoTileWindows(from: visibleWindows)
        let windowIDs = Set(windows.map(\.id))
        reconcileWindowGroupIdentifiers(for: windows,
                                        newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)
        updateGroupWindowOrders(for: windows)

        guard let focusedWindow = focusedWindow(matching: target,
                                                fallbackID: focusedFallbackWindowID,
                                                in: windows),
              let focusedGroupIdentifier = firstConfiguredGroupIdentifier(in: groupIdentifiers(for: focusedWindow)) else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        windows = windows.map { window in
            guard window.id == focusedWindow.id else {
                return window
            }

            return AutoTileWindow(id: window.id,
                                  applicationName: window.applicationName,
                                  bundleIdentifier: window.bundleIdentifier,
                                  title: window.title,
                                  processIdentifier: window.processIdentifier,
                                  window: window.window,
                                  frame: movedFrame,
                                  screenVisibleFrame: window.screenVisibleFrame)
        }

        let focusedWindowID = focusedWindow.id
        let focusedWindowFingerprint = AutoTileWindowFingerprint(focusedWindow)
        enlargedWindowIDsByGroup[focusedGroupIdentifier] = focusedWindowID
        if let focusedWindowFingerprint {
            enlargedWindowFingerprintsByGroup[focusedGroupIdentifier] = focusedWindowFingerprint
        } else {
            enlargedWindowFingerprintsByGroup.removeValue(forKey: focusedGroupIdentifier)
        }
        enlargedWindowSlotsByGroup.removeValue(forKey: focusedGroupIdentifier)

        let groupWindows = windows.filter {
            groupIdentifiers(for: $0).contains(focusedGroupIdentifier)
        }
        orderedWindowIDsByGroup[focusedGroupIdentifier] = Self.defaultWindowOrder(groupWindows)
        orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                              windows: windows)
        knownWindowsByID = Self.windowScreenFramesByID(visibleWindows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        let primaryWidthFraction = Self.primaryWidthFraction(for: movedFrame,
                                                             in: focusedWindow.screenVisibleFrame)
        return try autoTileGroups(windows: windows,
                                  affectedScreenFrames: [focusedWindow.screenVisibleFrame],
                                  targetGroupIdentifiers: [focusedGroupIdentifier],
                                  primaryWidthFractionOverride: primaryWidthFraction,
                                  primaryWindowIDOverride: focusedWindowID,
                                  preservesPrimaryWindowPosition: true)
    }

    private func applyFocusedWindowPrimary(_ target: WindowTarget,
                                           primaryWidthFraction: CGFloat,
                                           shouldEnlarge: Bool,
                                           togglesExistingPrimary: Bool = false) throws -> AutoTileResult {
        guard !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        let focusedFallbackWindowID = AutoTileWindowID(processIdentifier: target.processIdentifier,
                                                       elementHash: Int(CFHash(target.window)))
        guard isRunning else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
        refreshAccessibilityObservers(visibleWindows: visibleWindows)
        synchronizeTemporarilyRemovedWindows(with: visibleWindows)

        let windows = activeAutoTileWindows(from: visibleWindows)
        let windowIDs = Set(windows.map(\.id))
        reconcileWindowGroupIdentifiers(for: windows,
                                        newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                        openingContext: lastOpeningContext)
        updateGroupWindowOrders(for: windows)

        guard let focusedWindow = focusedWindow(matching: target,
                                                fallbackID: focusedFallbackWindowID,
                                                in: windows),
              let focusedGroupIdentifier = firstConfiguredGroupIdentifier(in: groupIdentifiers(for: focusedWindow)) else {
            return AutoTileResult(tiledWindowCount: 0, screenCount: 0, skippedWindowCount: 0)
        }

        let focusedWindowID = focusedWindow.id

        let focusedWindowFingerprint = AutoTileWindowFingerprint(focusedWindow)
        let focusedWindowIsAlreadyEnlarged = enlargedWindowIDsByGroup[focusedGroupIdentifier] == focusedWindowID ||
            (focusedWindowFingerprint.map { enlargedWindowFingerprintsByGroup[focusedGroupIdentifier] == $0 } ?? false)
        let focusedGroupWindows = windows.filter {
            groupIdentifiers(for: $0).contains(focusedGroupIdentifier)
        }
        let focusedWindowSlot = orderedGroupWindows(groupWindows: focusedGroupWindows,
                                                    groupIdentifier: focusedGroupIdentifier).firstIndex { $0.id == focusedWindowID }

        if !shouldEnlarge || (togglesExistingPrimary && focusedWindowIsAlreadyEnlarged) {
            enlargedWindowIDsByGroup.removeValue(forKey: focusedGroupIdentifier)
            enlargedWindowFingerprintsByGroup.removeValue(forKey: focusedGroupIdentifier)
            enlargedWindowSlotsByGroup.removeValue(forKey: focusedGroupIdentifier)
        } else {
            enlargedWindowIDsByGroup[focusedGroupIdentifier] = focusedWindowID
            if let focusedWindowFingerprint {
                enlargedWindowFingerprintsByGroup[focusedGroupIdentifier] = focusedWindowFingerprint
            } else {
                enlargedWindowFingerprintsByGroup.removeValue(forKey: focusedGroupIdentifier)
            }
            enlargedWindowSlotsByGroup[focusedGroupIdentifier] = focusedWindowSlot
        }

        knownWindowsByID = Self.windowScreenFramesByID(visibleWindows)
        lastOpeningContext = mover.frontmostAutoTileOpeningContext()
        rememberLeadingWindowSlots(from: windows)

        isApplyingTile = true
        defer {
            isApplyingTile = false
        }

        if !shouldEnlarge || (togglesExistingPrimary && focusedWindowIsAlreadyEnlarged) {
            return try autoTileGroups(windows: windows,
                                      affectedScreenFrames: [focusedWindow.screenVisibleFrame],
                                      targetGroupIdentifiers: [focusedGroupIdentifier])
        }

        return try autoTileGroups(windows: windows,
                                  affectedScreenFrames: [focusedWindow.screenVisibleFrame],
                                  targetGroupIdentifiers: [focusedGroupIdentifier],
                                  primaryWidthFractionOverride: primaryWidthFraction,
                                  primaryWindowIDOverride: focusedWindowID)
    }

    private func refreshKnownWindows() {
        guard !allowedBundleIdentifiers.isEmpty else {
            knownWindowsByID = [:]
            tiledWindowIDs = []
            orderedWindowIDs = []
            return
        }

        do {
            let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
            refreshAccessibilityObservers(visibleWindows: visibleWindows)
            synchronizeTemporarilyRemovedWindows(with: visibleWindows)

            let windows = activeAutoTileWindows(from: visibleWindows)
            let windowsByID = Self.windowScreenFramesByID(visibleWindows)
            let windowIDs = Set(windows.map(\.id))
            reconcileWindowGroupIdentifiers(for: windows,
                                            newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                            openingContext: lastOpeningContext)
            updateGroupWindowOrders(for: windows)
            knownWindowsByID = windowsByID
            lastOpeningContext = mover.frontmostAutoTileOpeningContext()
            rememberLeadingWindowSlots(from: windows)
            orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                                  windows: windows)
        } catch {
            knownWindowsByID = [:]
            tiledWindowIDs = []
            windowGroupIdentifiersByID = [:]
            orderedWindowIDs = []
            orderedWindowIDsByGroup = [:]
            handler(.failure(error))
        }
    }

    private func retileVisibleWindows(temporarilyNormalizedGroupIdentifiers: Set<Int> = [],
                                      schedulesReinforcements: Bool = true) {
        guard !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty,
              !keepsForcedTileLayoutStable else {
            return
        }

        do {
            let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
            refreshAccessibilityObservers(visibleWindows: visibleWindows)
            synchronizeTemporarilyRemovedWindows(with: visibleWindows)

            let windows = activeAutoTileWindows(from: visibleWindows)
            let windowIDs = Set(windows.map(\.id))
            let previousWindowIDs = Set(knownWindowsByID.keys)
            let didObserveWindowSetChange = windowIDs != previousWindowIDs
            reconcileWindowGroupIdentifiers(for: windows,
                                            newWindowIDs: windowIDs.subtracting(windowGroupIdentifiersByID.keys),
                                            openingContext: lastOpeningContext)
            updateGroupWindowOrders(for: windows)
            lastOpeningContext = mover.frontmostAutoTileOpeningContext()
            let affectedScreenFrames = Dictionary(grouping: windows, by: { AutoTileScreenKey($0.screenVisibleFrame) })
                .values
                .compactMap { $0.first?.screenVisibleFrame }

            guard !affectedScreenFrames.isEmpty else {
                return
            }

            rememberLeadingWindowSlots(from: windows)
            orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                                  windows: windows)
            knownWindowsByID = Self.windowScreenFramesByID(visibleWindows)

            isApplyingTile = true
            let result = try autoTileGroups(windows: windows,
                                            affectedScreenFrames: affectedScreenFrames,
                                            temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers)
            isApplyingTile = false

            if result.tiledWindowCount > 0 {
                handler(.success(result))
            }

            if schedulesReinforcements || didObserveWindowSetChange {
                scheduleRetileReinforcements(temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers)
            }
        } catch {
            isApplyingTile = false
            tiledWindowIDs = []
            handler(.failure(error))
        }
    }

    private func scanForNewWindows() -> Bool {
        guard !isApplyingTile else {
            return false
        }

        guard hiddenScreenRevealProcessIdentifiers.isEmpty else {
            return false
        }

        guard !allowedBundleIdentifiers.isEmpty else {
            knownWindowsByID = [:]
            tiledWindowIDs = []
            windowGroupIdentifiersByID = [:]
            orderedWindowIDs = []
            orderedWindowIDsByGroup = [:]
            lastOpeningContext = nil
            return false
        }

        do {
            let openingContext = lastOpeningContext
            let previousWindowGroupIdentifiersByID = windowGroupIdentifiersByID
            let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers)
            refreshAccessibilityObservers(visibleWindows: visibleWindows)
            synchronizeTemporarilyRemovedWindows(with: visibleWindows)

            let windowsByID = Self.windowScreenFramesByID(visibleWindows)
            let allWindowIDs = Set(windowsByID.keys)
            let knownWindowIDs = Set(knownWindowsByID.keys)
            let newWindowIDs = allWindowIDs.subtracting(knownWindowIDs)
            let closedWindowIDs = knownWindowIDs.subtracting(allWindowIDs)
            manuallyAdjustedWindowIDs.formIntersection(allWindowIDs)
            let observedWindowChange = !newWindowIDs.isEmpty || !closedWindowIDs.isEmpty
            if observedWindowChange {
                keepsForcedTileLayoutStable = false
                forcedTileFramesByWindowID = [:]
            }

            let windows = activeAutoTileWindows(from: visibleWindows)
            let windowIDs = Set(windows.map(\.id))
            reconcileWindowGroupIdentifiers(for: windows,
                                            newWindowIDs: newWindowIDs.intersection(windowIDs),
                                            openingContext: openingContext)
            updateGroupWindowOrders(for: windows)
            lastOpeningContext = mover.frontmostAutoTileOpeningContext()
            let affectedScreenFrames = affectedScreenFrames(for: newWindowIDs,
                                                            closedWindowIDs: closedWindowIDs,
                                                            windows: visibleWindows)
            rememberLeadingWindowSlots(from: windows)
            orderedWindowIDs = updatedWindowOrder(currentWindowIDs: windowIDs,
                                                  windows: windows)
            knownWindowsByID = windowsByID
            activateMainAppsRelatedToNewWindows(newWindowIDs: newWindowIDs,
                                                windows: visibleWindows)
            let shouldScheduleSettledRetile = !newWindowIDs.isEmpty || !closedWindowIDs.isEmpty
            let temporarilyNormalizedGroupIdentifiers = temporarilyNormalizedEnlargedGroupIdentifiers(forNewWindowIDs: newWindowIDs,
                                                                                                       closedWindowIDs: closedWindowIDs,
                                                                                                       previousWindowGroupIdentifiersByID: previousWindowGroupIdentifiersByID,
                                                                                                       windows: windows)

            guard !affectedScreenFrames.isEmpty else {
                if shouldScheduleSettledRetile {
                    scheduleSettledRetile(temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers)
                }
                return observedWindowChange
            }

            isApplyingTile = true
            let result = try autoTileGroups(windows: windows,
                                            affectedScreenFrames: affectedScreenFrames,
                                            temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers)
            isApplyingTile = false

            if result.tiledWindowCount > 0 {
                handler(.success(result))
            }

            if shouldScheduleSettledRetile {
                scheduleSettledRetile(temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers)
            }

            return observedWindowChange
        } catch {
            isApplyingTile = false
            tiledWindowIDs = []
            handler(.failure(error))
            return false
        }
    }

    private func installWorkspaceObservers() {
        guard workspaceObserverTokens.isEmpty else {
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens = [
            notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                           object: nil,
                                           queue: .main) { [weak self] notification in
                guard let autoTiler = self else {
                    return
                }

                let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    autoTiler.handleApplicationActivation(bundleIdentifier: bundleIdentifier)
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                           object: nil,
                                           queue: .main) { [weak self] notification in
                guard let autoTiler = self else {
                    return
                }

                let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    autoTiler.handleApplicationLaunch(bundleIdentifier: bundleIdentifier)
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                           object: nil,
                                           queue: .main) { [weak self] _ in
                guard let autoTiler = self else {
                    return
                }

                Task { @MainActor in
                    autoTiler.handleWorkspaceChange()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didUnhideApplicationNotification,
                                           object: nil,
                                           queue: .main) { [weak self] notification in
                guard let autoTiler = self else {
                    return
                }

                let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    autoTiler.handleApplicationUnhide(bundleIdentifier: bundleIdentifier)
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didHideApplicationNotification,
                                           object: nil,
                                           queue: .main) { [weak self] notification in
                guard let autoTiler = self else {
                    return
                }

                let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    autoTiler.handleApplicationHide(bundleIdentifier: bundleIdentifier)
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil,
                                           queue: .main) { [weak self] _ in
                guard let autoTiler = self else {
                    return
                }

                Task { @MainActor in
                    autoTiler.handleWorkspaceChange()
                }
            }
        ]
    }

    private func removeWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        for token in workspaceObserverTokens {
            notificationCenter.removeObserver(token)
        }

        workspaceObserverTokens = []
    }

    private func handleWorkspaceChange() {
        guard isRunning else {
            return
        }

        refreshAccessibilityObservers()
        scheduleEventScan()
    }

    private func handleApplicationLaunch(bundleIdentifier: String?) {
        guard isRunning else {
            return
        }

        if let bundleIdentifier {
            if activateMainAppsRelated(to: [bundleIdentifier]) {
                scheduleMainAppRetiles()
            }
        }

        handleWorkspaceChange()
    }

    private func handleApplicationActivation(bundleIdentifier: String?) {
        guard isRunning,
              let bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        guard allowedBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        let didActivateMainApps = activateMainAppsRelated(to: [bundleIdentifier],
                                                          excluding: [bundleIdentifier])
        scheduleFocusedWindowRetile()

        if didActivateMainApps {
            scheduleMainAppRetiles()
        }
    }

    private func handleApplicationUnhide(bundleIdentifier: String?) {
        guard isRunning,
              let bundleIdentifier,
              allowedBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        if propagatedUnhiddenBundleIdentifiers.remove(bundleIdentifier) != nil {
            scheduleEventScan()
            return
        }

        let didRevealMainApps = isMainAppBundleIdentifier(bundleIdentifier) &&
            activateMainAppsRelated(to: [bundleIdentifier],
                                    excluding: [bundleIdentifier])
        let didRevealGroupedApps = unhideGroupedAppsRelated(to: [bundleIdentifier],
                                                            excluding: [bundleIdentifier])
        retileVisibleWindows()

        if didRevealMainApps || didRevealGroupedApps {
            scheduleMainAppRetiles()
        }
    }

    private func handleApplicationHide(bundleIdentifier: String?) {
        guard isRunning,
              let bundleIdentifier,
              allowedBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        if propagatedHiddenBundleIdentifiers.remove(bundleIdentifier) != nil {
            scheduleEventScan()
            return
        }

        if focusGroupSwitchHiddenBundleIdentifiers.remove(bundleIdentifier) != nil {
            return
        }

        let relatedBundleIdentifiers = groupedBundleIdentifiersRelated(to: [bundleIdentifier],
                                                                       excluding: [bundleIdentifier])
        propagatedHiddenBundleIdentifiers.formUnion(relatedBundleIdentifiers)
        let hiddenBundleIdentifiers = mover.hideApplications(bundleIdentifiers: relatedBundleIdentifiers)
        propagatedHiddenBundleIdentifiers.subtract(relatedBundleIdentifiers.subtracting(hiddenBundleIdentifiers))
        scheduleEventScan()
    }

    @discardableResult
    private func unhideGroupedAppsRelated(to bundleIdentifiers: Set<String>,
                                          excluding excludedBundleIdentifiers: Set<String> = []) -> Bool {
        let relatedBundleIdentifiers = groupedBundleIdentifiersRelated(to: bundleIdentifiers,
                                                                       excluding: excludedBundleIdentifiers)
        let bundleIdentifiersToUnhide = relatedBundleIdentifiers.subtracting(propagatedUnhiddenBundleIdentifiers)
        propagatedUnhiddenBundleIdentifiers.formUnion(bundleIdentifiersToUnhide)
        let unhiddenBundleIdentifiers = mover.unhideApplications(bundleIdentifiers: bundleIdentifiersToUnhide)
        propagatedUnhiddenBundleIdentifiers.subtract(bundleIdentifiersToUnhide.subtracting(unhiddenBundleIdentifiers))
        return !unhiddenBundleIdentifiers.isEmpty
    }

    fileprivate func handleAccessibilityNotification(_ notification: String, element: AXUIElement? = nil) {
        guard isRunning else {
            return
        }

        switch notification {
        case kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification:
            scheduleEventScan()
        case kAXFocusedWindowChangedNotification:
            if keepsForcedTileLayoutStable {
                scheduleForcedTileRestores()
            } else {
                scheduleFocusedWindowRetile()
            }
        case kAXWindowMovedNotification,
            kAXWindowResizedNotification:
            if let element {
                handleManualWindowAdjustment(of: element)
            }
        default:
            break
        }
    }

    private func handleManualWindowAdjustment(of element: AXUIElement) {
        guard isRunning,
              !isApplyingTile,
              let windowID = windowID(for: element),
              let currentFrame = mover.currentFrame(of: element) else {
            return
        }

        // Ignore the tiler's own echoes: a window resting at the frame we last
        // applied to it has not been touched by the user.
        if let appliedFrame = appliedFrameByWindowID[windowID],
           frameApproximatelyEqual(currentFrame, appliedFrame) {
            return
        }

        if manuallyAdjustedWindowIDs.insert(windowID).inserted {
            cancelPendingRetiles()
        }

        windowIDsPendingManualEvaluation.insert(windowID)
        scheduleManualAdjustmentEvaluation()
    }

    private func scheduleManualAdjustmentEvaluation() {
        pendingManualAdjustmentWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingManualAdjustmentWorkItem = nil
                self?.evaluatePendingManualAdjustments()
            }
        }

        pendingManualAdjustmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func evaluatePendingManualAdjustments() {
        let pendingWindowIDs = windowIDsPendingManualEvaluation
        windowIDsPendingManualEvaluation = []

        guard isRunning,
              !isApplyingTile,
              !allowedBundleIdentifiers.isEmpty,
              !pendingWindowIDs.isEmpty,
              let snapshot = try? mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers) else {
            return
        }

        for windowID in pendingWindowIDs {
            guard let window = snapshot.first(where: { $0.id == windowID }) else {
                manuallyAdjustedWindowIDs.remove(windowID)
                appliedFrameByWindowID.removeValue(forKey: windowID)
                continue
            }

            let referenceFrame = appliedFrameByWindowID[windowID]

            // Settled back onto the reference frame (e.g. an animated echo): not a manual change.
            if let referenceFrame,
               frameApproximatelyEqual(window.frame, referenceFrame) {
                manuallyAdjustedWindowIDs.remove(windowID)
                continue
            }

            // Only re-tile when the window was moved or resized enough to reshape the tile set.
            // Small nudges keep the user's frame and stay out of tiling.
            let shouldReengageWindow: Bool
            if let referenceFrame {
                shouldReengageWindow = windowWasReshapedSignificantly(from: referenceFrame,
                                                                      to: window.frame,
                                                                      in: window.screenVisibleFrame)
            } else {
                shouldReengageWindow = windowHasVisibleTilePeer(window, in: snapshot)
            }

            if shouldReengageWindow {
                reengageSnappedWindow(window)
            } else {
                // Honor the manual frame and use it as the new reference position.
                appliedFrameByWindowID[windowID] = window.frame
            }
        }
    }

    private func reengageSnappedWindow(_ window: AutoTileWindow) {
        manuallyAdjustedWindowIDs.remove(window.id)

        let target = WindowTarget(applicationName: window.applicationName,
                                  bundleIdentifier: window.bundleIdentifier,
                                  processIdentifier: window.processIdentifier,
                                  window: window.window)

        do {
            let result = try retileAroundMovedWindow(target, movedFrame: window.frame)
            if result.tiledWindowCount > 0 {
                handler(.success(result))
            }
        } catch {
            // Leave the window under management even if retiling around it failed.
        }
    }

    private func windowWasReshapedSignificantly(from oldFrame: CGRect,
                                                to newFrame: CGRect,
                                                in visibleFrame: CGRect) -> Bool {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return false
        }

        let originDistance = hypot(newFrame.minX - oldFrame.minX,
                                   newFrame.minY - oldFrame.minY)
        let widthDifference = abs(newFrame.width - oldFrame.width)
        let heightDifference = abs(newFrame.height - oldFrame.height)
        let movementThreshold = min(visibleFrame.width, visibleFrame.height) * 0.18
        let resizeThreshold: CGFloat = 6
        return originDistance > movementThreshold || widthDifference > resizeThreshold || heightDifference > resizeThreshold
    }

    private func windowHasVisibleTilePeer(_ window: AutoTileWindow,
                                          in windows: [AutoTileWindow]) -> Bool {
        let windowGroupIdentifiers = groupIdentifiers(for: window)
        guard !windowGroupIdentifiers.isEmpty else {
            return false
        }

        let windowScreenKey = AutoTileScreenKey(window.screenVisibleFrame)
        return windows.contains { otherWindow in
            otherWindow.id != window.id &&
                AutoTileScreenKey(otherWindow.screenVisibleFrame) == windowScreenKey &&
                !groupIdentifiers(for: otherWindow).intersection(windowGroupIdentifiers).isEmpty
        }
    }

    private func captureAppliedFrames() {
        guard isRunning,
              !allowedBundleIdentifiers.isEmpty,
              let snapshot = try? mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers) else {
            return
        }

        var frames: [AutoTileWindowID: CGRect] = [:]
        for window in snapshot {
            frames[window.id] = window.frame
        }
        appliedFrameByWindowID = frames
    }

    private func frameApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    private func windowID(for element: AXUIElement) -> AutoTileWindowID? {
        for observedApplication in observedApplicationsByProcessIdentifier.values {
            if let match = observedApplication.windowElementsByID.first(where: { CFEqual($0.value, element) }) {
                return match.key
            }
        }

        return nil
    }

    private func scheduleFocusedWindowRetile(delay: TimeInterval? = nil) {
        pendingFocusedWindowRetileWorkItem?.cancel()

        guard isRunning,
              !keepsForcedTileLayoutStable else {
            pendingFocusedWindowRetileWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.pendingFocusedWindowRetileWorkItem = nil
                self.retileFocusedWindowPrimary()
            }
        }

        pendingFocusedWindowRetileWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? eventScanDelay), execute: workItem)
    }

    private func cancelPendingRetiles() {
        pendingScanWorkItem?.cancel()
        pendingScanWorkItem = nil
        pendingFocusedWindowRetileWorkItem?.cancel()
        pendingFocusedWindowRetileWorkItem = nil
        pendingSettledRetileWorkItems.forEach { $0.cancel() }
        pendingSettledRetileWorkItems = []
        pendingRetileReinforcementWorkItems.forEach { $0.cancel() }
        pendingRetileReinforcementWorkItems = []
        pendingMainAppRetileWorkItems.forEach { $0.cancel() }
        pendingMainAppRetileWorkItems = []
        pendingFocusGroupRetileWorkItems.forEach { $0.cancel() }
        pendingFocusGroupRetileWorkItems = []
        pendingForcedTileRestoreWorkItems.forEach { $0.cancel() }
        pendingForcedTileRestoreWorkItems = []
    }

    private func scheduleForcedTileRestores() {
        pendingForcedTileRestoreWorkItems.forEach { $0.cancel() }
        pendingForcedTileRestoreWorkItems = []

        guard keepsForcedTileLayoutStable,
              !forcedTileFramesByWindowID.isEmpty else {
            return
        }

        for delay in [0.04, 0.16, 0.36] {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.restoreForcedTileLayoutIfNeeded()
                }
            }

            pendingForcedTileRestoreWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func restoreForcedTileLayoutIfNeeded() {
        guard keepsForcedTileLayoutStable,
              !forcedTileFramesByWindowID.isEmpty,
              !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty,
              isRunning else {
            return
        }

        do {
            let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers,
                                                                  includesOffscreenWindows: true)
            let currentWindowIDs = Set(visibleWindows.map(\.id))
            guard Set(forcedTileFramesByWindowID.keys).isSubset(of: currentWindowIDs) else {
                keepsForcedTileLayoutStable = false
                forcedTileFramesByWindowID = [:]
                return
            }

            isApplyingTile = true
            let result = mover.restoreAutoTileFrames(forcedTileFramesByWindowID,
                                                     windows: visibleWindows)
            appliedFrameByWindowID.merge(result.appliedFramesByWindowID) { _, new in new }
            isApplyingTile = false

            if result.tiledWindowCount > 0 {
                handler(.success(result))
            }
        } catch {
            isApplyingTile = false
            handler(.failure(error))
        }
    }

    private func retileFocusedWindowPrimary() {
        guard isRunning,
              !isApplyingTile,
              hiddenScreenRevealProcessIdentifiers.isEmpty,
              !allowedBundleIdentifiers.isEmpty else {
            return
        }

        do {
            let previousWindowIDs = Set(knownWindowsByID.keys)
            let target = try mover.frontmostWindowTarget()
            guard let bundleIdentifier = target.bundleIdentifier,
                  allowedBundleIdentifiers.contains(bundleIdentifier) else {
                return
            }

            let result = try applyFocusedWindowPrimary(target,
                                                       primaryWidthFraction: focusedWindowPrimaryWidthFraction,
                                                       shouldEnlarge: widensFocusedWindow && !focusTileWiderFixedBundleIdentifiers.contains(bundleIdentifier))
            if result.tiledWindowCount > 0 {
                handler(.success(result))
            }
            if Set(knownWindowsByID.keys) != previousWindowIDs {
                scheduleRetileReinforcements()
            }
        } catch {
            handler(.failure(error))
        }
    }

    private func scheduleEventScan() {
        pendingScanWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.pendingScanWorkItem = nil
                let didObserveWindowChange = self.scanForNewWindows()
                if didObserveWindowChange, !self.keepsForcedTileLayoutStable {
                    self.scheduleFocusedWindowRetile()
                }
            }
        }

        pendingScanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + eventScanDelay, execute: workItem)
    }

    private func refreshAccessibilityObservers(visibleWindows: [AutoTileWindow] = []) {
        guard isRunning,
              AXIsProcessTrusted() else {
            removeAccessibilityObservers()
            return
        }

        let observedProcessIdentifiers = observeAllowedRunningApplications()
        syncObservedWindowNotifications(for: visibleWindows,
                                        observedProcessIdentifiers: observedProcessIdentifiers)
    }

    @discardableResult
    private func observeAllowedRunningApplications() -> Set<pid_t> {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return application.activationPolicy == .regular &&
                !application.isHidden &&
                bundleIdentifier != ownBundleIdentifier &&
                allowedBundleIdentifiers.contains(bundleIdentifier)
        }
        let runningProcessIdentifiers = Set(runningApplications.map(\.processIdentifier))

        for processIdentifier in Array(observedApplicationsByProcessIdentifier.keys) where !runningProcessIdentifiers.contains(processIdentifier) {
            removeAccessibilityObserver(processIdentifier: processIdentifier)
        }

        for application in runningApplications where observedApplicationsByProcessIdentifier[application.processIdentifier] == nil {
            observeApplication(application)
        }

        return runningProcessIdentifiers
    }

    private func observeApplication(_ application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        var observer: AXObserver?
        let observerError = AXObserverCreate(processIdentifier,
                                             autoTilerAccessibilityObserverCallback,
                                             &observer)

        guard observerError == .success,
              let observer else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let runLoopSource = AXObserverGetRunLoopSource(observer)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let addError = AXObserverAddNotification(observer,
                                                 applicationElement,
                                                 kAXWindowCreatedNotification as CFString,
                                                 userInfo)

        guard addError == .success else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            return
        }

        AXObserverAddNotification(observer,
                                  applicationElement,
                                  kAXFocusedWindowChangedNotification as CFString,
                                  userInfo)

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        observedApplicationsByProcessIdentifier[processIdentifier] = ObservedApplication(observer: observer,
                                                                                         applicationElement: applicationElement,
                                                                                         runLoopSource: runLoopSource)
    }

    private func syncObservedWindowNotifications(for windows: [AutoTileWindow],
                                                 observedProcessIdentifiers: Set<pid_t>) {
        let windowsByProcessIdentifier = Dictionary(grouping: windows) { $0.processIdentifier }

        for processIdentifier in observedProcessIdentifiers {
            guard let observedApplication = observedApplicationsByProcessIdentifier[processIdentifier] else {
                continue
            }

            let processWindows = windowsByProcessIdentifier[processIdentifier] ?? []
            let currentWindowIDs = Set(processWindows.map(\.id))

            for (windowID, window) in Array(observedApplication.windowElementsByID) where !currentWindowIDs.contains(windowID) {
                AXObserverRemoveNotification(observedApplication.observer,
                                             window,
                                             kAXUIElementDestroyedNotification as CFString)
                AXObserverRemoveNotification(observedApplication.observer,
                                             window,
                                             kAXWindowMovedNotification as CFString)
                AXObserverRemoveNotification(observedApplication.observer,
                                             window,
                                             kAXWindowResizedNotification as CFString)
                observedApplication.windowElementsByID.removeValue(forKey: windowID)
            }

            for window in processWindows where observedApplication.windowElementsByID[window.id] == nil {
                let addError = AXObserverAddNotification(observedApplication.observer,
                                                         window.window,
                                                         kAXUIElementDestroyedNotification as CFString,
                                                         Unmanaged.passUnretained(self).toOpaque())

                if addError == .success {
                    observedApplication.windowElementsByID[window.id] = window.window
                    AXObserverAddNotification(observedApplication.observer,
                                              window.window,
                                              kAXWindowMovedNotification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                    AXObserverAddNotification(observedApplication.observer,
                                              window.window,
                                              kAXWindowResizedNotification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
    }

    private func removeAccessibilityObservers() {
        for processIdentifier in Array(observedApplicationsByProcessIdentifier.keys) {
            removeAccessibilityObserver(processIdentifier: processIdentifier)
        }
    }

    private func removeAccessibilityObserver(processIdentifier: pid_t) {
        guard let observedApplication = observedApplicationsByProcessIdentifier.removeValue(forKey: processIdentifier) else {
            return
        }

        AXObserverRemoveNotification(observedApplication.observer,
                                     observedApplication.applicationElement,
                                     kAXWindowCreatedNotification as CFString)
        AXObserverRemoveNotification(observedApplication.observer,
                                     observedApplication.applicationElement,
                                     kAXFocusedWindowChangedNotification as CFString)

        for window in observedApplication.windowElementsByID.values {
            AXObserverRemoveNotification(observedApplication.observer,
                                         window,
                                         kAXUIElementDestroyedNotification as CFString)
            AXObserverRemoveNotification(observedApplication.observer,
                                         window,
                                         kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(observedApplication.observer,
                                         window,
                                         kAXWindowResizedNotification as CFString)
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              observedApplication.runLoopSource,
                              .commonModes)
    }

    private func scheduleSettledRetile(temporarilyNormalizedGroupIdentifiers: Set<Int> = []) {
        pendingSettledRetileWorkItems.forEach { $0.cancel() }
        pendingSettledRetileWorkItems = []

        for delay in [0.06, 0.18, 0.42, 0.85, 1.20] {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.retileVisibleWindows(temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers,
                                               schedulesReinforcements: false)
                }
            }

            pendingSettledRetileWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func scheduleRetileReinforcements(temporarilyNormalizedGroupIdentifiers: Set<Int> = []) {
        pendingRetileReinforcementWorkItems.forEach { $0.cancel() }
        pendingRetileReinforcementWorkItems = []

        guard !keepsForcedTileLayoutStable else {
            return
        }

        for delay in [0.08, 0.18, 0.35, 0.65, 1.00] {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.retileVisibleWindows(temporarilyNormalizedGroupIdentifiers: temporarilyNormalizedGroupIdentifiers,
                                               schedulesReinforcements: false)
                }
            }

            pendingRetileReinforcementWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func scheduleMainAppRetiles() {
        guard !keepsForcedTileLayoutStable else {
            pendingMainAppRetileWorkItems.forEach { $0.cancel() }
            pendingMainAppRetileWorkItems = []
            return
        }

        pendingMainAppRetileWorkItems.forEach { $0.cancel() }
        pendingMainAppRetileWorkItems = []

        for delay in [0.12, 0.35, 0.75, 1.4, 2.4] {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    guard !self.keepsForcedTileLayoutStable else {
                        return
                    }

                    self.retileVisibleWindows(schedulesReinforcements: false)
                }
            }

            pendingMainAppRetileWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func autoTileGroups(windows: [AutoTileWindow],
                                affectedScreenFrames: [CGRect],
                                targetGroupIdentifiers: [Int]? = nil,
                                temporarilyNormalizedGroupIdentifiers: Set<Int> = [],
                                primaryWidthFractionOverride: CGFloat? = nil,
                                primaryWindowIDOverride: AutoTileWindowID? = nil,
                                preservesPrimaryWindowPosition: Bool = false) throws -> AutoTileResult {
        let affectedScreens = Set(affectedScreenFrames.map(AutoTileScreenKey.init))

        var tiledWindowCount = 0
        var screenKeys: Set<AutoTileScreenKey> = []
        var skippedWindowCount = 0
        var appliedFramesByWindowID: [AutoTileWindowID: CGRect] = [:]

        for groupIdentifier in targetGroupIdentifiers ?? configuredGroupIdentifiers {
            let groupWindows = windows.filter { groupIdentifiers(for: $0).contains(groupIdentifier) }
            guard !groupWindows.isEmpty else {
                continue
            }

            let fillsSingleVisibleWindow = false
            if groupWindows.count > 1 {
                groupsWithMultipleVisibleWindows.insert(groupIdentifier)
            }

            var rememberedPrimaryWindowID = enlargedWindowIDsByGroup[groupIdentifier]
            var rememberedPrimaryWindowExists = rememberedPrimaryWindowID.map { primaryWindowID in
                groupWindows.contains { $0.id == primaryWindowID }
            } ?? false

            if rememberedPrimaryWindowID != nil,
               !rememberedPrimaryWindowExists {
                enlargedWindowIDsByGroup.removeValue(forKey: groupIdentifier)
                rememberedPrimaryWindowID = nil
            }

            if !rememberedPrimaryWindowExists,
               let rememberedPrimaryWindowFingerprint = enlargedWindowFingerprintsByGroup[groupIdentifier],
               let restoredPrimaryWindow = groupWindows.first(where: { AutoTileWindowFingerprint($0).map { $0 == rememberedPrimaryWindowFingerprint } ?? false }) {
                rememberedPrimaryWindowID = restoredPrimaryWindow.id
                rememberedPrimaryWindowExists = true
                enlargedWindowIDsByGroup[groupIdentifier] = restoredPrimaryWindow.id
            }

            if rememberedPrimaryWindowID == nil,
               enlargedWindowFingerprintsByGroup[groupIdentifier] == nil {
                enlargedWindowSlotsByGroup.removeValue(forKey: groupIdentifier)
            }

            let usesTemporarilyNormalizedLayout = temporarilyNormalizedGroupIdentifiers.contains(groupIdentifier)
            let groupScreenLayoutMode = screenLayoutModeByGroup[groupIdentifier] ?? .gridScreen
            let groupMaximumColumnCount = maximumColumnCountByGroup[groupIdentifier] ?? 3
            let groupTileDirection = tileDirectionByGroup[groupIdentifier] ?? .leftToRight
            if layoutMode == .sharedGrid,
               groupWindows.count == 3 {
                clearFocusedPrimaryState(for: groupIdentifier)
                rememberedPrimaryWindowID = nil
                rememberedPrimaryWindowExists = false
            }
            let groupPrimaryWindowIDOverride = usesTemporarilyNormalizedLayout ? primaryWindowIDOverride : (primaryWindowIDOverride ?? (rememberedPrimaryWindowExists ? rememberedPrimaryWindowID : nil))
            let groupPrimaryWidthFractionOverride = groupPrimaryWindowIDOverride == nil ? nil : (primaryWidthFractionOverride ?? groupScreenLayoutMode.primaryWidthFraction)
            let groupPrimaryWindowSlotOverride = primaryWindowIDOverride == nil ? enlargedWindowSlotsByGroup[groupIdentifier] : nil

            let groupAffectedScreenFrames = Dictionary(grouping: groupWindows,
                                                       by: { AutoTileScreenKey($0.screenVisibleFrame) })
                .values
                .compactMap { screenWindows -> CGRect? in
                    guard let screenVisibleFrame = screenWindows.first?.screenVisibleFrame,
                          affectedScreens.contains(AutoTileScreenKey(screenVisibleFrame)) else {
                        return nil
                    }

                    return screenVisibleFrame
                }

            guard !groupAffectedScreenFrames.isEmpty else {
                continue
            }

            let result = try mover.autoTile(windows: groupWindows,
                                            orderedWindowIDs: orderedWindowIDsByGroup[groupIdentifier] ?? orderedWindowIDs,
                                            affectedScreenFrames: groupAffectedScreenFrames,
                                            layoutMode: layoutMode,
                                            reservedSlotBundleIdentifiers: mainBundleIdentifiers(in: groupIdentifier),
                                            fillsFirstWindow: fillsFirstWindowByGroup[groupIdentifier] ?? false,
                                            fillsSingleVisibleWindow: fillsSingleVisibleWindow,
                                            screenLayoutMode: groupScreenLayoutMode,
                                            maximumColumnCount: groupMaximumColumnCount,
                                            tileDirection: groupTileDirection,
                                            ignoresSecondAppInList: ignoresSecondAppInListByGroup[groupIdentifier] ?? false,
                                            ignoredSecondWindowStartMode: ignoredSecondWindowStartModeByGroup[groupIdentifier] ?? .normalStart,
                                            primaryWidthFractionOverride: groupPrimaryWidthFractionOverride,
                                            primaryWindowIDOverride: groupPrimaryWindowIDOverride,
                                            primaryWindowSlotOverride: groupPrimaryWindowSlotOverride,
                                            preservesPrimaryWindowPosition: preservesPrimaryWindowPosition)

            tiledWindowCount += result.tiledWindowCount
            skippedWindowCount += result.skippedWindowCount
            screenKeys.formUnion(groupAffectedScreenFrames.map(AutoTileScreenKey.init))
            appliedFramesByWindowID.merge(result.appliedFramesByWindowID) { _, new in new }

            if result.tiledWindowCount > 0 {
                let affectedGroupScreenKeys = Set(groupAffectedScreenFrames.map(AutoTileScreenKey.init))
                tiledWindowIDs.formUnion(groupWindows
                    .filter { affectedGroupScreenKeys.contains(AutoTileScreenKey($0.screenVisibleFrame)) }
                    .map(\.id))
            }
        }

        self.appliedFrameByWindowID.merge(appliedFramesByWindowID) { _, new in new }

        return AutoTileResult(tiledWindowCount: tiledWindowCount,
                              screenCount: screenKeys.count,
                              skippedWindowCount: skippedWindowCount,
                              appliedFramesByWindowID: appliedFramesByWindowID)
    }

    private func clearFocusedPrimaryState() {
        enlargedWindowIDsByGroup = [:]
        enlargedWindowFingerprintsByGroup = [:]
        enlargedWindowSlotsByGroup = [:]
    }

    private func clearFocusedPrimaryState(for groupIdentifier: Int) {
        enlargedWindowIDsByGroup.removeValue(forKey: groupIdentifier)
        enlargedWindowFingerprintsByGroup.removeValue(forKey: groupIdentifier)
        enlargedWindowSlotsByGroup.removeValue(forKey: groupIdentifier)
    }

    private func captureForcedTileLayoutSnapshot() {
        guard keepsForcedTileLayoutStable else {
            forcedTileFramesByWindowID = [:]
            return
        }

        do {
            let visibleWindows = try mover.visibleAutoTileWindows(allowedBundleIdentifiers: allowedBundleIdentifiers,
                                                                  includesOffscreenWindows: true)
            let windows = activeAutoTileWindows(from: visibleWindows)
            forcedTileFramesByWindowID = Dictionary(uniqueKeysWithValues: windows.map { window in
                (window.id, window.frame)
            })
        } catch {
            forcedTileFramesByWindowID = [:]
        }
    }

    private func temporarilyNormalizedEnlargedGroupIdentifiers(forNewWindowIDs newWindowIDs: Set<AutoTileWindowID>,
                                                               closedWindowIDs: Set<AutoTileWindowID>,
                                                               previousWindowGroupIdentifiersByID: [AutoTileWindowID: Set<Int>],
                                                               windows: [AutoTileWindow]) -> Set<Int> {
        guard !newWindowIDs.isEmpty || !closedWindowIDs.isEmpty,
              (!enlargedWindowIDsByGroup.isEmpty || !enlargedWindowFingerprintsByGroup.isEmpty) else {
            return []
        }

        var normalizedGroupIdentifiers: Set<Int> = []

        for groupIdentifier in configuredGroupIdentifiers {
            guard enlargedWindowIDsByGroup[groupIdentifier] != nil ||
                    enlargedWindowFingerprintsByGroup[groupIdentifier] != nil else {
                continue
            }

            let groupWindows = windows.filter { self.groupIdentifiers(for: $0).contains(groupIdentifier) }
            let newGroupWindows = groupWindows.filter { newWindowIDs.contains($0.id) }
            let newWindowRestoresEnlargedWindow = newGroupWindows.contains { window in
                window.id == enlargedWindowIDsByGroup[groupIdentifier] ||
                    AutoTileWindowFingerprint(window).map { $0 == enlargedWindowFingerprintsByGroup[groupIdentifier] } == true
            }
            let addsNonEnlargedWindowToLargerGroup = groupWindows.count > 2 &&
                !newGroupWindows.isEmpty &&
                !newWindowRestoresEnlargedWindow
            let closesWindowInGroup = closedWindowIDs.contains { windowID in
                previousWindowGroupIdentifiersByID[windowID]?.contains(groupIdentifier) ?? false
            }
            let closesWindowInMiddleStartGroup = closesWindowInGroup &&
                groupWindows.count > 2 &&
                (ignoredSecondWindowStartModeByGroup[groupIdentifier] ?? .normalStart) == .middleStart

            guard addsNonEnlargedWindowToLargerGroup || closesWindowInMiddleStartGroup else {
                continue
            }

            normalizedGroupIdentifiers.insert(groupIdentifier)
        }

        return normalizedGroupIdentifiers
    }

    private func activeAutoTileWindows(from windows: [AutoTileWindow]) -> [AutoTileWindow] {
        guard !temporarilyRemovedWindowsByID.isEmpty || !manuallyAdjustedWindowIDs.isEmpty else {
            return windows
        }

        return windows.filter {
            temporarilyRemovedWindowsByID[$0.id] == nil && !manuallyAdjustedWindowIDs.contains($0.id)
        }
    }

    private func synchronizeTemporarilyRemovedWindows(with windows: [AutoTileWindow]) {
        guard !temporarilyRemovedWindowsByID.isEmpty else {
            return
        }

        for (id, removal) in Array(temporarilyRemovedWindowsByID) {
            guard let matchedWindow = temporarilyRemovedWindow(matching: removal, in: windows) else {
                temporarilyRemovedWindowsByID.removeValue(forKey: id)
                if mostRecentlyTemporarilyRemovedWindowID == id {
                    mostRecentlyTemporarilyRemovedWindowID = temporarilyRemovedWindowsByID.keys.first
                }
                continue
            }

            guard matchedWindow.id != id else {
                continue
            }

            temporarilyRemovedWindowsByID.removeValue(forKey: id)
            temporarilyRemovedWindowsByID[matchedWindow.id] = TemporarilyRemovedAutoTileWindow(id: matchedWindow.id,
                                                                                              fingerprint: AutoTileWindowFingerprint(matchedWindow) ?? removal.fingerprint,
                                                                                              applicationName: removal.applicationName,
                                                                                              groupIdentifiers: removal.groupIdentifiers)
            if mostRecentlyTemporarilyRemovedWindowID == id {
                mostRecentlyTemporarilyRemovedWindowID = matchedWindow.id
            }
        }
    }

    private func temporarilyRemovedWindow(matching removal: TemporarilyRemovedAutoTileWindow,
                                          in windows: [AutoTileWindow]) -> AutoTileWindow? {
        if let window = windows.first(where: { $0.id == removal.id }) {
            return window
        }

        guard let fingerprint = removal.fingerprint else {
            return nil
        }

        let matches = windows.filter { window in
            AutoTileWindowFingerprint(window).map { $0 == fingerprint } ?? false
        }

        return matches.count == 1 ? matches[0] : nil
    }

    private func affectedScreenFrames(for newWindowIDs: Set<AutoTileWindowID>,
                                      closedWindowIDs: Set<AutoTileWindowID>,
                                      windows: [AutoTileWindow]) -> [CGRect] {
        let newWindowScreenFrames = windows
            .filter { newWindowIDs.contains($0.id) }
            .map(\.screenVisibleFrame)

        let closedWindowScreenFrames = closedWindowIDs.compactMap { knownWindowsByID[$0] }

        return newWindowScreenFrames + closedWindowScreenFrames
    }

    private func focusedWindow(matching target: WindowTarget,
                               fallbackID: AutoTileWindowID,
                               in windows: [AutoTileWindow]) -> AutoTileWindow? {
        if let window = windows.first(where: { $0.id == fallbackID }) {
            return window
        }

        if let window = windows.first(where: { CFEqual($0.window, target.window) }) {
            return window
        }

        let targetTitle = stringAttribute(kAXTitleAttribute as CFString, for: target.window)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleMatches = windows.filter { window in
            guard window.processIdentifier == target.processIdentifier,
                  window.bundleIdentifier == target.bundleIdentifier,
                  let targetTitle,
                  !targetTitle.isEmpty else {
                return false
            }

            return window.title?.trimmingCharacters(in: .whitespacesAndNewlines) == targetTitle
        }

        if titleMatches.count == 1 {
            return titleMatches[0]
        }

        let processMatches = windows.filter {
            $0.processIdentifier == target.processIdentifier &&
                $0.bundleIdentifier == target.bundleIdentifier
        }

        return processMatches.count == 1 ? processMatches[0] : nil
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private static func windowScreenFramesByID(_ windows: [AutoTileWindow]) -> [AutoTileWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.screenVisibleFrame) })
    }

    private static func normalizedWindowTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        return title
    }

    private func orderedGroupWindows(groupWindows: [AutoTileWindow],
                                     groupIdentifier: Int) -> [AutoTileWindow] {
        let windowsByID = Dictionary(uniqueKeysWithValues: groupWindows.map { ($0.id, $0) })
        let orderedWindows = (orderedWindowIDsByGroup[groupIdentifier] ?? orderedWindowIDs).compactMap { windowsByID[$0] }
        let orderedWindowIDSet = Set(orderedWindows.map(\.id))
        let unorderedWindows = groupWindows
            .filter { !orderedWindowIDSet.contains($0.id) }
            .sorted(by: Self.windowSpatialSort)

        return orderedWindows + unorderedWindows
    }

    private var configuredGroupIdentifiers: [Int] {
        Array(Set(appGroupIdentifiersByBundleIdentifier.values.flatMap { $0 })).sorted()
    }

    private func groupIdentifiers(for window: AutoTileWindow) -> Set<Int> {
        windowGroupIdentifiersByID[window.id] ?? defaultGroupIdentifiers(for: window.bundleIdentifier)
    }

    private func defaultGroupIdentifiers(for bundleIdentifier: String) -> Set<Int> {
        return appGroupIdentifiersByBundleIdentifier[bundleIdentifier] ?? []
    }

    private func mainBundleIdentifiers(in groupIdentifier: Int) -> [String] {
        return mainAppBundleIdentifiersByGroup[groupIdentifier] ?? []
    }

    private func bundleIdentifierOrder(in groupIdentifier: Int) -> [String] {
        return appBundleIdentifiersByGroup[groupIdentifier] ?? []
    }

    private func reconcileWindowGroupIdentifiers(for windows: [AutoTileWindow],
                                                 newWindowIDs: Set<AutoTileWindowID>,
                                                 openingContext: AutoTileOpeningContext?) {
        let currentWindowIDs = Set(windows.map(\.id))
        windowGroupIdentifiersByID = windowGroupIdentifiersByID.filter { currentWindowIDs.contains($0.key) }

        for window in windows {
            let candidates = defaultGroupIdentifiers(for: window.bundleIdentifier)
            guard !candidates.isEmpty else {
                windowGroupIdentifiersByID.removeValue(forKey: window.id)
                continue
            }

            let contextualGroups = contextualGroupIdentifiers(for: window,
                                                              candidates: candidates,
                                                              openingContext: openingContext,
                                                              windows: windows)

            if let assignedGroups = windowGroupIdentifiersByID[window.id],
               !newWindowIDs.contains(window.id) {
                let retainedGroups = assignedGroups.intersection(candidates)
                if !retainedGroups.isEmpty {
                    if candidates.count > 1,
                       let contextualGroups,
                       contextualGroups != retainedGroups {
                        windowGroupIdentifiersByID[window.id] = contextualGroups
                        continue
                    }

                    windowGroupIdentifiersByID[window.id] = retainedGroups
                    continue
                }
            }

            windowGroupIdentifiersByID[window.id] = contextualGroups ??
                fallbackGroupIdentifiers(candidates: candidates)
        }
    }

    private func contextualGroupIdentifiers(for window: AutoTileWindow,
                                            candidates: Set<Int>,
                                            openingContext: AutoTileOpeningContext?,
                                            windows: [AutoTileWindow]) -> Set<Int>? {
        guard candidates.count > 1 else {
            return candidates
        }

        if let openingContext,
           let openerWindowID = openingContext.windowID,
           openerWindowID != window.id,
           let openerGroupIdentifier = firstConfiguredGroupIdentifier(in: candidates.intersection(windowGroupIdentifiersByID[openerWindowID] ?? [])) {
            return [openerGroupIdentifier]
        }

        if let openingContext,
           openingContext.bundleIdentifier != window.bundleIdentifier,
           let openerGroupIdentifier = firstConfiguredGroupIdentifier(in: candidates.intersection(defaultGroupIdentifiers(for: openingContext.bundleIdentifier))) {
            return [openerGroupIdentifier]
        }

        if let peerGroupIdentifier = sameScreenPeerGroupIdentifier(for: window,
                                                                   candidates: candidates,
                                                                   windows: windows) {
            return [peerGroupIdentifier]
        }

        return nil
    }

    private func fallbackGroupIdentifiers(candidates: Set<Int>) -> Set<Int> {
        guard let groupIdentifier = firstConfiguredGroupIdentifier(in: candidates) else {
            return []
        }

        return [groupIdentifier]
    }

    private func firstConfiguredGroupIdentifier(in groupIdentifiers: Set<Int>) -> Int? {
        configuredGroupIdentifiers.first { groupIdentifiers.contains($0) }
    }

    private func sameScreenPeerGroupIdentifier(for window: AutoTileWindow,
                                               candidates: Set<Int>,
                                               windows: [AutoTileWindow]) -> Int? {
        var groupScores: [Int: Int] = [:]
        let screenKey = AutoTileScreenKey(window.screenVisibleFrame)

        for peerWindow in windows where peerWindow.id != window.id && AutoTileScreenKey(peerWindow.screenVisibleFrame) == screenKey {
            let peerDefaultGroups = defaultGroupIdentifiers(for: peerWindow.bundleIdentifier)
            let peerGroups: Set<Int>

            if peerDefaultGroups.count == 1 {
                peerGroups = peerDefaultGroups
            } else if let assignedPeerGroups = windowGroupIdentifiersByID[peerWindow.id]?.intersection(peerDefaultGroups),
                      !assignedPeerGroups.isEmpty {
                peerGroups = assignedPeerGroups
            } else {
                continue
            }

            for groupIdentifier in peerGroups.intersection(candidates) {
                groupScores[groupIdentifier, default: 0] += 1
            }
        }

        guard let highestScore = groupScores.values.max(),
              highestScore > 0 else {
            return nil
        }

        let matchingGroupIdentifiers = Set(groupScores.compactMap { groupIdentifier, score in
            score == highestScore ? groupIdentifier : nil
        })

        guard matchingGroupIdentifiers.count == 1 else {
            return nil
        }

        return firstConfiguredGroupIdentifier(in: matchingGroupIdentifiers)
    }

    private func updateGroupWindowOrders(for windows: [AutoTileWindow]) {
        for groupIdentifier in configuredGroupIdentifiers {
            let groupWindows = windows.filter { groupIdentifiers(for: $0).contains(groupIdentifier) }
            guard !groupWindows.isEmpty else {
                continue
            }

            orderedWindowIDsByGroup[groupIdentifier] = orderedWindowIDs(groupWindows,
                                                                        in: groupIdentifier)
        }

        orderedWindowIDsByGroup = orderedWindowIDsByGroup.filter { groupIdentifier, _ in
            configuredGroupIdentifiers.contains(groupIdentifier)
        }
    }

    private func rememberLeadingWindowSlots(from windows: [AutoTileWindow]) {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let orderedWindows = orderedWindowIDs.compactMap { windowsByID[$0] }
        let orderedWindowIDSet = Set(orderedWindows.map(\.id))
        let initialWindows = windows
            .filter { !orderedWindowIDSet.contains($0.id) }
            .sorted(by: Self.windowSpatialSort)
        let slotCandidateWindows = orderedWindows.isEmpty ? initialWindows : orderedWindows

        for groupIdentifier in configuredGroupIdentifiers {
            let groupOrderedWindows = (orderedWindowIDsByGroup[groupIdentifier] ?? [])
                .compactMap { windowsByID[$0] }
            let groupWindows = groupOrderedWindows.isEmpty ?
                slotCandidateWindows.filter { groupIdentifiers(for: $0).contains(groupIdentifier) } :
                groupOrderedWindows
            guard !groupWindows.isEmpty else {
                continue
            }

            var rememberedSlots = rememberedWindowSlotsByGroup[groupIdentifier] ?? [:]

            for (slot, window) in groupWindows.prefix(2).enumerated() {
                guard let fingerprint = AutoTileWindowFingerprint(window) else {
                    continue
                }

                rememberedSlots[fingerprint] = slot
            }

            rememberedWindowSlotsByGroup[groupIdentifier] = rememberedSlots
        }
    }

    private func updatedWindowOrder(currentWindowIDs: Set<AutoTileWindowID>,
                                    windows: [AutoTileWindow]) -> [AutoTileWindowID] {
        let retainedWindowIDs = Self.uniqueWindowIDs(orderedWindowIDs.filter { currentWindowIDs.contains($0) })
        let retainedWindowIDSet = Set(retainedWindowIDs)
        let newWindowIDs = Self.defaultWindowOrder(windows.filter { !retainedWindowIDSet.contains($0.id) })

        return retainedWindowIDs + newWindowIDs
    }

    private func orderedWindowIDs(_ windows: [AutoTileWindow],
                                  in groupIdentifier: Int) -> [AutoTileWindowID] {
        orderedWindows(windows, in: groupIdentifier).map(\.id)
    }

    private func orderedWindows(_ windows: [AutoTileWindow],
                                in groupIdentifier: Int) -> [AutoTileWindow] {
        let windowsByBundleIdentifier = Dictionary(grouping: windows) { $0.bundleIdentifier }
        var orderedWindows: [AutoTileWindow] = []
        var usedWindowIDs: Set<AutoTileWindowID> = []

        func append(_ windows: [AutoTileWindow]) {
            let sortedWindows = windows.sorted {
                windowSortForRetainedOrder($0, $1, in: groupIdentifier)
            }

            for window in sortedWindows where usedWindowIDs.insert(window.id).inserted {
                orderedWindows.append(window)
            }
        }

        let mainBundleIdentifiers = mainBundleIdentifiers(in: groupIdentifier)

        for bundleIdentifier in mainBundleIdentifiers {
            append(windowsByBundleIdentifier[bundleIdentifier] ?? [])
        }

        let mainBundleIdentifierSet = Set(mainBundleIdentifiers)
        for bundleIdentifier in bundleIdentifierOrder(in: groupIdentifier) {
            guard !mainBundleIdentifierSet.contains(bundleIdentifier) else {
                continue
            }

            append(windowsByBundleIdentifier[bundleIdentifier] ?? [])
        }

        append(windows.filter { !usedWindowIDs.contains($0.id) })
        return orderedWindows
    }

    private func windowSortForRetainedOrder(_ lhs: AutoTileWindow,
                                            _ rhs: AutoTileWindow,
                                            in groupIdentifier: Int) -> Bool {
        let lhsIndex = retainedOrderIndex(for: lhs.id, in: groupIdentifier)
        let rhsIndex = retainedOrderIndex(for: rhs.id, in: groupIdentifier)

        if lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }

        return Self.windowSpatialSort(lhs, rhs)
    }

    private func retainedOrderIndex(for windowID: AutoTileWindowID,
                                    in groupIdentifier: Int) -> Int {
        let groupWindowIDs = orderedWindowIDsByGroup[groupIdentifier] ?? []
        if let groupIndex = groupWindowIDs.firstIndex(of: windowID) {
            return groupIndex
        }

        if let globalIndex = orderedWindowIDs.firstIndex(of: windowID) {
            return groupWindowIDs.count + globalIndex
        }

        return Int.max
    }

    private func activateMainAppsRelatedToNewWindows(newWindowIDs: Set<AutoTileWindowID>,
                                                     windows: [AutoTileWindow]) {
        guard !newWindowIDs.isEmpty else {
            return
        }

        let openedBundleIdentifiers = Set(windows
            .filter { newWindowIDs.contains($0.id) }
            .map(\.bundleIdentifier))
        if activateMainAppsRelated(to: openedBundleIdentifiers) {
            scheduleMainAppRetiles()
        }
    }

    private func reassertMainAppsForFrontmostApplication() {
        guard isRunning,
              !isApplyingTile,
              let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              isMainAppBundleIdentifier(bundleIdentifier) else {
            return
        }

        let now = Date()
        if let lastMainAppFocusReassertion,
           lastMainAppFocusReassertion.bundleIdentifier == bundleIdentifier,
           now.timeIntervalSince(lastMainAppFocusReassertion.date) < mainAppFocusReassertionInterval {
            return
        }

        self.lastMainAppFocusReassertion = (bundleIdentifier, now)

        if activateMainAppsRelated(to: [bundleIdentifier],
                                   excluding: [bundleIdentifier]) {
            scheduleMainAppRetiles()
        }
    }

    private func isMainAppBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        return mainAppBundleIdentifiersByGroup.values.contains { $0.contains(bundleIdentifier) }
    }

    private func groupedBundleIdentifiersRelated(to bundleIdentifiers: Set<String>,
                                                 excluding excludedBundleIdentifiers: Set<String> = []) -> Set<String> {
        Set(configuredGroupIdentifiers.flatMap { groupIdentifier -> [String] in
            let groupBundleIdentifiers = Set(appBundleIdentifiersByGroup[groupIdentifier] ?? [])

            guard !groupBundleIdentifiers.isDisjoint(with: bundleIdentifiers) else {
                return []
            }

            return Array(groupBundleIdentifiers)
        }).subtracting(excludedBundleIdentifiers)
    }

    @discardableResult
    private func activateMainAppsRelated(to bundleIdentifiers: Set<String>,
                                         excluding excludedBundleIdentifiers: Set<String> = []) -> Bool {
        let relatedMainBundleIdentifiers = Set(configuredGroupIdentifiers.flatMap { groupIdentifier -> [String] in
            let mainBundleIdentifiers = mainBundleIdentifiers(in: groupIdentifier)
            let mainBundleIdentifierSet = Set(mainBundleIdentifiers)

            guard !mainBundleIdentifiers.isEmpty,
                  !mainBundleIdentifierSet.isDisjoint(with: bundleIdentifiers) else {
                return []
            }

            return mainBundleIdentifiers
        }).subtracting(excludedBundleIdentifiers)

        guard !relatedMainBundleIdentifiers.isEmpty else {
            return false
        }

        return mover.revealApplications(bundleIdentifiers: relatedMainBundleIdentifiers) > 0
    }

    private func normalizedMainAppBundleIdentifiersByGroup(_ settings: [Int: [String]]) -> [Int: [String]] {
        Dictionary(uniqueKeysWithValues: configuredGroupIdentifiers.map { groupIdentifier in
            let configuredBundleIdentifiers = Set(appBundleIdentifiersByGroup[groupIdentifier] ?? [])
            var seenBundleIdentifiers: Set<String> = []
            let identifiers = (settings[groupIdentifier] ?? []).filter { identifier in
                configuredBundleIdentifiers.contains(identifier) &&
                    seenBundleIdentifiers.insert(identifier).inserted
            }

            return (groupIdentifier, identifiers)
        })
    }

    private static func defaultWindowOrder(_ windows: [AutoTileWindow]) -> [AutoTileWindowID] {
        windows
            .sorted(by: windowSpatialSort)
            .map(\.id)
    }

    private static func primaryWidthFraction(for frame: CGRect,
                                             in screenVisibleFrame: CGRect) -> CGFloat {
        guard screenVisibleFrame.width > 0 else {
            return 0.5
        }

        return min(max(frame.width / screenVisibleFrame.width, 0.2), 0.85)
    }

    private static func windowSpatialSort(_ lhs: AutoTileWindow, _ rhs: AutoTileWindow) -> Bool {
        if abs(lhs.frame.midX - rhs.frame.midX) > 8 {
            return lhs.frame.midX < rhs.frame.midX
        }

        if abs(lhs.frame.midY - rhs.frame.midY) > 8 {
            return lhs.frame.midY < rhs.frame.midY
        }

        if lhs.area != rhs.area {
            return lhs.area > rhs.area
        }

        return windowSortKey(lhs) < windowSortKey(rhs)
    }

    private static func windowSortKey(_ window: AutoTileWindow) -> String {
        "\(window.processIdentifier)-\(window.id.elementHash)"
    }

    private func orderedCandidateWindows(_ windows: [AutoTileWindow]) -> [AutoTileWindow] {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let orderedWindows = orderedWindowIDs.compactMap { windowsByID[$0] }
        let orderedWindowIDSet = Set(orderedWindows.map(\.id))
        let unorderedWindows = windows
            .filter { !orderedWindowIDSet.contains($0.id) }
            .sorted(by: Self.windowSpatialSort)

        return orderedWindows + unorderedWindows
    }

    private static func uniqueWindowIDs(_ windowIDs: [AutoTileWindowID]) -> [AutoTileWindowID] {
        var seenWindowIDs: Set<AutoTileWindowID> = []
        return windowIDs.filter { seenWindowIDs.insert($0).inserted }
    }
}

private struct AutoTileScreenKey: Hashable {
    let minX: Int
    let minY: Int
    let width: Int
    let height: Int

    init(_ frame: CGRect) {
        minX = Int(frame.minX.rounded(.toNearestOrAwayFromZero))
        minY = Int(frame.minY.rounded(.toNearestOrAwayFromZero))
        width = Int(frame.width.rounded(.toNearestOrAwayFromZero))
        height = Int(frame.height.rounded(.toNearestOrAwayFromZero))
    }
}

private struct AutoTileWindowFingerprint: Hashable {
    let bundleIdentifier: String
    let title: String

    init?(_ window: AutoTileWindow) {
        guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        bundleIdentifier = window.bundleIdentifier
        self.title = title
    }
}

private final class ObservedApplication {
    let observer: AXObserver
    let applicationElement: AXUIElement
    let runLoopSource: CFRunLoopSource
    var windowElementsByID: [AutoTileWindowID: AXUIElement] = [:]

    init(observer: AXObserver,
         applicationElement: AXUIElement,
         runLoopSource: CFRunLoopSource) {
        self.observer = observer
        self.applicationElement = applicationElement
        self.runLoopSource = runLoopSource
    }
}

private let autoTilerAccessibilityObserverCallback: AXObserverCallback = { _, element, notification, userInfo in
    guard let userInfo else {
        return
    }

    let autoTiler = Unmanaged<AutoTiler>.fromOpaque(userInfo).takeUnretainedValue()
    let notificationName = notification as String
    Task { @MainActor in
        autoTiler.handleAccessibilityNotification(notificationName, element: element)
    }
}
