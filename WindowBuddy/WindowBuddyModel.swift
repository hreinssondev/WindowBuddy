//
//  WindowBuddyModel.swift
//  WindowBuddy
//
//  Created by Codex on 01/06/2026.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WindowBuddyModel: ObservableObject {
    @Published var isAutoTilingEnabled: Bool {
        didSet {
            userDefaults.set(isAutoTilingEnabled, forKey: Self.autoTilingEnabledDefaultsKey)
            updateAutoTilerState()

            if isAutoTilingEnabled, accessibilityGranted, !hasSelectedAutoTileApps {
                statusMessage = "No apps are selected for tiling."
            } else if isAutoTilingEnabled, accessibilityGranted {
                statusMessage = "Auto tiling is active."
            } else if isAutoTilingEnabled {
                statusMessage = "Grant Accessibility permission to enable auto tiling."
            } else {
                statusMessage = "Auto tiling is off."
            }
        }
    }

    @Published var usesInstantWindowMovement: Bool {
        didSet {
            userDefaults.set(usesInstantWindowMovement, forKey: Self.instantWindowMovementDefaultsKey)
            mover.usesInstantWindowMovement = usesInstantWindowMovement
            statusMessage = usesInstantWindowMovement ? "Window moves are instant." : "Window moves use the standard animation."
        }
    }

    @Published var excludesManuallyMovedWindowsFromAutoTiling: Bool {
        didSet {
            userDefaults.set(excludesManuallyMovedWindowsFromAutoTiling,
                             forKey: Self.excludesManuallyMovedWindowsFromAutoTilingDefaultsKey)
            autoTiler.excludesManuallyMovedWindowsFromAutoTiling = excludesManuallyMovedWindowsFromAutoTiling
            if excludesManuallyMovedWindowsFromAutoTiling {
                statusMessage = "Move or snap a window once to exclude it; do so again to resume auto tiling."
            } else if keepsFullSizeWindowsOutOfAutoTiling {
                statusMessage = "The two-move cycle remains active through the full-size exclusion setting."
            } else {
                statusMessage = "Manually moved windows can return to auto tiling."
            }
        }
    }

    @Published var keepsFullSizeWindowsOutOfAutoTiling: Bool {
        didSet {
            userDefaults.set(keepsFullSizeWindowsOutOfAutoTiling,
                             forKey: Self.keepsFullSizeWindowsOutOfAutoTilingDefaultsKey)
            autoTiler.keepsFullSizeWindowsOutOfAutoTiling = keepsFullSizeWindowsOutOfAutoTiling
            if keepsFullSizeWindowsOutOfAutoTiling {
                statusMessage = "Full-size windows stay untiled, with the same two-action cycle for manual moves and snaps."
            } else if excludesManuallyMovedWindowsFromAutoTiling {
                statusMessage = "The two-move cycle remains active for manually moved windows."
            } else {
                statusMessage = "Full-size windows can return to auto tiling."
            }
        }
    }

    @Published var widensFocusedAutoTileWindow: Bool {
        didSet {
            userDefaults.set(widensFocusedAutoTileWindow, forKey: Self.widensFocusedAutoTileWindowDefaultsKey)
            autoTiler.widensFocusedWindow = widensFocusedAutoTileWindow
            statusMessage = widensFocusedAutoTileWindow ? "Focused tiled windows get extra width." : "Focused tiled windows use normal tile sizes."
        }
    }

    @Published var focusedAutoTileWindowWidthFraction: Double {
        didSet {
            let normalizedWidthFraction = Self.normalizedFocusedAutoTileWindowWidthFraction(focusedAutoTileWindowWidthFraction)

            if normalizedWidthFraction != focusedAutoTileWindowWidthFraction {
                focusedAutoTileWindowWidthFraction = normalizedWidthFraction
                return
            }

            userDefaults.set(normalizedWidthFraction, forKey: Self.focusedAutoTileWindowWidthFractionDefaultsKey)
            autoTiler.focusedWindowPrimaryWidthFraction = CGFloat(normalizedWidthFraction)
            statusMessage = "Focused tiled windows use \(Self.focusedAutoTileWindowWidthText(for: normalizedWidthFraction)) width."
        }
    }

    @Published var movesExistingAutoTileAppWindowsToFocusedGroup: Bool {
        didSet {
            userDefaults.set(movesExistingAutoTileAppWindowsToFocusedGroup,
                             forKey: Self.movesExistingAutoTileAppWindowsToFocusedGroupDefaultsKey)
            autoTiler.movesExistingAppWindowsToFocusedGroup = movesExistingAutoTileAppWindowsToFocusedGroup
            statusMessage = movesExistingAutoTileAppWindowsToFocusedGroup ?
                "Open app windows move into the focused group." :
                "Open app windows stay in their current group."
        }
    }

    @Published var revealsActiveAutoTileGroupApps: Bool {
        didSet {
            userDefaults.set(revealsActiveAutoTileGroupApps,
                             forKey: Self.revealsActiveAutoTileGroupAppsDefaultsKey)
            autoTiler.revealsActiveGroupApps = revealsActiveAutoTileGroupApps
            statusMessage = revealsActiveAutoTileGroupApps ?
                "Focusing a grouped app reveals its group apps with open windows." :
                "Focusing a grouped app only reveals that app."
        }
    }

    @Published var focusGroupSwitchingHidesOthers: Bool {
        didSet {
            userDefaults.set(focusGroupSwitchingHidesOthers,
                             forKey: Self.focusGroupSwitchingHidesOthersDefaultsKey)
            statusMessage = focusGroupSwitchingHidesOthers ?
                "Focus group switching hides other groups." :
                "Focus group switching brings groups forward without hiding apps."
        }
    }

    @Published var focusGroupSwitchDelay: Double {
        didSet {
            let normalizedDelay = Self.normalizedFocusGroupSwitchDelay(focusGroupSwitchDelay)

            if normalizedDelay != focusGroupSwitchDelay {
                focusGroupSwitchDelay = normalizedDelay
                return
            }

            userDefaults.set(normalizedDelay,
                             forKey: Self.focusGroupSwitchDelayDefaultsKey)
            reschedulePendingFocusGroupSwitchIfNeeded()
            statusMessage = normalizedDelay == 0 ?
                "Focus groups switch without an added delay." :
                "Focus group switches are spaced \(Self.focusGroupSwitchDelayText(for: normalizedDelay)) apart."
        }
    }

    @Published var switchesAwayFromSingleAppFocusGroups: Bool {
        didSet {
            userDefaults.set(switchesAwayFromSingleAppFocusGroups,
                             forKey: Self.switchesAwayFromSingleAppFocusGroupsDefaultsKey)
            statusMessage = switchesAwayFromSingleAppFocusGroups ?
                "Single-app focus groups switch to the other focused group." :
                "Single-app focus groups use hide and reveal."
        }
    }

    @Published var showsDockIcon: Bool {
        didSet {
            userDefaults.set(showsDockIcon, forKey: Self.showsDockIconDefaultsKey)
            applyActivationPolicy()
            statusMessage = showsDockIcon ? "Dock icon is visible." : "WindowBuddy is menu bar only."
        }
    }
    @Published private(set) var settingsShortcut: DockMoverShortcut
    @Published private(set) var focusGroupsForwardShortcut: DockMoverShortcut
    @Published private(set) var focusGroupsBackwardShortcut: DockMoverShortcut
    @Published private(set) var focusGroupOnePhysicalKey: FocusGroupPhysicalKey
    @Published private(set) var focusGroupTwoPhysicalKey: FocusGroupPhysicalKey
    @Published private(set) var focusGroupPhysicalKeyValidationMessage: String?

    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var statusMessage = "Waiting for Accessibility permission."
    @Published private(set) var autoTileAppGroups: [AutoTileAppGroup] = []
    @Published private(set) var focusTileWiderFixedAutoTileAppBundleIdentifiers: Set<String> = []
    @Published private(set) var focusGroupIdentifiers: [Int] = []
    @Published private(set) var focusedGroupNumberByGroup: [Int: Int] = [:]
    @Published private(set) var activeFocusGroupIdentifier: Int?
    @Published private(set) var activeSecondaryFocusGroupIdentifier: Int?
    @Published private(set) var availableAutoTileApps: [AutoTileAppSelection] = []
    @Published private(set) var isLoadingAvailableAutoTileApps = false

    private static let autoTilingEnabledDefaultsKey = "autoTilingEnabled"
    private static let instantWindowMovementDefaultsKey = "instantWindowMovement"
    private static let excludesManuallyMovedWindowsFromAutoTilingDefaultsKey = "excludesManuallyMovedWindowsFromAutoTiling"
    private static let keepsFullSizeWindowsOutOfAutoTilingDefaultsKey = "keepsFullSizeWindowsOutOfAutoTiling"
    private static let focusTileWiderFixedBundleIdentifiersDefaultsKey = "focusTileWiderFixedBundleIdentifiers"
    private static let focusTileWiderResizableBundleIdentifiersDefaultsKey = "focusTileWiderResizableBundleIdentifiers"
    private static let focusGroupIdentifiersDefaultsKey = "focusGroupIdentifiers"
    private static let focusedGroupNumberByGroupDefaultsKey = "focusedGroupNumberByGroup"
    private static let activeFocusGroupIdentifierDefaultsKey = "activeFocusGroupIdentifier"
    private static let activeSecondaryFocusGroupIdentifierDefaultsKey = "activeSecondaryFocusGroupIdentifier"
    private static let existingFirstNewWindowBundleIdentifiersDefaultsKey = "existingFirstNewWindowBundleIdentifiers"
    private static let widensFocusedAutoTileWindowDefaultsKey = "widensFocusedAutoTileWindow"
    private static let focusedAutoTileWindowWidthFractionDefaultsKey = "focusedAutoTileWindowWidthFraction"
    private static let movesExistingAutoTileAppWindowsToFocusedGroupDefaultsKey = "movesExistingAutoTileAppWindowsToFocusedGroup"
    private static let revealsActiveAutoTileGroupAppsDefaultsKey = "revealsActiveAutoTileGroupApps"
    private static let focusGroupSwitchingHidesOthersDefaultsKey = "focusGroupSwitchingHidesOthers"
    private static let focusGroupSwitchDelayDefaultsKey = "focusGroupSwitchDelay"
    private static let switchesAwayFromSingleAppFocusGroupsDefaultsKey = "switchesAwayFromSingleAppFocusGroups"
    private static let showsDockIconDefaultsKey = "showsDockIcon"
    private static let settingsShortcutDefaultsKey = "windowBuddySettingsShortcut"
    private static let focusGroupsForwardShortcutDefaultsKey = "focusGroupsForwardShortcut"
    private static let focusGroupsBackwardShortcutDefaultsKey = "focusGroupsBackwardShortcut"
    private static let focusGroupOnePhysicalKeyDefaultsKey = "focusGroupOnePhysicalKeyCode"
    private static let focusGroupTwoPhysicalKeyDefaultsKey = "focusGroupTwoPhysicalKeyCode"
    private static let fillsFirstWindowByGroupDefaultsKey = "fillsFirstWindowByGroup"
    private static let screenLayoutModeByGroupDefaultsKey = "screenLayoutModeByGroup"
    private static let maximumColumnCountByGroupDefaultsKey = "maximumColumnCountByGroup"
    private static let tileDirectionByGroupDefaultsKey = "tileDirectionByGroup"
    private static let mainAppBundleIdentifiersByGroupDefaultsKey = "mainAppBundleIdentifiersByGroup"
    private static let ignoresSecondAppInListDefaultsKey = "ignoresSecondAppInList"
    private static let ignoresSecondAppInListByGroupDefaultsKey = "ignoresSecondAppInListByGroup"
    private static let ignoredSecondWindowStartModeByGroupDefaultsKey = "ignoredSecondWindowStartModeByGroup"
    private static let autoTileAppGroupsDefaultsKey = "autoTileAppGroups"
    private static let autoTileAppBundleIdentifiersDefaultsKey = "autoTileAppBundleIdentifiers"
    private static let autoTileGroupCount = 10
    static let maximumColumnCountRange: ClosedRange<Int> = 1...8
    private static let defaultMaximumColumnCount = 3
    static let focusedAutoTileWindowWidthFractionRange: ClosedRange<Double> = 0.52...0.85
    private static let defaultFocusedAutoTileWindowWidthFraction = 0.56
    static let focusGroupSwitchDelayRange: ClosedRange<Double> = 0...0.5
    private static let defaultFocusGroupSwitchDelay = 0.0

    private struct FocusGroupSwitchRequest {
        let reverse: Bool
        let number: Int
    }

    private let userDefaults: UserDefaults
    private let mover = AccessibilityWindowMover()
    private let autoTileLayoutMode: AutoTileLayoutMode = .sharedGrid
    private let autoTileSpeedMode: AutoTileSpeedMode = .normal
    private var autoTileAppBundleIdentifiersByGroup: [Int: Set<String>] = [:]
    private var autoTileAppGroupIdentifiersByBundleIdentifierCache: [String: Set<Int>] = [:]
    private var mainAppBundleIdentifiersByGroup: [Int: [String]] = [:]
    private var fillsFirstWindowByGroup: [Int: Bool] = [:]
    private var screenLayoutModeByGroup: [Int: AutoTileScreenLayoutMode] = [:]
    private var maximumColumnCountByGroup: [Int: Int] = [:]
    private var tileDirectionByGroup: [Int: AutoTileDirection] = [:]
    private var ignoresSecondAppInListByGroup: [Int: Bool] = [:]
    private var ignoredSecondWindowStartModeByGroup: [Int: AutoTileIgnoredSecondWindowStartMode] = [:]
    private var focusTileWiderResizableBundleIdentifiers: Set<String> = []
    private var lastCycledFocusGroupNumber: Int?
    private var focusGroupTransitionDeadlineByNumber: [Int: Date] = [:]
    private var pendingFocusGroupSwitchRequests: [FocusGroupSwitchRequest] = []
    private var pendingFocusGroupSwitchTask: Task<Void, Never>?
    private var lastFocusGroupSwitchExecutionDate: Date?
    private var hasLoadedAvailableAutoTileApps = false
    private lazy var autoTiler = AutoTiler(mover: mover,
                                           appGroupIdentifiersByBundleIdentifier: autoTileAppGroupIdentifiersByBundleIdentifier,
                                           appBundleIdentifiersByGroup: autoTileAppBundleIdentifierOrderByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           layoutMode: autoTileLayoutMode,
                                           speedMode: autoTileSpeedMode,
                                           focusTileWiderFixedBundleIdentifiers: focusTileWiderFixedAutoTileAppBundleIdentifiers,
                                           widensFocusedWindow: widensFocusedAutoTileWindow,
                                           focusedWindowPrimaryWidthFraction: CGFloat(focusedAutoTileWindowWidthFraction),
                                           movesExistingAppWindowsToFocusedGroup: movesExistingAutoTileAppWindowsToFocusedGroup,
                                           revealsActiveGroupApps: revealsActiveAutoTileGroupApps,
                                           excludesManuallyMovedWindowsFromAutoTiling: excludesManuallyMovedWindowsFromAutoTiling,
                                           keepsFullSizeWindowsOutOfAutoTiling: keepsFullSizeWindowsOutOfAutoTiling,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup) { [weak self] result in
        guard let self else {
            return
        }

        switch result {
        case let .success(result):
            if result.skippedWindowCount > 0 {
                statusMessage = "Auto tiled \(result.tiledWindowCount) windows. \(result.skippedWindowCount) were left alone."
            } else {
                statusMessage = "Auto tiled \(result.tiledWindowCount) windows."
            }
        case let .failure(error):
            if isAutoTilingEnabled {
                statusMessage = error.localizedDescription
            }
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isAutoTilingEnabled = true
        userDefaults.set(true, forKey: Self.autoTilingEnabledDefaultsKey)
        autoTileAppBundleIdentifiersByGroup = Self.storedAppGroups(in: userDefaults)
        autoTileAppGroupIdentifiersByBundleIdentifierCache = Self.appGroupIdentifiersByBundleIdentifier(for: autoTileAppBundleIdentifiersByGroup)
        mainAppBundleIdentifiersByGroup = Self.storedMainAppBundleIdentifiersByGroup(in: userDefaults,
                                                                                     appGroups: autoTileAppBundleIdentifiersByGroup)
        fillsFirstWindowByGroup = Self.storedFillsFirstWindowByGroup(in: userDefaults)
        screenLayoutModeByGroup = Self.storedScreenLayoutModeByGroup(in: userDefaults)
        maximumColumnCountByGroup = Self.storedMaximumColumnCountByGroup(in: userDefaults)
        tileDirectionByGroup = Self.storedTileDirectionByGroup(in: userDefaults)
        ignoresSecondAppInListByGroup = Self.storedIgnoresSecondAppInListByGroup(in: userDefaults)
        ignoredSecondWindowStartModeByGroup = Self.storedIgnoredSecondWindowStartModeByGroup(in: userDefaults)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        focusTileWiderResizableBundleIdentifiers = Self.storedFocusTileWiderResizableBundleIdentifiers(in: userDefaults,
                                                                                                       appGroups: autoTileAppBundleIdentifiersByGroup)
        focusTileWiderFixedAutoTileAppBundleIdentifiers = Self.focusTileWiderFixedBundleIdentifiers(resizableBundleIdentifiers: focusTileWiderResizableBundleIdentifiers,
                                                                                                    appGroups: autoTileAppBundleIdentifiersByGroup)
        let storedFocusGroupIdentifiers = Self.storedFocusGroupIdentifiers(in: userDefaults,
                                                                           appGroups: autoTileAppBundleIdentifiersByGroup)
        let storedFocusedGroupNumberByGroup = Self.storedFocusedGroupNumberByGroup(in: userDefaults,
                                                                                   appGroups: autoTileAppBundleIdentifiersByGroup,
                                                                                   legacyFocusGroupIdentifiers: storedFocusGroupIdentifiers)
        focusGroupIdentifiers = storedFocusGroupIdentifiers
        focusedGroupNumberByGroup = storedFocusedGroupNumberByGroup
        activeFocusGroupIdentifier = Self.storedActiveFocusGroupIdentifier(in: userDefaults,
                                                                           focusGroupIdentifiers: storedFocusGroupIdentifiers)
        activeSecondaryFocusGroupIdentifier = Self.storedActiveFocusGroupIdentifier(in: userDefaults,
                                                                                   key: Self.activeSecondaryFocusGroupIdentifierDefaultsKey,
                                                                                   focusGroupIdentifiers: Self.focusGroupIdentifiers(in: storedFocusedGroupNumberByGroup,
                                                                                                                                      number: 2))

        if userDefaults.object(forKey: Self.instantWindowMovementDefaultsKey) == nil {
            usesInstantWindowMovement = true
        } else {
            usesInstantWindowMovement = userDefaults.bool(forKey: Self.instantWindowMovementDefaultsKey)
        }

        if userDefaults.object(forKey: Self.excludesManuallyMovedWindowsFromAutoTilingDefaultsKey) == nil {
            excludesManuallyMovedWindowsFromAutoTiling = false
        } else {
            excludesManuallyMovedWindowsFromAutoTiling = userDefaults.bool(
                forKey: Self.excludesManuallyMovedWindowsFromAutoTilingDefaultsKey
            )
        }

        // Keeping full-size windows untiled is now always on and no longer
        // configurable from the UI.
        keepsFullSizeWindowsOutOfAutoTiling = true

        if userDefaults.object(forKey: Self.widensFocusedAutoTileWindowDefaultsKey) == nil {
            widensFocusedAutoTileWindow = true
        } else {
            widensFocusedAutoTileWindow = userDefaults.bool(forKey: Self.widensFocusedAutoTileWindowDefaultsKey)
        }

        if userDefaults.object(forKey: Self.focusedAutoTileWindowWidthFractionDefaultsKey) == nil {
            focusedAutoTileWindowWidthFraction = Self.defaultFocusedAutoTileWindowWidthFraction
        } else {
            focusedAutoTileWindowWidthFraction = Self.normalizedFocusedAutoTileWindowWidthFraction(userDefaults.double(forKey: Self.focusedAutoTileWindowWidthFractionDefaultsKey))
        }

        if userDefaults.object(forKey: Self.movesExistingAutoTileAppWindowsToFocusedGroupDefaultsKey) == nil {
            movesExistingAutoTileAppWindowsToFocusedGroup = true
        } else {
            movesExistingAutoTileAppWindowsToFocusedGroup = userDefaults.bool(forKey: Self.movesExistingAutoTileAppWindowsToFocusedGroupDefaultsKey)
        }

        if userDefaults.object(forKey: Self.revealsActiveAutoTileGroupAppsDefaultsKey) == nil {
            revealsActiveAutoTileGroupApps = true
        } else {
            revealsActiveAutoTileGroupApps = userDefaults.bool(forKey: Self.revealsActiveAutoTileGroupAppsDefaultsKey)
        }

        if userDefaults.object(forKey: Self.focusGroupSwitchingHidesOthersDefaultsKey) == nil {
            focusGroupSwitchingHidesOthers = true
        } else {
            focusGroupSwitchingHidesOthers = userDefaults.bool(forKey: Self.focusGroupSwitchingHidesOthersDefaultsKey)
        }

        if userDefaults.object(forKey: Self.focusGroupSwitchDelayDefaultsKey) == nil {
            focusGroupSwitchDelay = Self.defaultFocusGroupSwitchDelay
        } else {
            focusGroupSwitchDelay = Self.normalizedFocusGroupSwitchDelay(
                userDefaults.double(forKey: Self.focusGroupSwitchDelayDefaultsKey)
            )
        }

        if userDefaults.object(forKey: Self.switchesAwayFromSingleAppFocusGroupsDefaultsKey) == nil {
            switchesAwayFromSingleAppFocusGroups = true
        } else {
            switchesAwayFromSingleAppFocusGroups = userDefaults.bool(
                forKey: Self.switchesAwayFromSingleAppFocusGroupsDefaultsKey
            )
        }

        if userDefaults.object(forKey: Self.showsDockIconDefaultsKey) == nil {
            showsDockIcon = true
        } else {
            showsDockIcon = userDefaults.bool(forKey: Self.showsDockIconDefaultsKey)
        }
        settingsShortcut = Self.storedShortcut(in: userDefaults,
                                               key: Self.settingsShortcutDefaultsKey,
                                               defaultShortcut: .windowBuddySettingsDefault)
        focusGroupsForwardShortcut = Self.storedShortcut(in: userDefaults,
                                                         key: Self.focusGroupsForwardShortcutDefaultsKey,
                                                         defaultShortcut: .focusGroupsForwardDefault)
        focusGroupsBackwardShortcut = Self.storedShortcut(in: userDefaults,
                                                          key: Self.focusGroupsBackwardShortcutDefaultsKey,
                                                          defaultShortcut: .focusGroupsBackwardDefault)
        let storedGroupOnePhysicalKey = Self.storedPhysicalKey(in: userDefaults,
                                                              key: Self.focusGroupOnePhysicalKeyDefaultsKey,
                                                              defaultKey: .groupOneDefault)
        let storedGroupTwoPhysicalKey = Self.storedPhysicalKey(in: userDefaults,
                                                              key: Self.focusGroupTwoPhysicalKeyDefaultsKey,
                                                              defaultKey: .groupTwoDefault)
        if FocusGroupPhysicalKey.conflicts(storedGroupOnePhysicalKey, storedGroupTwoPhysicalKey) {
            focusGroupOnePhysicalKey = .groupOneDefault
            focusGroupTwoPhysicalKey = .groupTwoDefault
            userDefaults.set(Int(FocusGroupPhysicalKey.groupOneDefault.keyCode),
                             forKey: Self.focusGroupOnePhysicalKeyDefaultsKey)
            userDefaults.set(Int(FocusGroupPhysicalKey.groupTwoDefault.keyCode),
                             forKey: Self.focusGroupTwoPhysicalKeyDefaultsKey)
        } else {
            focusGroupOnePhysicalKey = storedGroupOnePhysicalKey
            focusGroupTwoPhysicalKey = storedGroupTwoPhysicalKey
        }
        focusGroupPhysicalKeyValidationMessage = nil

        mover.usesInstantWindowMovement = usesInstantWindowMovement
    }

    var permissionStatusTitle: String {
        accessibilityGranted ? "Accessibility Enabled" : "Accessibility Needed"
    }

    var autoTilerStatusTitle: String {
        if isAutoTilingEnabled, !hasSelectedAutoTileApps {
            return "Choose App Groups"
        }

        return isAutoTilingEnabled ? "Auto Tiler Active" : "Auto Tiler Off"
    }

    var hasSelectedAutoTileApps: Bool {
        !autoTileAppGroupIdentifiersByBundleIdentifier.isEmpty
    }

    var hasAnyAutoTileGroups: Bool {
        !visibleAutoTileAppGroups.isEmpty
    }

    var visibleAutoTileAppGroups: [AutoTileAppGroup] {
        autoTileAppGroups.filter { !$0.apps.isEmpty }
    }

    var canAddAutoTileGroup: Bool {
        autoTileAppGroups.contains { $0.apps.isEmpty }
    }

    var firstEmptyAutoTileGroup: AutoTileAppGroup? {
        autoTileAppGroups.first { $0.apps.isEmpty }
    }

    var focusedAutoTileWindowWidthText: String {
        Self.focusedAutoTileWindowWidthText(for: focusedAutoTileWindowWidthFraction)
    }

    var focusGroupSwitchDelayText: String {
        Self.focusGroupSwitchDelayText(for: focusGroupSwitchDelay)
    }

    var focusTileWiderResizableAutoTileApps: [AutoTileAppSelection] {
        selectedAutoTileApps.filter { focusTileWiderResizableBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    var focusTileWiderFixedAutoTileApps: [AutoTileAppSelection] {
        selectedAutoTileApps.filter { !focusTileWiderResizableBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    func start() {
        loadAvailableAutoTileAppsIfNeeded()
        refreshAccessibilityStatus()

        guard accessibilityGranted else {
            statusMessage = "Grant Accessibility permission to enable auto tiling."
            return
        }

        let focusedBundleIdentifiers = focusedGroupNumberByGroup.keys.reduce(into: Set<String>()) { identifiers, groupIdentifier in
            identifiers.formUnion(autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? [])
        }
        // Earlier builds minimized focus-group windows. Restore that legacy
        // state while the apps are still hidden so the first app-level reveal
        // also appears as one group instead of animating window by window.
        _ = mover.prepareHiddenApplicationsForAppLevelReveal(bundleIdentifiers: focusedBundleIdentifiers)
        updateAutoTilerState()
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }

    func stop() {
        autoTiler.stop()
        focusGroupTransitionDeadlineByNumber = [:]
        pendingFocusGroupSwitchTask?.cancel()
        pendingFocusGroupSwitchTask = nil
        pendingFocusGroupSwitchRequests = []
        lastFocusGroupSwitchExecutionDate = nil
        statusMessage = "Auto tiling stopped."
    }

    func moveFrontmostWindow(to placement: WindowPlacement,
                             using variant: WindowLayoutVariant) {
        accessibilityGranted = AXIsProcessTrusted()

        guard accessibilityGranted else {
            statusMessage = "Grant Accessibility permission before moving windows."
            return
        }

        do {
            let target = try mover.frontmostWindowTarget()
            let result = try mover.move(target,
                                        to: placement,
                                        using: variant)

            if autoTiler.isRunning {
                let retileResult = try autoTiler.retileAroundMovedWindow(target,
                                                                         movedFrame: result.frame)
                if retileResult.tiledWindowCount > 0 {
                    statusMessage = "\(result.applicationName) moved \(result.placement.title.lowercased()). Tiling followed it."
                } else {
                    statusMessage = "\(result.applicationName) moved \(result.placement.title.lowercased())."
                }
            } else {
                statusMessage = "\(result.applicationName) moved \(result.placement.title.lowercased())."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func fillFrontmostWindowAndTemporarilyRemoveFromTiling() {
        accessibilityGranted = AXIsProcessTrusted()

        guard accessibilityGranted else {
            statusMessage = "Grant Accessibility permission before moving windows."
            return
        }

        do {
            let target = try mover.frontmostWindowTarget()

            guard autoTiler.isRunning else {
                let result = try mover.applyPreferredOpeningSize(target)
                statusMessage = result.didFillScreen ?
                    "\(target.applicationName) is full size." :
                    "\(target.applicationName) is half screen."
                return
            }

            let result = try autoTiler.temporarilyRemoveFromTilingAndFill(target)
            if !result.didFillScreen {
                statusMessage = "\(result.applicationName) is half screen."
            } else if result.removedFromTiling {
                statusMessage = "\(result.applicationName) is full size and temporarily out of tiling."
            } else {
                statusMessage = "\(result.applicationName) is full size. It was not part of the active tile set."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreMostRecentlyRemovedWindowToTiling() {
        accessibilityGranted = AXIsProcessTrusted()

        guard accessibilityGranted else {
            statusMessage = "Grant Accessibility permission before moving windows."
            return
        }

        guard autoTiler.isRunning else {
            statusMessage = "Auto tiling is off."
            return
        }

        do {
            let result = try autoTiler.restoreMostRecentlyRemovedWindowToTiling()
            if result.retileResult.tiledWindowCount > 0 {
                statusMessage = "\(result.applicationName) returned to tiling."
            } else {
                statusMessage = "\(result.applicationName) is back in the tile set."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resizeAutoTiledWindows() {
        accessibilityGranted = AXIsProcessTrusted()

        guard accessibilityGranted else {
            statusMessage = "Grant Accessibility permission before resizing tiled windows."
            return
        }

        guard autoTiler.isRunning else {
            statusMessage = "Auto tiling is off."
            return
        }

        do {
            let result = try autoTiler.resizeTiledWindowsIncludingOffscreen()
            if result.tiledWindowCount > 0 {
                statusMessage = "Resized \(result.tiledWindowCount) tiled windows."
            } else {
                statusMessage = "Tiled windows are already in place."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        updateAutoTilerState()

        if accessibilityGranted, isAutoTilingEnabled, hasSelectedAutoTileApps {
            statusMessage = "Auto tiling is active."
        } else if accessibilityGranted, isAutoTilingEnabled {
            statusMessage = "No apps are selected for tiling."
        } else if accessibilityGranted {
            statusMessage = "Accessibility is enabled. Auto tiling is off."
        } else {
            statusMessage = "Grant Accessibility permission to enable auto tiling."
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityStatus()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func loadAvailableAutoTileAppsIfNeeded() {
        guard !hasLoadedAvailableAutoTileApps, !isLoadingAvailableAutoTileApps else {
            return
        }

        isLoadingAvailableAutoTileApps = true

        Task.detached(priority: .utility) {
            let apps = AutoTileAppSelection.installedApplications()

            await MainActor.run {
                self.availableAutoTileApps = apps
                self.hasLoadedAvailableAutoTileApps = true
                self.isLoadingAvailableAutoTileApps = false
            }
        }
    }

    func addAutoTileApps(_ apps: [AutoTileAppSelection], in group: AutoTileAppGroup) {
        guard !apps.isEmpty else {
            return
        }

        setAutoTileAppBundleIdentifiers(apps.map(\.bundleIdentifier), in: group.index)
        statusMessage = apps.count == 1 ? "\(apps[0].displayName) joined \(group.title)." : "\(apps.count) apps joined \(group.title)."
    }

    func browseAutoTileApps(in group: AutoTileAppGroup) {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps for \(group.title)"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK else {
            return
        }

        let selectedApps = panel.urls.compactMap(AutoTileAppSelection.app(at:))
        guard !selectedApps.isEmpty else {
            return
        }

        addAutoTileApps(selectedApps, in: group)
    }

    func addAutoTileGroup() -> AutoTileAppGroup? {
        guard let group = firstEmptyAutoTileGroup else {
            statusMessage = "All \(Self.autoTileGroupCount) app groups are in use."
            return nil
        }

        return group
    }

    func removeAutoTileApp(_ app: AutoTileAppSelection, from group: AutoTileAppGroup) {
        var groups = autoTileAppBundleIdentifiersByGroup
        groups[group.index, default: []].remove(app.bundleIdentifier)
        setAutoTileAppBundleIdentifiersByGroup(groups)
        statusMessage = hasSelectedAutoTileApps ? "\(app.displayName) left \(group.title)." : "No apps are selected for tiling."
    }

    func clearAutoTileApps(in group: AutoTileAppGroup) {
        var groups = autoTileAppBundleIdentifiersByGroup
        groups[group.index] = []
        setAutoTileAppBundleIdentifiersByGroup(groups)
        statusMessage = "\(group.title) is empty."
    }

    func clearAllAutoTileGroups() {
        setAutoTileAppBundleIdentifiersByGroup([:])
        statusMessage = "No apps are selected for tiling."
    }

    func resetSavedAutoTileOrder() {
        autoTiler.resetSavedOrder()
        statusMessage = autoTiler.isRunning ? "Saved order reset to the current visible windows." : "Saved order reset."
    }

    func isFocusGroup(_ group: AutoTileAppGroup) -> Bool {
        focusGroupIdentifiers.contains(group.index)
    }

    func focusedGroupNumber(in group: AutoTileAppGroup) -> Int {
        focusedGroupNumberByGroup[group.index] ?? 0
    }

    func setFocusGroup(_ isFocusGroup: Bool, in group: AutoTileAppGroup) {
        setFocusedGroupNumber(isFocusGroup ? 1 : 0, in: group)
    }

    func setFocusedGroupNumber(_ number: Int, in group: AutoTileAppGroup) {
        guard !group.apps.isEmpty else {
            statusMessage = "\(group.title) needs apps before it can be a focus group."
            return
        }

        var numbers = focusedGroupNumberByGroup
        if number == 1 || number == 2 || number == 3 {
            numbers[group.index] = number
        } else {
            numbers.removeValue(forKey: group.index)
        }

        setFocusedGroupNumberByGroup(numbers)
        switch number {
        case 1, 2:
            statusMessage = "\(group.title) is focused group \(number)."
        case 3:
            statusMessage = "\(group.title) is focused group 1+2."
        default:
            statusMessage = "\(group.title) is not a focused group."
        }
    }

    func setSettingsShortcut(_ shortcut: DockMoverShortcut) {
        guard shortcut != settingsShortcut else {
            statusMessage = "Settings shortcut is already \(shortcut.displayText)."
            return
        }

        settingsShortcut = shortcut
        persistShortcut(shortcut, key: Self.settingsShortcutDefaultsKey)
        statusMessage = "Settings shortcut saved as \(shortcut.displayText)."
    }

    func setFocusGroupsForwardShortcut(_ shortcut: DockMoverShortcut) {
        focusGroupsForwardShortcut = shortcut
        persistShortcut(shortcut, key: Self.focusGroupsForwardShortcutDefaultsKey)
        statusMessage = "Forward focus group shortcut saved as \(shortcut.displayText)."
    }

    func setFocusGroupsBackwardShortcut(_ shortcut: DockMoverShortcut) {
        focusGroupsBackwardShortcut = shortcut
        persistShortcut(shortcut, key: Self.focusGroupsBackwardShortcutDefaultsKey)
        statusMessage = "Backward focus group shortcut saved as \(shortcut.displayText)."
    }

    @discardableResult
    func setFocusGroupPhysicalKey(_ key: FocusGroupPhysicalKey,
                                  number: Int) -> Bool {
        guard number == 1 || number == 2 else {
            return false
        }

        let otherKey = number == 1 ? focusGroupTwoPhysicalKey : focusGroupOnePhysicalKey
        guard !FocusGroupPhysicalKey.conflicts(key, otherKey) else {
            let message = "Focused groups 1 and 2 need different physical keys. Caps Lock and F17 also count as the same key."
            focusGroupPhysicalKeyValidationMessage = message
            statusMessage = message
            return false
        }

        if number == 1 {
            focusGroupOnePhysicalKey = key
            persistPhysicalKey(key, key: Self.focusGroupOnePhysicalKeyDefaultsKey)
        } else {
            focusGroupTwoPhysicalKey = key
            persistPhysicalKey(key, key: Self.focusGroupTwoPhysicalKeyDefaultsKey)
        }

        focusGroupPhysicalKeyValidationMessage = nil
        statusMessage = "Focused group \(number) key saved as \(key.displayText)."
        return true
    }

    func resetFocusGroupPhysicalKeys() {
        focusGroupOnePhysicalKey = .groupOneDefault
        focusGroupTwoPhysicalKey = .groupTwoDefault
        persistPhysicalKey(.groupOneDefault, key: Self.focusGroupOnePhysicalKeyDefaultsKey)
        persistPhysicalKey(.groupTwoDefault, key: Self.focusGroupTwoPhysicalKeyDefaultsKey)
        focusGroupPhysicalKeyValidationMessage = nil
        statusMessage = "Focused group keys reset to their defaults."
    }

    func toggleFocusGroups(reverse: Bool = false, number: Int = 1) {
        guard focusGroupSwitchDelay > 0 else {
            performFocusGroupSwitch(reverse: reverse, number: number)
            return
        }

        pendingFocusGroupSwitchRequests.append(
            FocusGroupSwitchRequest(reverse: reverse, number: number)
        )
        processNextFocusGroupSwitchIfNeeded()
    }

    private func processNextFocusGroupSwitchIfNeeded() {
        guard pendingFocusGroupSwitchTask == nil,
              !pendingFocusGroupSwitchRequests.isEmpty else {
            return
        }

        let elapsedSinceLastSwitch = lastFocusGroupSwitchExecutionDate.map {
            Date().timeIntervalSince($0)
        } ?? focusGroupSwitchDelay
        let remainingDelay = max(0, focusGroupSwitchDelay - elapsedSinceLastSwitch)

        guard remainingDelay > 0 else {
            performNextFocusGroupSwitch()
            return
        }

        pendingFocusGroupSwitchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            pendingFocusGroupSwitchTask = nil
            performNextFocusGroupSwitch()
        }
    }

    private func performNextFocusGroupSwitch() {
        guard !pendingFocusGroupSwitchRequests.isEmpty else {
            return
        }

        let request = pendingFocusGroupSwitchRequests.removeFirst()
        lastFocusGroupSwitchExecutionDate = Date()
        performFocusGroupSwitch(reverse: request.reverse, number: request.number)
        processNextFocusGroupSwitchIfNeeded()
    }

    private func reschedulePendingFocusGroupSwitchIfNeeded() {
        guard pendingFocusGroupSwitchTask != nil else {
            return
        }

        pendingFocusGroupSwitchTask?.cancel()
        pendingFocusGroupSwitchTask = nil
        processNextFocusGroupSwitchIfNeeded()
    }

    private func performFocusGroupSwitch(reverse: Bool, number: Int) {
        let focusGroupIdentifiers = focusGroupIdentifiers(number: number)
        guard !focusGroupIdentifiers.isEmpty else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let runningFocusGroupIdentifiers = runningConfiguredFocusGroupIdentifiers(number: number)
        guard !runningFocusGroupIdentifiers.isEmpty else {
            statusMessage = "No focus group apps are running."
            return
        }

        let frontmostGroupIdentifier = frontmostFocusGroupIdentifier(number: number)
        let storedActiveGroupIdentifier = activeFocusGroupIdentifier(number: number)
        let currentGroupIdentifier = focusGroupTransitionIsInFlight(number: number) ?
            storedActiveGroupIdentifier :
            (frontmostGroupIdentifier ?? storedActiveGroupIdentifier)
        let isSwitchingFocusGroupNumber = frontmostGroupIdentifier == nil &&
            lastCycledFocusGroupNumber != nil &&
            lastCycledFocusGroupNumber != number
        let targetGroupIdentifier: Int
        if runningFocusGroupIdentifiers.count == 1 {
            let groupIdentifier = runningFocusGroupIdentifiers[0]
            if currentGroupIdentifier == groupIdentifier, !isSwitchingFocusGroupNumber {
                if switchesAwayFromSingleAppFocusGroups,
                   (autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []).count == 1,
                   switchToOtherRunningFocusGroup(from: groupIdentifier,
                                                  currentNumber: number,
                                                  reverse: reverse) {
                    return
                }

                hideFocusGroup(groupIdentifier, number: number)
                lastCycledFocusGroupNumber = number
                return
            }

            revealFocusGroup(groupIdentifier, number: number)
            lastCycledFocusGroupNumber = number
            return
        } else {
            if isSwitchingFocusGroupNumber,
               let currentGroupIdentifier,
               runningFocusGroupIdentifiers.contains(currentGroupIdentifier) {
                targetGroupIdentifier = currentGroupIdentifier
            } else {
                let activeIndex = currentGroupIdentifier.flatMap { runningFocusGroupIdentifiers.firstIndex(of: $0) }
                let nextIndex = activeIndex.map {
                    reverse ?
                        ($0 - 1 + runningFocusGroupIdentifiers.count) % runningFocusGroupIdentifiers.count :
                        ($0 + 1) % runningFocusGroupIdentifiers.count
                } ?? (reverse ? runningFocusGroupIdentifiers.count - 1 : 0)
                targetGroupIdentifier = runningFocusGroupIdentifiers[nextIndex]
            }
        }

        activateFocusGroup(targetGroupIdentifier, number: number)
        lastCycledFocusGroupNumber = number
    }

    @discardableResult
    private func switchToOtherRunningFocusGroup(from sourceGroupIdentifier: Int,
                                                currentNumber: Int,
                                                reverse: Bool) -> Bool {
        let otherNumber = currentNumber == 1 ? 2 : 1
        let otherGroupIdentifiers = runningConfiguredFocusGroupIdentifiers(number: otherNumber)
            .filter { $0 != sourceGroupIdentifier }
        guard !otherGroupIdentifiers.isEmpty else {
            return false
        }

        let storedActiveGroupIdentifier = activeFocusGroupIdentifier(number: otherNumber)
        let targetGroupIdentifier: Int
        if let storedActiveGroupIdentifier,
           otherGroupIdentifiers.contains(storedActiveGroupIdentifier) {
            targetGroupIdentifier = storedActiveGroupIdentifier
        } else {
            targetGroupIdentifier = reverse ?
                (otherGroupIdentifiers.last ?? otherGroupIdentifiers[0]) :
                otherGroupIdentifiers[0]
        }

        activateFocusGroup(targetGroupIdentifier, number: otherNumber)
        lastCycledFocusGroupNumber = otherNumber
        return true
    }

    func setAutoTileAppIsMain(_ isMain: Bool, app: AutoTileAppSelection, in group: AutoTileAppGroup) {
        var mainApps = mainAppBundleIdentifiersByGroup

        if isMain {
            var groupMainApps = mainApps[group.index] ?? []
            groupMainApps.removeAll { $0 == app.bundleIdentifier }
            groupMainApps.append(app.bundleIdentifier)
            mainApps[group.index] = groupMainApps
        } else {
            mainApps[group.index, default: []].removeAll { $0 == app.bundleIdentifier }
        }

        setMainAppBundleIdentifiersByGroup(mainApps)
        statusMessage = isMain ? "\(app.displayName) is a main app in \(group.title)." : "\(app.displayName) is no longer a main app."
    }

    func setFocusTileWiderResizeMode(_ mode: AutoTileFocusedResizeMode, for app: AutoTileAppSelection) {
        var resizableBundleIdentifiers = focusTileWiderResizableBundleIdentifiers

        switch mode {
        case .resizesWithFocus:
            resizableBundleIdentifiers.insert(app.bundleIdentifier)
        case .keepsSizeOnFocus:
            resizableBundleIdentifiers.remove(app.bundleIdentifier)
        }

        setFocusTileWiderResizableBundleIdentifiers(resizableBundleIdentifiers)
        statusMessage = mode == .resizesWithFocus ?
            "\(app.displayName) will resize when focused." :
            "\(app.displayName) will keep its size when focused."
    }

    func setIgnoresSecondAppInList(_ ignoresSecondAppInList: Bool, in group: AutoTileAppGroup) {
        ignoresSecondAppInListByGroup[group.index] = ignoresSecondAppInList
        ignoresSecondAppInListByGroup = Self.normalizedIgnoresSecondAppInListByGroup(ignoresSecondAppInListByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedIgnoresSecondAppInListByGroup(ignoresSecondAppInListByGroup),
                         forKey: Self.ignoresSecondAppInListByGroupDefaultsKey)
        autoTiler.ignoresSecondAppInListByGroup = ignoresSecondAppInListByGroup
        statusMessage = ignoresSecondAppInList ? "\(group.title) ignores the second app." : "\(group.title) tiles the second app."
    }

    func setIgnoredSecondWindowStartMode(_ startMode: AutoTileIgnoredSecondWindowStartMode, in group: AutoTileAppGroup) {
        ignoredSecondWindowStartModeByGroup[group.index] = startMode
        ignoredSecondWindowStartModeByGroup = Self.normalizedIgnoredSecondWindowStartModeByGroup(ignoredSecondWindowStartModeByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedIgnoredSecondWindowStartModeByGroup(ignoredSecondWindowStartModeByGroup),
                         forKey: Self.ignoredSecondWindowStartModeByGroupDefaultsKey)
        autoTiler.ignoredSecondWindowStartModeByGroup = ignoredSecondWindowStartModeByGroup
        statusMessage = "\(group.title) uses \(startMode.title)."
    }

    func setFillsFirstWindow(_ fillsFirstWindow: Bool, in group: AutoTileAppGroup) {
        fillsFirstWindowByGroup[group.index] = fillsFirstWindow
        fillsFirstWindowByGroup = Self.normalizedFillsFirstWindowByGroup(fillsFirstWindowByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedFillsFirstWindowByGroup(fillsFirstWindowByGroup),
                         forKey: Self.fillsFirstWindowByGroupDefaultsKey)
        autoTiler.fillsFirstWindowByGroup = fillsFirstWindowByGroup
        statusMessage = fillsFirstWindow ? "\(group.title) fills the first browser window." : "\(group.title) starts the first window normally."
    }

    func setScreenLayoutMode(_ screenLayoutMode: AutoTileScreenLayoutMode, in group: AutoTileAppGroup) {
        let selectedScreenLayoutMode = AutoTileScreenLayoutMode.standardCases.contains(screenLayoutMode) ? screenLayoutMode : .halfScreen
        screenLayoutModeByGroup[group.index] = selectedScreenLayoutMode
        screenLayoutModeByGroup = Self.normalizedScreenLayoutModeByGroup(screenLayoutModeByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedScreenLayoutModeByGroup(screenLayoutModeByGroup),
                         forKey: Self.screenLayoutModeByGroupDefaultsKey)
        autoTiler.screenLayoutModeByGroup = screenLayoutModeByGroup
        statusMessage = "\(group.title) uses \(selectedScreenLayoutMode.title) tiling."
    }

    func setMaximumColumnCount(_ maximumColumnCount: Int, in group: AutoTileAppGroup) {
        let normalizedMaximumColumnCount = Self.normalizedMaximumColumnCount(maximumColumnCount)
        maximumColumnCountByGroup[group.index] = normalizedMaximumColumnCount
        maximumColumnCountByGroup = Self.normalizedMaximumColumnCountByGroup(maximumColumnCountByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedMaximumColumnCountByGroup(maximumColumnCountByGroup),
                         forKey: Self.maximumColumnCountByGroupDefaultsKey)
        autoTiler.maximumColumnCountByGroup = maximumColumnCountByGroup
        statusMessage = "\(group.title) uses up to \(normalizedMaximumColumnCount) columns."
    }

    func setTileDirection(_ tileDirection: AutoTileDirection, in group: AutoTileAppGroup) {
        tileDirectionByGroup[group.index] = tileDirection
        tileDirectionByGroup = Self.normalizedTileDirectionByGroup(tileDirectionByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedTileDirectionByGroup(tileDirectionByGroup),
                         forKey: Self.tileDirectionByGroupDefaultsKey)
        autoTiler.tileDirectionByGroup = tileDirectionByGroup
        let directionName: String
        switch tileDirection {
        case .leftToRight:
            directionName = "left"
        case .centerOut:
            directionName = "center"
        case .rightToLeft:
            directionName = "right"
        }
        statusMessage = "\(group.title) tiles from the \(directionName)."
    }

    private func updateAutoTilerState() {
        guard accessibilityGranted,
              isAutoTilingEnabled,
              hasSelectedAutoTileApps else {
            autoTiler.stop()
            return
        }

        if !autoTiler.isRunning {
            autoTiler.start()
        } else {
            autoTiler.reconcileVisibleWindows()
        }
    }

    private var autoTileAppGroupIdentifiersByBundleIdentifier: [String: Set<Int>] {
        autoTileAppGroupIdentifiersByBundleIdentifierCache
    }

    private static func appGroupIdentifiersByBundleIdentifier(for groups: [Int: Set<String>]) -> [String: Set<Int>] {
        groups.reduce(into: [:]) { result, entry in
            let (groupIndex, bundleIdentifiers) = entry

            for bundleIdentifier in bundleIdentifiers {
                result[bundleIdentifier, default: []].insert(groupIndex)
            }
        }
    }

    private func setAutoTileAppBundleIdentifiers(_ identifiers: [String], in groupIndex: Int) {
        var groups = autoTileAppBundleIdentifiersByGroup

        for identifier in identifiers {
            groups[groupIndex, default: []].insert(identifier)
        }

        setAutoTileAppBundleIdentifiersByGroup(groups)
    }

    private func setAutoTileAppBundleIdentifiersByGroup(_ groups: [Int: Set<String>]) {
        autoTileAppBundleIdentifiersByGroup = Self.normalizedAppGroups(groups)
        autoTileAppGroupIdentifiersByBundleIdentifierCache = Self.appGroupIdentifiersByBundleIdentifier(for: autoTileAppBundleIdentifiersByGroup)
        mainAppBundleIdentifiersByGroup = Self.normalizedMainAppBundleIdentifiersByGroup(mainAppBundleIdentifiersByGroup,
                                                                                         appGroups: autoTileAppBundleIdentifiersByGroup)
        screenLayoutModeByGroup = Self.normalizedScreenLayoutModeByGroup(screenLayoutModeByGroup)
        maximumColumnCountByGroup = Self.normalizedMaximumColumnCountByGroup(maximumColumnCountByGroup)
        tileDirectionByGroup = Self.normalizedTileDirectionByGroup(tileDirectionByGroup)
        focusTileWiderResizableBundleIdentifiers = Self.normalizedFocusTileWiderResizableBundleIdentifiers(focusTileWiderResizableBundleIdentifiers,
                                                                                                          appGroups: autoTileAppBundleIdentifiersByGroup)
        focusTileWiderFixedAutoTileAppBundleIdentifiers = Self.focusTileWiderFixedBundleIdentifiers(resizableBundleIdentifiers: focusTileWiderResizableBundleIdentifiers,
                                                                                                    appGroups: autoTileAppBundleIdentifiersByGroup)
        focusGroupIdentifiers = Self.normalizedFocusGroupIdentifiers(focusGroupIdentifiers,
                                                                     appGroups: autoTileAppBundleIdentifiersByGroup)
        focusedGroupNumberByGroup = Self.normalizedFocusedGroupNumberByGroup(focusedGroupNumberByGroup,
                                                                             appGroups: autoTileAppBundleIdentifiersByGroup)
        focusGroupIdentifiers = Self.focusGroupIdentifiers(in: focusedGroupNumberByGroup, number: 1)
        if let activeFocusGroupIdentifier,
           !focusGroupIdentifiers.contains(activeFocusGroupIdentifier) {
            self.activeFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)
        }
        let secondaryFocusGroupIdentifiers = Self.focusGroupIdentifiers(in: focusedGroupNumberByGroup, number: 2)
        if let activeSecondaryFocusGroupIdentifier,
           !secondaryFocusGroupIdentifiers.contains(activeSecondaryFocusGroupIdentifier) {
            self.activeSecondaryFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeSecondaryFocusGroupIdentifierDefaultsKey)
        }
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedAppGroups(autoTileAppBundleIdentifiersByGroup),
                         forKey: Self.autoTileAppGroupsDefaultsKey)
        userDefaults.set(Self.persistedMainAppBundleIdentifiersByGroup(mainAppBundleIdentifiersByGroup),
                         forKey: Self.mainAppBundleIdentifiersByGroupDefaultsKey)
        userDefaults.set(Self.persistedScreenLayoutModeByGroup(screenLayoutModeByGroup),
                         forKey: Self.screenLayoutModeByGroupDefaultsKey)
        userDefaults.set(Self.persistedMaximumColumnCountByGroup(maximumColumnCountByGroup),
                         forKey: Self.maximumColumnCountByGroupDefaultsKey)
        userDefaults.set(Self.persistedTileDirectionByGroup(tileDirectionByGroup),
                         forKey: Self.tileDirectionByGroupDefaultsKey)
        userDefaults.set(Array(focusTileWiderResizableBundleIdentifiers).sorted(),
                         forKey: Self.focusTileWiderResizableBundleIdentifiersDefaultsKey)
        userDefaults.set(focusGroupIdentifiers,
                         forKey: Self.focusGroupIdentifiersDefaultsKey)
        userDefaults.set(Self.persistedFocusedGroupNumberByGroup(focusedGroupNumberByGroup),
                         forKey: Self.focusedGroupNumberByGroupDefaultsKey)
        userDefaults.removeObject(forKey: Self.autoTileAppBundleIdentifiersDefaultsKey)
        autoTiler.appGroupIdentifiersByBundleIdentifier = autoTileAppGroupIdentifiersByBundleIdentifier
        autoTiler.appBundleIdentifiersByGroup = autoTileAppBundleIdentifierOrderByGroup
        autoTiler.mainAppBundleIdentifiersByGroup = mainAppBundleIdentifiersByGroup
        autoTiler.screenLayoutModeByGroup = screenLayoutModeByGroup
        autoTiler.maximumColumnCountByGroup = maximumColumnCountByGroup
        autoTiler.tileDirectionByGroup = tileDirectionByGroup
        autoTiler.focusTileWiderFixedBundleIdentifiers = focusTileWiderFixedAutoTileAppBundleIdentifiers
        updateAutoTilerState()
    }

    private func setMainAppBundleIdentifiersByGroup(_ groups: [Int: [String]]) {
        mainAppBundleIdentifiersByGroup = Self.normalizedMainAppBundleIdentifiersByGroup(groups,
                                                                                        appGroups: autoTileAppBundleIdentifiersByGroup)
        autoTileAppGroups = Self.appGroups(for: autoTileAppBundleIdentifiersByGroup,
                                           mainAppBundleIdentifiersByGroup: mainAppBundleIdentifiersByGroup,
                                           fillsFirstWindowByGroup: fillsFirstWindowByGroup,
                                           screenLayoutModeByGroup: screenLayoutModeByGroup,
                                           maximumColumnCountByGroup: maximumColumnCountByGroup,
                                           tileDirectionByGroup: tileDirectionByGroup,
                                           ignoresSecondAppInListByGroup: ignoresSecondAppInListByGroup,
                                           ignoredSecondWindowStartModeByGroup: ignoredSecondWindowStartModeByGroup)
        userDefaults.set(Self.persistedMainAppBundleIdentifiersByGroup(mainAppBundleIdentifiersByGroup),
                         forKey: Self.mainAppBundleIdentifiersByGroupDefaultsKey)
        autoTiler.mainAppBundleIdentifiersByGroup = mainAppBundleIdentifiersByGroup
    }

    private func setFocusTileWiderResizableBundleIdentifiers(_ identifiers: Set<String>) {
        focusTileWiderResizableBundleIdentifiers = Self.normalizedFocusTileWiderResizableBundleIdentifiers(identifiers,
                                                                                                          appGroups: autoTileAppBundleIdentifiersByGroup)
        focusTileWiderFixedAutoTileAppBundleIdentifiers = Self.focusTileWiderFixedBundleIdentifiers(resizableBundleIdentifiers: focusTileWiderResizableBundleIdentifiers,
                                                                                                    appGroups: autoTileAppBundleIdentifiersByGroup)
        userDefaults.set(Array(focusTileWiderResizableBundleIdentifiers).sorted(),
                         forKey: Self.focusTileWiderResizableBundleIdentifiersDefaultsKey)
        userDefaults.removeObject(forKey: Self.focusTileWiderFixedBundleIdentifiersDefaultsKey)
        userDefaults.removeObject(forKey: Self.existingFirstNewWindowBundleIdentifiersDefaultsKey)
        autoTiler.focusTileWiderFixedBundleIdentifiers = focusTileWiderFixedAutoTileAppBundleIdentifiers
    }

    private func setFocusGroupIdentifiers(_ identifiers: [Int]) {
        var numbers = focusedGroupNumberByGroup.compactMapValues { number in
            number == 1 ? nil : number == 3 ? 2 : number
        }
        for identifier in Self.normalizedFocusGroupIdentifiers(identifiers, appGroups: autoTileAppBundleIdentifiersByGroup) {
            numbers[identifier] = numbers[identifier] == 2 ? 3 : 1
        }
        setFocusedGroupNumberByGroup(numbers)
    }

    private func setFocusedGroupNumberByGroup(_ numbers: [Int: Int]) {
        focusedGroupNumberByGroup = Self.normalizedFocusedGroupNumberByGroup(numbers,
                                                                             appGroups: autoTileAppBundleIdentifiersByGroup)
        focusGroupIdentifiers = Self.focusGroupIdentifiers(in: focusedGroupNumberByGroup, number: 1)
        userDefaults.set(focusGroupIdentifiers,
                         forKey: Self.focusGroupIdentifiersDefaultsKey)
        userDefaults.set(Self.persistedFocusedGroupNumberByGroup(focusedGroupNumberByGroup),
                         forKey: Self.focusedGroupNumberByGroupDefaultsKey)

        if let activeFocusGroupIdentifier,
           !focusGroupIdentifiers.contains(activeFocusGroupIdentifier) {
            self.activeFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)
        }
        let secondaryFocusGroupIdentifiers = Self.focusGroupIdentifiers(in: focusedGroupNumberByGroup, number: 2)
        if let activeSecondaryFocusGroupIdentifier,
           !secondaryFocusGroupIdentifiers.contains(activeSecondaryFocusGroupIdentifier) {
            self.activeSecondaryFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeSecondaryFocusGroupIdentifierDefaultsKey)
        }
    }

    private func hideFocusGroup(_ groupIdentifier: Int, number: Int) {
        let bundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !bundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to hide."
            return
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        let processIdentifiers = mover.applicationProcessIdentifiers(bundleIdentifiers: bundleIdentifiers,
                                                                      hidden: false,
                                                                      runningApplications: runningApplications)

        autoTiler.beginFocusGroupSwitch(settlesGroupIdentifier: nil)
        autoTiler.suppressFocusGroupSwitchHideNotifications(for: processIdentifiers)
        let hiddenApplicationCount = mover.setApplications(processIdentifiers, hidden: true)
        setActiveFocusGroupIdentifier(nil, number: number)
        markFocusGroupTransition(number: number)

        statusMessage = hiddenApplicationCount > 0 ?
            "Hid Group \(groupIdentifier + 1)." :
            "Group \(groupIdentifier + 1) is already hidden."
    }

    private func activateFocusGroup(_ groupIdentifier: Int, number: Int) {
        guard focusGroupNumber(for: groupIdentifier) != nil else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !targetBundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to reveal."
            return
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        guard runningApplications.contains(where: { application in
            application.activationPolicy == .regular &&
                application.bundleIdentifier.map(targetBundleIdentifiers.contains) == true
        }) else {
            statusMessage = "Group \(groupIdentifier + 1) has no running apps."
            return
        }

        let preferredActivationBundleIdentifiers = preferredActivationBundleIdentifiers(for: groupIdentifier)
        let outsideBundleIdentifiers = bundleIdentifiersOutsideFocusGroup(
            groupIdentifier,
            runningApplications: runningApplications
        )
        let targetProcessIdentifiers = mover.applicationProcessIdentifiers(bundleIdentifiers: targetBundleIdentifiers,
                                                                            hidden: true,
                                                                            runningApplications: runningApplications)
        let outsideProcessIdentifiers = focusGroupSwitchingHidesOthers ?
            mover.applicationProcessIdentifiers(bundleIdentifiers: outsideBundleIdentifiers,
                                                hidden: false,
                                                runningApplications: runningApplications) :
            []

        autoTiler.beginFocusGroupSwitch(settlesGroupIdentifier: groupIdentifier)
        autoTiler.suppressFocusGroupSwitchUnhideNotifications(for: targetProcessIdentifiers)
        autoTiler.suppressFocusGroupSwitchHideNotifications(for: outsideProcessIdentifiers)

        let unhiddenApplicationCount = mover.setApplications(targetProcessIdentifiers, hidden: false)
        let didActivateApplication = mover.activateApplication(
            bundleIdentifiers: targetBundleIdentifiers,
            preferredBundleIdentifiers: preferredActivationBundleIdentifiers,
            runningApplications: runningApplications
        )
        let hiddenApplicationCount = mover.setApplications(outsideProcessIdentifiers, hidden: true)
        autoTiler.scheduleFocusGroupRetiles(groupIdentifier)

        setActiveFocusGroupIdentifier(groupIdentifier, number: number)
        markFocusGroupTransition(number: number)

        if unhiddenApplicationCount > 0 || didActivateApplication, hiddenApplicationCount > 0 {
            statusMessage = "Switched to Group \(groupIdentifier + 1)."
        } else if unhiddenApplicationCount > 0 || didActivateApplication {
            statusMessage = "Revealed Group \(groupIdentifier + 1)."
        } else {
            statusMessage = "Group \(groupIdentifier + 1) is already visible."
        }
    }

    private func revealFocusGroup(_ groupIdentifier: Int, number: Int) {
        guard focusGroupNumber(for: groupIdentifier) != nil else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !targetBundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to reveal."
            return
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        guard runningApplications.contains(where: { application in
            application.activationPolicy == .regular &&
                application.bundleIdentifier.map(targetBundleIdentifiers.contains) == true
        }) else {
            statusMessage = "Group \(groupIdentifier + 1) has no running apps."
            return
        }

        let preferredActivationBundleIdentifiers = preferredActivationBundleIdentifiers(for: groupIdentifier)
        let targetProcessIdentifiers = mover.applicationProcessIdentifiers(bundleIdentifiers: targetBundleIdentifiers,
                                                                            hidden: true,
                                                                            runningApplications: runningApplications)
        autoTiler.beginFocusGroupSwitch(settlesGroupIdentifier: groupIdentifier)
        autoTiler.suppressFocusGroupSwitchUnhideNotifications(for: targetProcessIdentifiers)
        let unhiddenApplicationCount = mover.setApplications(targetProcessIdentifiers, hidden: false)
        let didActivateApplication = mover.activateApplication(
            bundleIdentifiers: targetBundleIdentifiers,
            preferredBundleIdentifiers: preferredActivationBundleIdentifiers,
            runningApplications: runningApplications
        )
        autoTiler.scheduleFocusGroupRetiles(groupIdentifier)

        setActiveFocusGroupIdentifier(groupIdentifier, number: number)
        markFocusGroupTransition(number: number)

        statusMessage = unhiddenApplicationCount > 0 || didActivateApplication ?
            "Revealed Group \(groupIdentifier + 1)." :
            "Group \(groupIdentifier + 1) is already visible."
    }

    private func focusGroupTransitionIsInFlight(number: Int) -> Bool {
        guard let deadline = focusGroupTransitionDeadlineByNumber[number] else {
            return false
        }

        guard deadline > Date() else {
            focusGroupTransitionDeadlineByNumber.removeValue(forKey: number)
            return false
        }

        return true
    }

    private func markFocusGroupTransition(number: Int) {
        focusGroupTransitionDeadlineByNumber[number] = Date().addingTimeInterval(0.5)
    }

    private func runningConfiguredFocusGroupIdentifiers(number: Int) -> [Int] {
        let runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap { application -> String? in
            guard application.activationPolicy == .regular else {
                return nil
            }

            return application.bundleIdentifier
        })

        return focusGroupIdentifiers(number: number).filter { groupIdentifier in
            let bundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
            return !bundleIdentifiers.isDisjoint(with: runningBundleIdentifiers)
        }
    }

    private func focusGroupIdentifiers(number: Int) -> [Int] {
        Self.focusGroupIdentifiers(in: focusedGroupNumberByGroup, number: number)
    }

    private func focusGroupNumber(for groupIdentifier: Int) -> Int? {
        focusedGroupNumberByGroup[groupIdentifier]
    }

    private func activeFocusGroupIdentifier(number: Int) -> Int? {
        number == 2 ? activeSecondaryFocusGroupIdentifier : activeFocusGroupIdentifier
    }

    private func setActiveFocusGroupIdentifier(_ groupIdentifier: Int?, number: Int) {
        let key = number == 2 ?
            Self.activeSecondaryFocusGroupIdentifierDefaultsKey :
            Self.activeFocusGroupIdentifierDefaultsKey

        if number == 2 {
            activeSecondaryFocusGroupIdentifier = groupIdentifier
        } else {
            activeFocusGroupIdentifier = groupIdentifier
        }

        if let groupIdentifier {
            userDefaults.set(groupIdentifier, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func frontmostFocusGroupIdentifier(number: Int) -> Int? {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let groupIdentifiers = autoTileAppGroupIdentifiersByBundleIdentifier[bundleIdentifier] else {
            return nil
        }

        return focusGroupIdentifiers(number: number).first {
            groupIdentifiers.contains($0)
        }
    }

    private func preferredActivationBundleIdentifiers(for groupIdentifier: Int) -> [String] {
        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        let preferredBundleIdentifiers = (mainAppBundleIdentifiersByGroup[groupIdentifier] ?? []) +
            (autoTileAppBundleIdentifierOrderByGroup[groupIdentifier] ?? [])
        var seenBundleIdentifiers: Set<String> = []

        return preferredBundleIdentifiers.filter { bundleIdentifier in
            targetBundleIdentifiers.contains(bundleIdentifier) &&
                seenBundleIdentifiers.insert(bundleIdentifier).inserted
        }
    }

    private func bundleIdentifiersOutsideFocusGroup(
        _ groupIdentifier: Int,
        runningApplications: [NSRunningApplication]
    ) -> Set<String> {
        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        return Set(runningApplications.compactMap { application -> String? in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownBundleIdentifier,
                  !targetBundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }

            return bundleIdentifier
        })
    }

    private static func appGroups(for groups: [Int: Set<String>],
                                  mainAppBundleIdentifiersByGroup: [Int: [String]],
                                  fillsFirstWindowByGroup: [Int: Bool],
                                  screenLayoutModeByGroup: [Int: AutoTileScreenLayoutMode],
                                  maximumColumnCountByGroup: [Int: Int],
                                  tileDirectionByGroup: [Int: AutoTileDirection],
                                  ignoresSecondAppInListByGroup: [Int: Bool],
                                  ignoredSecondWindowStartModeByGroup: [Int: AutoTileIgnoredSecondWindowStartMode]) -> [AutoTileAppGroup] {
        (0..<autoTileGroupCount).map { groupIndex in
            AutoTileAppGroup(index: groupIndex,
                             apps: appSelections(for: groups[groupIndex] ?? []),
                             mainAppBundleIdentifiers: mainAppBundleIdentifiersByGroup[groupIndex] ?? [],
                             screenLayoutMode: screenLayoutModeByGroup[groupIndex] ?? .halfScreen,
                             maximumColumnCount: maximumColumnCountByGroup[groupIndex] ?? defaultMaximumColumnCount,
                             tileDirection: tileDirectionByGroup[groupIndex] ?? .leftToRight,
                             fillsFirstWindow: fillsFirstWindowByGroup[groupIndex] ?? false,
                             ignoresSecondAppInList: ignoresSecondAppInListByGroup[groupIndex] ?? true,
                             ignoredSecondWindowStartMode: ignoredSecondWindowStartModeByGroup[groupIndex] ?? .normalStart)
        }
    }

    private static func appSelections(for bundleIdentifiers: Set<String>) -> [AutoTileAppSelection] {
        bundleIdentifiers
            .map(AutoTileAppSelection.resolved(bundleIdentifier:))
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)

                if comparison == .orderedSame {
                    return $0.bundleIdentifier < $1.bundleIdentifier
                }

                return comparison == .orderedAscending
            }
    }

    private var autoTileAppBundleIdentifierOrderByGroup: [Int: [String]] {
        Dictionary(uniqueKeysWithValues: (0..<Self.autoTileGroupCount).map { groupIndex in
            let identifiers = Self.appSelections(for: autoTileAppBundleIdentifiersByGroup[groupIndex] ?? [])
                .map(\.bundleIdentifier)

            return (groupIndex, identifiers)
        })
    }

    private var selectedAutoTileApps: [AutoTileAppSelection] {
        Self.appSelections(for: Set(autoTileAppBundleIdentifiersByGroup.values.flatMap { $0 }))
    }

    private static func storedAppGroups(in userDefaults: UserDefaults) -> [Int: Set<String>] {
        if let storedGroups = userDefaults.dictionary(forKey: autoTileAppGroupsDefaultsKey) as? [String: [String]] {
            return normalizedAppGroups(Dictionary(uniqueKeysWithValues: storedGroups.compactMap { key, identifiers in
                guard let groupIndex = Int(key) else {
                    return nil
                }

                return (groupIndex, Set(identifiers))
            }))
        }

        let legacyIdentifiers = Set(userDefaults.stringArray(forKey: autoTileAppBundleIdentifiersDefaultsKey) ?? [])
        guard !legacyIdentifiers.isEmpty else {
            return normalizedAppGroups([:])
        }

        return normalizedAppGroups([0: legacyIdentifiers])
    }

    private static func storedMainAppBundleIdentifiersByGroup(in userDefaults: UserDefaults,
                                                              appGroups: [Int: Set<String>]) -> [Int: [String]] {
        guard let storedGroups = userDefaults.dictionary(forKey: mainAppBundleIdentifiersByGroupDefaultsKey) as? [String: [String]] else {
            return normalizedMainAppBundleIdentifiersByGroup([:], appGroups: appGroups)
        }

        return normalizedMainAppBundleIdentifiersByGroup(Dictionary(uniqueKeysWithValues: storedGroups.compactMap { key, identifiers in
            guard let groupIndex = Int(key) else {
                return nil
            }

            return (groupIndex, identifiers)
        }), appGroups: appGroups)
    }

    private static func storedFocusTileWiderResizableBundleIdentifiers(in userDefaults: UserDefaults,
                                                                       appGroups: [Int: Set<String>]) -> Set<String> {
        if userDefaults.object(forKey: focusTileWiderResizableBundleIdentifiersDefaultsKey) != nil {
            let identifiers = Set(userDefaults.stringArray(forKey: focusTileWiderResizableBundleIdentifiersDefaultsKey) ?? [])
            return normalizedFocusTileWiderResizableBundleIdentifiers(identifiers, appGroups: appGroups)
        }

        return []
    }

    private static func storedFocusGroupIdentifiers(in userDefaults: UserDefaults,
                                                    appGroups: [Int: Set<String>]) -> [Int] {
        normalizedFocusGroupIdentifiers(userDefaults.array(forKey: focusGroupIdentifiersDefaultsKey) as? [Int] ?? [],
                                        appGroups: appGroups)
    }

    private static func storedFocusedGroupNumberByGroup(in userDefaults: UserDefaults,
                                                        appGroups: [Int: Set<String>],
                                                        legacyFocusGroupIdentifiers: [Int]) -> [Int: Int] {
        if let storedSettings = userDefaults.dictionary(forKey: focusedGroupNumberByGroupDefaultsKey) as? [String: Int] {
            return normalizedFocusedGroupNumberByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, value in
                guard let groupIndex = Int(key) else {
                    return nil
                }

                return (groupIndex, value)
            }), appGroups: appGroups)
        }

        return normalizedFocusedGroupNumberByGroup(Dictionary(uniqueKeysWithValues: legacyFocusGroupIdentifiers.map {
            ($0, 1)
        }), appGroups: appGroups)
    }

    private static func storedActiveFocusGroupIdentifier(in userDefaults: UserDefaults,
                                                        focusGroupIdentifiers: [Int]) -> Int? {
        storedActiveFocusGroupIdentifier(in: userDefaults,
                                         key: activeFocusGroupIdentifierDefaultsKey,
                                         focusGroupIdentifiers: focusGroupIdentifiers)
    }

    private static func storedActiveFocusGroupIdentifier(in userDefaults: UserDefaults,
                                                        key: String,
                                                        focusGroupIdentifiers: [Int]) -> Int? {
        guard userDefaults.object(forKey: key) != nil else {
            return nil
        }

        let groupIdentifier = userDefaults.integer(forKey: key)
        return focusGroupIdentifiers.contains(groupIdentifier) ? groupIdentifier : nil
    }

    private static func normalizedAppGroups(_ groups: [Int: Set<String>]) -> [Int: Set<String>] {
        var normalizedGroups: [Int: Set<String>] = [:]

        for groupIndex in 0..<autoTileGroupCount {
            normalizedGroups[groupIndex] = groups[groupIndex] ?? []
        }

        return normalizedGroups
    }

    private static func normalizedMainAppBundleIdentifiersByGroup(_ groups: [Int: [String]],
                                                                  appGroups: [Int: Set<String>]) -> [Int: [String]] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            var seenBundleIdentifiers: Set<String> = []
            let allowedBundleIdentifiers = appGroups[groupIndex] ?? []
            let identifiers = (groups[groupIndex] ?? []).filter { identifier in
                allowedBundleIdentifiers.contains(identifier) &&
                    seenBundleIdentifiers.insert(identifier).inserted
            }

            return (groupIndex, identifiers)
        })
    }

    private static func normalizedFocusTileWiderResizableBundleIdentifiers(_ identifiers: Set<String>,
                                                                          appGroups: [Int: Set<String>]) -> Set<String> {
        identifiers.intersection(Set(appGroups.values.flatMap { $0 }))
    }

    private static func focusTileWiderFixedBundleIdentifiers(resizableBundleIdentifiers: Set<String>,
                                                            appGroups: [Int: Set<String>]) -> Set<String> {
        Set(appGroups.values.flatMap { $0 }).subtracting(resizableBundleIdentifiers)
    }

    private static func normalizedFocusGroupIdentifiers(_ identifiers: [Int],
                                                       appGroups: [Int: Set<String>]) -> [Int] {
        var seenIdentifiers: Set<Int> = []

        return identifiers.filter { groupIdentifier in
            groupIdentifier >= 0 &&
                groupIdentifier < autoTileGroupCount &&
                !(appGroups[groupIdentifier] ?? []).isEmpty &&
                seenIdentifiers.insert(groupIdentifier).inserted
        }
    }

    private static func normalizedFocusedGroupNumberByGroup(_ settings: [Int: Int],
                                                            appGroups: [Int: Set<String>]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: settings.compactMap { groupIdentifier, number in
            guard groupIdentifier >= 0,
                  groupIdentifier < autoTileGroupCount,
                  number == 1 || number == 2 || number == 3,
                  !(appGroups[groupIdentifier] ?? []).isEmpty else {
                return nil
            }

            return (groupIdentifier, number)
        })
    }

    private static func focusGroupIdentifiers(in settings: [Int: Int], number: Int) -> [Int] {
        settings
            .filter { $0.value == number || $0.value == 3 }
            .map(\.key)
            .sorted()
    }

    private static func storedFillsFirstWindowByGroup(in userDefaults: UserDefaults) -> [Int: Bool] {
        guard let storedSettings = userDefaults.dictionary(forKey: fillsFirstWindowByGroupDefaultsKey) as? [String: Bool] else {
            return normalizedFillsFirstWindowByGroup([:])
        }

        return normalizedFillsFirstWindowByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, value in
            guard let groupIndex = Int(key) else {
                return nil
            }

            return (groupIndex, value)
        }))
    }

    private static func normalizedFillsFirstWindowByGroup(_ settings: [Int: Bool]) -> [Int: Bool] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (groupIndex, settings[groupIndex] ?? false)
        })
    }

    private static func storedScreenLayoutModeByGroup(in userDefaults: UserDefaults) -> [Int: AutoTileScreenLayoutMode] {
        guard let storedSettings = userDefaults.dictionary(forKey: screenLayoutModeByGroupDefaultsKey) as? [String: String] else {
            return normalizedScreenLayoutModeByGroup([:])
        }

        return normalizedScreenLayoutModeByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, rawValue in
            guard let groupIndex = Int(key),
                  let screenLayoutMode = AutoTileScreenLayoutMode(rawValue: rawValue) else {
                return nil
            }

            return (groupIndex, screenLayoutMode)
        }))
    }

    private static func normalizedScreenLayoutModeByGroup(_ settings: [Int: AutoTileScreenLayoutMode]) -> [Int: AutoTileScreenLayoutMode] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            let mode = settings[groupIndex] ?? .halfScreen

            return (groupIndex, mode)
        })
    }

    private static func storedMaximumColumnCountByGroup(in userDefaults: UserDefaults) -> [Int: Int] {
        guard let storedSettings = userDefaults.dictionary(forKey: maximumColumnCountByGroupDefaultsKey) as? [String: Int] else {
            return normalizedMaximumColumnCountByGroup([:])
        }

        return normalizedMaximumColumnCountByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, value in
            guard let groupIndex = Int(key) else {
                return nil
            }

            return (groupIndex, value)
        }))
    }

    private static func normalizedMaximumColumnCountByGroup(_ settings: [Int: Int]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (groupIndex, normalizedMaximumColumnCount(settings[groupIndex] ?? defaultMaximumColumnCount))
        })
    }

    private static func normalizedMaximumColumnCount(_ maximumColumnCount: Int) -> Int {
        min(max(maximumColumnCount, maximumColumnCountRange.lowerBound),
            maximumColumnCountRange.upperBound)
    }

    private static func storedTileDirectionByGroup(in userDefaults: UserDefaults) -> [Int: AutoTileDirection] {
        guard let storedSettings = userDefaults.dictionary(forKey: tileDirectionByGroupDefaultsKey) as? [String: String] else {
            return normalizedTileDirectionByGroup([:])
        }

        return normalizedTileDirectionByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, rawValue in
            guard let groupIndex = Int(key),
                  let tileDirection = AutoTileDirection(rawValue: rawValue) else {
                return nil
            }

            return (groupIndex, tileDirection)
        }))
    }

    private static func normalizedTileDirectionByGroup(_ settings: [Int: AutoTileDirection]) -> [Int: AutoTileDirection] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (groupIndex, settings[groupIndex] ?? .leftToRight)
        })
    }

    private static func persistedTileDirectionByGroup(_ settings: [Int: AutoTileDirection]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: settings.map { groupIndex, tileDirection in
            (String(groupIndex), tileDirection.rawValue)
        })
    }

    private static func storedIgnoresSecondAppInListByGroup(in userDefaults: UserDefaults) -> [Int: Bool] {
        if let storedSettings = userDefaults.dictionary(forKey: ignoresSecondAppInListByGroupDefaultsKey) as? [String: Bool] {
            return normalizedIgnoresSecondAppInListByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, value in
                guard let groupIndex = Int(key) else {
                    return nil
                }

                return (groupIndex, value)
            }))
        }

        let legacyValue = userDefaults.object(forKey: ignoresSecondAppInListDefaultsKey) as? Bool ?? true
        return normalizedIgnoresSecondAppInListByGroup(Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map {
            ($0, legacyValue)
        }))
    }

    private static func normalizedIgnoresSecondAppInListByGroup(_ settings: [Int: Bool]) -> [Int: Bool] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (groupIndex, settings[groupIndex] ?? true)
        })
    }

    private static func storedIgnoredSecondWindowStartModeByGroup(in userDefaults: UserDefaults) -> [Int: AutoTileIgnoredSecondWindowStartMode] {
        guard let storedSettings = userDefaults.dictionary(forKey: ignoredSecondWindowStartModeByGroupDefaultsKey) as? [String: String] else {
            return normalizedIgnoredSecondWindowStartModeByGroup([:])
        }

        return normalizedIgnoredSecondWindowStartModeByGroup(Dictionary(uniqueKeysWithValues: storedSettings.compactMap { key, rawValue in
            guard let groupIndex = Int(key),
                  let startMode = AutoTileIgnoredSecondWindowStartMode(rawValue: rawValue) else {
                return nil
            }

            return (groupIndex, startMode)
        }))
    }

    private static func normalizedIgnoredSecondWindowStartModeByGroup(_ settings: [Int: AutoTileIgnoredSecondWindowStartMode]) -> [Int: AutoTileIgnoredSecondWindowStartMode] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (groupIndex, settings[groupIndex] ?? .normalStart)
        })
    }

    private static func normalizedFocusedAutoTileWindowWidthFraction(_ widthFraction: Double) -> Double {
        min(max(widthFraction, focusedAutoTileWindowWidthFractionRange.lowerBound),
            focusedAutoTileWindowWidthFractionRange.upperBound)
    }

    private static func focusedAutoTileWindowWidthText(for widthFraction: Double) -> String {
        "\(Int((widthFraction * 100).rounded()))%"
    }

    private static func normalizedFocusGroupSwitchDelay(_ delay: Double) -> Double {
        min(max(delay, focusGroupSwitchDelayRange.lowerBound),
            focusGroupSwitchDelayRange.upperBound)
    }

    private static func focusGroupSwitchDelayText(for delay: Double) -> String {
        delay == 0 ? "None" : "\(Int((delay * 1_000).rounded())) ms"
    }

    private static func storedShortcut(in userDefaults: UserDefaults,
                                       key: String,
                                       defaultShortcut: DockMoverShortcut) -> DockMoverShortcut {
        guard let data = userDefaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(DockMoverShortcut.self, from: data) else {
            return defaultShortcut
        }

        return shortcut
    }

    private func persistShortcut(_ shortcut: DockMoverShortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            userDefaults.set(data, forKey: key)
        }
    }

    private static func storedPhysicalKey(in userDefaults: UserDefaults,
                                          key: String,
                                          defaultKey: FocusGroupPhysicalKey) -> FocusGroupPhysicalKey {
        guard let storedValue = userDefaults.object(forKey: key) as? NSNumber,
              let keyCode = UInt16(exactly: storedValue.intValue),
              let physicalKey = FocusGroupPhysicalKey(keyCode: keyCode) else {
            return defaultKey
        }

        return physicalKey
    }

    private func persistPhysicalKey(_ physicalKey: FocusGroupPhysicalKey,
                                    key: String) {
        userDefaults.set(Int(physicalKey.keyCode), forKey: key)
    }

    private static func persistedAppGroups(_ groups: [Int: Set<String>]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), Array(groups[groupIndex] ?? []).sorted())
        })
    }

    private static func persistedFocusedGroupNumberByGroup(_ settings: [Int: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: settings.map { groupIndex, number in
            (String(groupIndex), number)
        })
    }

    private static func persistedMainAppBundleIdentifiersByGroup(_ groups: [Int: [String]]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), groups[groupIndex] ?? [])
        })
    }

    private static func persistedIgnoresSecondAppInListByGroup(_ settings: [Int: Bool]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), settings[groupIndex] ?? true)
        })
    }

    private static func persistedFillsFirstWindowByGroup(_ settings: [Int: Bool]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), settings[groupIndex] ?? false)
        })
    }

    private static func persistedScreenLayoutModeByGroup(_ settings: [Int: AutoTileScreenLayoutMode]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), (settings[groupIndex] ?? .halfScreen).rawValue)
        })
    }

    private static func persistedMaximumColumnCountByGroup(_ settings: [Int: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), normalizedMaximumColumnCount(settings[groupIndex] ?? defaultMaximumColumnCount))
        })
    }

    private static func persistedIgnoredSecondWindowStartModeByGroup(_ settings: [Int: AutoTileIgnoredSecondWindowStartMode]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), (settings[groupIndex] ?? .normalStart).rawValue)
        })
    }

}
