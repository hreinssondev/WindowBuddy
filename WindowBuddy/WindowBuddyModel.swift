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

    @Published var showsDockIcon: Bool {
        didSet {
            userDefaults.set(showsDockIcon, forKey: Self.showsDockIconDefaultsKey)
            applyActivationPolicy()
            statusMessage = showsDockIcon ? "Dock icon is visible." : "WindowBuddy is menu bar only."
        }
    }

    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var statusMessage = "Waiting for Accessibility permission."
    @Published private(set) var autoTileAppGroups: [AutoTileAppGroup] = []
    @Published private(set) var focusTileWiderFixedAutoTileAppBundleIdentifiers: Set<String> = []
    @Published private(set) var focusGroupIdentifiers: [Int] = []
    @Published private(set) var activeFocusGroupIdentifier: Int?
    @Published private(set) var availableAutoTileApps: [AutoTileAppSelection] = []
    @Published private(set) var isLoadingAvailableAutoTileApps = false

    private static let autoTilingEnabledDefaultsKey = "autoTilingEnabled"
    private static let instantWindowMovementDefaultsKey = "instantWindowMovement"
    private static let focusTileWiderFixedBundleIdentifiersDefaultsKey = "focusTileWiderFixedBundleIdentifiers"
    private static let focusTileWiderResizableBundleIdentifiersDefaultsKey = "focusTileWiderResizableBundleIdentifiers"
    private static let focusGroupIdentifiersDefaultsKey = "focusGroupIdentifiers"
    private static let activeFocusGroupIdentifierDefaultsKey = "activeFocusGroupIdentifier"
    private static let existingFirstNewWindowBundleIdentifiersDefaultsKey = "existingFirstNewWindowBundleIdentifiers"
    private static let widensFocusedAutoTileWindowDefaultsKey = "widensFocusedAutoTileWindow"
    private static let focusedAutoTileWindowWidthFractionDefaultsKey = "focusedAutoTileWindowWidthFraction"
    private static let movesExistingAutoTileAppWindowsToFocusedGroupDefaultsKey = "movesExistingAutoTileAppWindowsToFocusedGroup"
    private static let revealsActiveAutoTileGroupAppsDefaultsKey = "revealsActiveAutoTileGroupApps"
    private static let focusGroupSwitchingHidesOthersDefaultsKey = "focusGroupSwitchingHidesOthers"
    private static let showsDockIconDefaultsKey = "showsDockIcon"
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
        focusGroupIdentifiers = storedFocusGroupIdentifiers
        activeFocusGroupIdentifier = Self.storedActiveFocusGroupIdentifier(in: userDefaults,
                                                                           focusGroupIdentifiers: storedFocusGroupIdentifiers)

        if userDefaults.object(forKey: Self.instantWindowMovementDefaultsKey) == nil {
            usesInstantWindowMovement = true
        } else {
            usesInstantWindowMovement = userDefaults.bool(forKey: Self.instantWindowMovementDefaultsKey)
        }

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

        if userDefaults.object(forKey: Self.showsDockIconDefaultsKey) == nil {
            showsDockIcon = true
        } else {
            showsDockIcon = userDefaults.bool(forKey: Self.showsDockIconDefaultsKey)
        }

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

        updateAutoTilerState()
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }

    func stop() {
        autoTiler.stop()
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

    func setFocusGroup(_ isFocusGroup: Bool, in group: AutoTileAppGroup) {
        guard !group.apps.isEmpty else {
            statusMessage = "\(group.title) needs apps before it can be a focus group."
            return
        }

        var identifiers = focusGroupIdentifiers.filter { $0 != group.index }

        if isFocusGroup {
            identifiers.append(group.index)
        } else if activeFocusGroupIdentifier == group.index {
            activeFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)
        }

        setFocusGroupIdentifiers(identifiers)
        statusMessage = isFocusGroup ? "\(group.title) is a focus group." : "\(group.title) is not a focus group."
    }

    func toggleFocusGroups() {
        guard !focusGroupIdentifiers.isEmpty else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let runningFocusGroupIdentifiers = runningConfiguredFocusGroupIdentifiers()
        guard !runningFocusGroupIdentifiers.isEmpty else {
            statusMessage = "No focus group apps are running."
            return
        }

        let frontmostGroupIdentifier = frontmostFocusGroupIdentifier()
        let currentGroupIdentifier = frontmostGroupIdentifier ?? activeFocusGroupIdentifier
        let targetGroupIdentifier: Int
        if runningFocusGroupIdentifiers.count == 1 {
            let groupIdentifier = runningFocusGroupIdentifiers[0]
            if currentGroupIdentifier == groupIdentifier {
                hideFocusGroup(groupIdentifier)
                return
            }

            revealFocusGroup(groupIdentifier)
            return
        } else {
            let activeIndex = currentGroupIdentifier.flatMap { runningFocusGroupIdentifiers.firstIndex(of: $0) }
            let nextIndex = activeIndex.map { ($0 + 1) % runningFocusGroupIdentifiers.count } ?? 0
            targetGroupIdentifier = runningFocusGroupIdentifiers[nextIndex]
        }

        activateFocusGroup(targetGroupIdentifier)
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
        if let activeFocusGroupIdentifier,
           !focusGroupIdentifiers.contains(activeFocusGroupIdentifier) {
            self.activeFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)
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
        focusGroupIdentifiers = Self.normalizedFocusGroupIdentifiers(identifiers,
                                                                    appGroups: autoTileAppBundleIdentifiersByGroup)
        userDefaults.set(focusGroupIdentifiers,
                         forKey: Self.focusGroupIdentifiersDefaultsKey)

        if let activeFocusGroupIdentifier,
           !focusGroupIdentifiers.contains(activeFocusGroupIdentifier) {
            self.activeFocusGroupIdentifier = nil
            userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)
        }
    }

    private func hideFocusGroup(_ groupIdentifier: Int) {
        let bundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !bundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to hide."
            return
        }

        autoTiler.suppressFocusGroupSwitchHideNotifications(for: bundleIdentifiers)
        let hiddenApplicationCount = mover.hideApplications(bundleIdentifiers: bundleIdentifiers).count
        activeFocusGroupIdentifier = nil
        userDefaults.removeObject(forKey: Self.activeFocusGroupIdentifierDefaultsKey)

        statusMessage = hiddenApplicationCount > 0 ?
            "Hid Group \(groupIdentifier + 1)." :
            "Group \(groupIdentifier + 1) is already hidden."
    }

    private func activateFocusGroup(_ groupIdentifier: Int) {
        guard focusGroupIdentifiers.contains(groupIdentifier) else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !targetBundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to reveal."
            return
        }

        guard focusGroupIsRunning(groupIdentifier) else {
            statusMessage = "Group \(groupIdentifier + 1) has no running apps."
            return
        }

        let preferredActivationBundleIdentifiers = preferredActivationBundleIdentifiers(for: groupIdentifier)
        let activatedApplicationCount = mover.revealApplications(
            bundleIdentifiers: targetBundleIdentifiers,
            preferredActivationBundleIdentifiers: preferredActivationBundleIdentifiers
        )
        let outsideBundleIdentifiers = bundleIdentifiersOutsideFocusGroup(groupIdentifier)
        if focusGroupSwitchingHidesOthers {
            autoTiler.suppressFocusGroupSwitchHideNotifications(for: outsideBundleIdentifiers)
        }
        let hiddenApplicationCount = focusGroupSwitchingHidesOthers ?
            mover.hideApplications(bundleIdentifiers: outsideBundleIdentifiers).count :
            0
        let revealedApplicationCount = retileFocusGroup(groupIdentifier)

        activeFocusGroupIdentifier = groupIdentifier
        userDefaults.set(groupIdentifier,
                         forKey: Self.activeFocusGroupIdentifierDefaultsKey)

        if revealedApplicationCount > 0 || activatedApplicationCount > 0, hiddenApplicationCount > 0 {
            statusMessage = "Switched to Group \(groupIdentifier + 1)."
        } else if revealedApplicationCount > 0 || activatedApplicationCount > 0 {
            statusMessage = "Revealed Group \(groupIdentifier + 1)."
        } else {
            statusMessage = "Group \(groupIdentifier + 1) is already visible."
        }
    }

    private func revealFocusGroup(_ groupIdentifier: Int) {
        guard focusGroupIdentifiers.contains(groupIdentifier) else {
            statusMessage = "Choose focus groups before switching."
            return
        }

        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !targetBundleIdentifiers.isEmpty else {
            statusMessage = "Group \(groupIdentifier + 1) has no apps to reveal."
            return
        }

        guard focusGroupIsRunning(groupIdentifier) else {
            statusMessage = "Group \(groupIdentifier + 1) has no running apps."
            return
        }

        let preferredActivationBundleIdentifiers = preferredActivationBundleIdentifiers(for: groupIdentifier)
        let revealedApplicationCount = revealAndTileFocusGroup(groupIdentifier,
                                                               bundleIdentifiers: targetBundleIdentifiers,
                                                               preferredActivationBundleIdentifiers: preferredActivationBundleIdentifiers)
        let activatedApplicationCount = mover.revealApplications(
            bundleIdentifiers: targetBundleIdentifiers,
            preferredActivationBundleIdentifiers: preferredActivationBundleIdentifiers
        )

        activeFocusGroupIdentifier = groupIdentifier
        userDefaults.set(groupIdentifier,
                         forKey: Self.activeFocusGroupIdentifierDefaultsKey)

        statusMessage = revealedApplicationCount > 0 || activatedApplicationCount > 0 ?
            "Revealed Group \(groupIdentifier + 1)." :
            "Group \(groupIdentifier + 1) is already visible."
    }

    private func revealAndTileFocusGroup(_ groupIdentifier: Int,
                                         bundleIdentifiers: Set<String>,
                                         preferredActivationBundleIdentifiers: [String]) -> Int {
        let revealedApplicationCount = mover.revealApplications(
            bundleIdentifiers: bundleIdentifiers,
            preferredActivationBundleIdentifiers: preferredActivationBundleIdentifiers,
            activates: false
        )

        _ = retileFocusGroup(groupIdentifier)

        return revealedApplicationCount
    }

    private func retileFocusGroup(_ groupIdentifier: Int) -> Int {
        do {
            let result = try autoTiler.retileVisibleGroup(groupIdentifier)
            autoTiler.scheduleFocusGroupRetiles(groupIdentifier)
            return result.tiledWindowCount
        } catch {
            if isAutoTilingEnabled {
                statusMessage = error.localizedDescription
            }
            return 0
        }
    }

    private func runningConfiguredFocusGroupIdentifiers() -> [Int] {
        focusGroupIdentifiers.filter(focusGroupIsRunning)
    }

    private func frontmostFocusGroupIdentifier() -> Int? {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let groupIdentifiers = autoTileAppGroupIdentifiersByBundleIdentifier[bundleIdentifier] else {
            return nil
        }

        return focusGroupIdentifiers.first { groupIdentifiers.contains($0) }
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

    private func bundleIdentifiersOutsideFocusGroup(_ groupIdentifier: Int) -> Set<String> {
        let targetBundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        return Set(NSWorkspace.shared.runningApplications.compactMap { application -> String? in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownBundleIdentifier,
                  !targetBundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }

            return bundleIdentifier
        })
    }

    private func focusGroupIsRunning(_ groupIdentifier: Int) -> Bool {
        let bundleIdentifiers = autoTileAppBundleIdentifiersByGroup[groupIdentifier] ?? []
        guard !bundleIdentifiers.isEmpty else {
            return false
        }

        let runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap { application -> String? in
            guard application.activationPolicy == .regular else {
                return nil
            }

            return application.bundleIdentifier
        })
        return !bundleIdentifiers.isDisjoint(with: runningBundleIdentifiers)
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

    private static func storedActiveFocusGroupIdentifier(in userDefaults: UserDefaults,
                                                        focusGroupIdentifiers: [Int]) -> Int? {
        guard userDefaults.object(forKey: activeFocusGroupIdentifierDefaultsKey) != nil else {
            return nil
        }

        let groupIdentifier = userDefaults.integer(forKey: activeFocusGroupIdentifierDefaultsKey)
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

    private static func persistedAppGroups(_ groups: [Int: Set<String>]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: (0..<autoTileGroupCount).map { groupIndex in
            (String(groupIndex), Array(groups[groupIndex] ?? []).sorted())
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
