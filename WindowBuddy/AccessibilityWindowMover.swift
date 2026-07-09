//
//  AccessibilityWindowMover.swift
//  WindowBuddy
//
//  Created by Codex on 01/06/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSMoveWindow")
private func CGSMoveWindow(_ connectionID: CGSConnectionID,
                           _ windowID: CGWindowID,
                           _ point: UnsafePointer<CGPoint>) -> CGError

struct WindowMoveResult {
    let applicationName: String
    let placement: WindowPlacement
    let variant: WindowLayoutVariant
    let frame: CGRect
}

struct PreferredWindowSizeResult {
    let frame: CGRect
    let didFillScreen: Bool
}

struct WindowTarget {
    let applicationName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let window: AXUIElement
}

struct AutoTileWindowID: Hashable {
    let processIdentifier: pid_t
    let elementHash: Int
}

struct AutoTileOpeningContext {
    let bundleIdentifier: String
    let windowID: AutoTileWindowID?
}

struct AutoTileWindow {
    let id: AutoTileWindowID
    let applicationName: String
    let bundleIdentifier: String
    let title: String?
    let processIdentifier: pid_t
    let window: AXUIElement
    let frame: CGRect
    let screenVisibleFrame: CGRect

    var area: CGFloat {
        max(0, frame.width) * max(0, frame.height)
    }
}

struct AutoTileResult {
    let tiledWindowCount: Int
    let screenCount: Int
    let skippedWindowCount: Int
    let appliedFramesByWindowID: [AutoTileWindowID: CGRect]

    init(tiledWindowCount: Int,
         screenCount: Int,
         skippedWindowCount: Int,
         appliedFramesByWindowID: [AutoTileWindowID: CGRect] = [:]) {
        self.tiledWindowCount = tiledWindowCount
        self.screenCount = screenCount
        self.skippedWindowCount = skippedWindowCount
        self.appliedFramesByWindowID = appliedFramesByWindowID
    }
}

enum WindowMoveError: LocalizedError {
    case accessibilityNotTrusted
    case noFrontmostApplication
    case noFocusedWindow(String)
    case noNextWindow(String)
    case cannotReadWindowFrame
    case cannotFindDisplay
    case cannotResize(AXError)
    case cannotMove(AXError)
    case cannotFocusWindow(AXError)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            "Accessibility permission is required before WindowBuddy can move windows."
        case .noFrontmostApplication:
            "No frontmost application was found."
        case let .noFocusedWindow(applicationName):
            "\(applicationName) does not have a focused window to move."
        case let .noNextWindow(applicationName):
            "\(applicationName) does not have another window to focus."
        case .cannotReadWindowFrame:
            "The focused window's frame could not be read."
        case .cannotFindDisplay:
            "The display for the focused window could not be found."
        case let .cannotResize(error):
            "The focused window refused the resize request (\(error.readableName))."
        case let .cannotMove(error):
            "The focused window refused the move request (\(error.readableName))."
        case let .cannotFocusWindow(error):
            "The next window refused the focus request (\(error.readableName))."
        }
    }
}

final class AccessibilityWindowMover {
    private static let maximumAutoTileRows = 2
    private static let defaultMaximumAutoTileColumns = 3
    private static let supportedMaximumAutoTileColumns = 8
    private static let minimumAutoTileWindowWidth: CGFloat = 160
    private static let minimumFlexibleAutoTileWindowSize: CGFloat = 80
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.duckduckgo.macos.browser",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Canary",
        "com.microsoft.edgemac.Dev",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "org.torproject.torbrowser"
    ]

    var usesInstantWindowMovement = false
    private let frameAttributeSupportLock = NSLock()
    private let windowServerMoveSupportLock = NSLock()
    private var frameAttributeSupportByProcessIdentifier: [pid_t: Bool] = [:]
    private var windowServerMoveSupportByProcessIdentifier: [pid_t: Bool] = [:]
    private var minimumAutoTileSizesByWindowID: [AutoTileWindowID: CGSize] = [:]

    func moveFrontmostWindow(to placement: WindowPlacement, using variant: WindowLayoutVariant) throws -> WindowMoveResult {
        let target = try frontmostWindowTarget()
        return try move(target, to: placement, using: variant)
    }

    func frontmostWindowTarget() throws -> WindowTarget {
        guard AXIsProcessTrusted() else {
            throw WindowMoveError.accessibilityNotTrusted
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw WindowMoveError.noFrontmostApplication
        }

        let applicationName = application.localizedName ?? "Frontmost app"
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let window = try focusedWindow(for: applicationElement, applicationName: applicationName)

        return WindowTarget(applicationName: applicationName,
                            bundleIdentifier: application.bundleIdentifier,
                            processIdentifier: application.processIdentifier,
                            window: window)
    }

    func frontmostAutoTileOpeningContext() -> AutoTileOpeningContext? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let applicationName = application.localizedName ?? "Frontmost app"
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windowID = (try? focusedWindow(for: applicationElement, applicationName: applicationName)).map {
            AutoTileWindowID(processIdentifier: application.processIdentifier,
                             elementHash: Int(CFHash($0)))
        }

        return AutoTileOpeningContext(bundleIdentifier: bundleIdentifier,
                                      windowID: windowID)
    }

    func move(_ target: WindowTarget, to placement: WindowPlacement, using variant: WindowLayoutVariant) throws -> WindowMoveResult {
        let currentFrame = try frame(of: target.window)

        guard let availableFrame = visibleFrame(containing: currentFrame) else {
            throw WindowMoveError.cannotFindDisplay
        }

        let targetFrame = frame(placement.frame(in: availableFrame, using: variant),
                                constrainedTo: availableFrame)
        try set(frame: targetFrame,
                for: target.window,
                processIdentifier: target.processIdentifier)

        return WindowMoveResult(applicationName: target.applicationName,
                                placement: placement,
                                variant: variant,
                                frame: targetFrame)
    }

    func fillScreen(_ target: WindowTarget) throws -> CGRect {
        let currentFrame = try frame(of: target.window)

        guard let availableFrame = visibleFrame(containing: currentFrame) else {
            throw WindowMoveError.cannotFindDisplay
        }

        let targetFrame = frame(availableFrame, constrainedTo: availableFrame)
        try set(frame: targetFrame,
                for: target.window,
                processIdentifier: target.processIdentifier)
        return targetFrame
    }

    func applyPreferredOpeningSize(_ target: WindowTarget) throws -> PreferredWindowSizeResult {
        let currentFrame = try frame(of: target.window)

        guard let availableFrame = visibleFrame(containing: currentFrame) else {
            throw WindowMoveError.cannotFindDisplay
        }

        let shouldFillScreen = target.bundleIdentifier.map(Self.isBrowserBundleIdentifier) ?? false
        let targetFrame = frame(shouldFillScreen ? availableFrame : singleWindowStartFrame(in: availableFrame),
                                constrainedTo: availableFrame)
        try set(frame: targetFrame,
                for: target.window,
                processIdentifier: target.processIdentifier)

        return PreferredWindowSizeResult(frame: targetFrame,
                                         didFillScreen: shouldFillScreen)
    }

    func focusNextWindow() throws -> String {
        guard AXIsProcessTrusted() else {
            throw WindowMoveError.accessibilityNotTrusted
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw WindowMoveError.noFrontmostApplication
        }

        let applicationName = application.localizedName ?? "Frontmost app"
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let currentWindow = try focusedWindow(for: applicationElement, applicationName: applicationName)
        let windows = try windows(for: applicationElement, applicationName: applicationName)

        guard windows.count > 1 else {
            throw WindowMoveError.noNextWindow(applicationName)
        }

        let currentIndex = windows.firstIndex { CFEqual($0, currentWindow) } ?? -1
        let nextWindow = windows[(currentIndex + 1) % windows.count]
        let raiseError = AXUIElementPerformAction(nextWindow, kAXRaiseAction as CFString)
        let focusError = AXUIElementSetAttributeValue(applicationElement,
                                                     kAXFocusedWindowAttribute as CFString,
                                                     nextWindow)

        guard focusError == .success || raiseError == .success else {
            throw WindowMoveError.cannotFocusWindow(focusError)
        }

        application.activate(options: [])
        return applicationName
    }

    func setApplications(_ processIdentifiers: Set<pid_t>, hidden: Bool) -> Int {
        processIdentifiers.reduce(0) { count, processIdentifier in
            guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
                return count
            }

            let didApply = hidden ? application.hide() : application.unhide()
            return didApply ? count + 1 : count
        }
    }

    func hideApplications(bundleIdentifiers: Set<String>) -> Set<String> {
        guard !bundleIdentifiers.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.reduce(into: []) { hiddenBundleIdentifiers, application in
            guard let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifiers.contains(bundleIdentifier),
                  application.activationPolicy == .regular,
                  !application.isHidden else {
                return
            }

            let minimizedWindowCount = minimizeWindows(for: application)
            let didHide = application.hide()

            if didHide || minimizedWindowCount > 0 {
                hiddenBundleIdentifiers.insert(bundleIdentifier)
            }
        }
    }

    func unhideApplications(bundleIdentifiers: Set<String>) -> Set<String> {
        guard !bundleIdentifiers.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.reduce(into: []) { unhiddenBundleIdentifiers, application in
            guard let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifiers.contains(bundleIdentifier),
                  application.activationPolicy == .regular,
                  application.isHidden,
                  application.unhide() else {
                return
            }

            unhiddenBundleIdentifiers.insert(bundleIdentifier)
        }
    }

    func revealApplications(bundleIdentifiers: Set<String>,
                            preferredActivationBundleIdentifiers: [String] = [],
                            activates: Bool = true) -> Int {
        guard !bundleIdentifiers.isEmpty else {
            return 0
        }

        let applications = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return bundleIdentifiers.contains(bundleIdentifier) &&
                application.activationPolicy == .regular
        }
        var affectedBundleIdentifiers: Set<String> = []

        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier else {
                continue
            }

            let didUnhide = application.unhide()
            let unminimizedWindowCount = unminimizeWindows(for: application)

            if didUnhide || unminimizedWindowCount > 0 {
                affectedBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        if activates {
            let applicationsByBundleIdentifier = Dictionary(grouping: applications) { application in
                application.bundleIdentifier ?? ""
            }
            let activationApplication = preferredActivationBundleIdentifiers
                .compactMap { applicationsByBundleIdentifier[$0]?.first }
                .first ?? applications.first

            if let activationApplication,
               let bundleIdentifier = activationApplication.bundleIdentifier,
               activationApplication.activate(options: [.activateAllWindows]) {
                affectedBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        return affectedBundleIdentifiers.count
    }

    func visibleApplicationProcessIdentifiersCoveringActiveScreen() throws -> Set<pid_t> {
        guard AXIsProcessTrusted() else {
            throw WindowMoveError.accessibilityNotTrusted
        }

        guard let targetVisibleFrame = activeScreenVisibleFrame() else {
            throw WindowMoveError.cannotFindDisplay
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownProcessIdentifier = NSRunningApplication.current.processIdentifier

        return Set(NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
            guard application.activationPolicy == .regular,
                  !application.isHidden,
                  application.processIdentifier != ownProcessIdentifier,
                  application.bundleIdentifier != ownBundleIdentifier else {
                return nil
            }

            let applicationName = application.localizedName ?? "Application"
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

            guard let windows = try? windows(for: applicationElement, applicationName: applicationName),
                  windows.contains(where: { window in
                      guard isStandardWindow(window),
                            let frame = try? frame(of: window),
                            frame.width >= 80,
                            frame.height >= 80 else {
                          return false
                      }

                      return frame.intersects(targetVisibleFrame)
                  }) else {
                return nil
            }

            return application.processIdentifier
        })
    }

    func visibleAutoTileWindows(allowedBundleIdentifiers: Set<String>,
                                includesOffscreenWindows: Bool = false) throws -> [AutoTileWindow] {
        guard AXIsProcessTrusted() else {
            throw WindowMoveError.accessibilityNotTrusted
        }

        guard !allowedBundleIdentifiers.isEmpty else {
            return []
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        let screenGeometries = screenGeometries()
        guard !screenGeometries.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.flatMap { application -> [AutoTileWindow] in
            guard let bundleIdentifier = application.bundleIdentifier,
                  allowedBundleIdentifiers.contains(bundleIdentifier) else {
                return []
            }

            guard application.activationPolicy == .regular,
                  !application.isHidden,
                  bundleIdentifier != ownBundleIdentifier else {
                return []
            }

            let applicationName = application.localizedName ?? "Application"
            let processIdentifier = application.processIdentifier
            let applicationElement = AXUIElementCreateApplication(processIdentifier)

            guard let windows = try? windows(for: applicationElement, applicationName: applicationName) else {
                return []
            }

            return windows.compactMap { window -> AutoTileWindow? in
                guard isStandardWindow(window),
                      let frame = try? frame(of: window),
                      frame.width >= 160,
                      frame.height >= 120,
                      let screenVisibleFrame = visibleFrame(containing: frame,
                                                            screenGeometries: screenGeometries),
                      includesOffscreenWindows || frame.intersects(screenVisibleFrame) else {
                    return nil
                }

                return AutoTileWindow(id: AutoTileWindowID(processIdentifier: processIdentifier,
                                                           elementHash: Int(CFHash(window))),
                                      applicationName: applicationName,
                                      bundleIdentifier: bundleIdentifier,
                                      title: stringAttribute(kAXTitleAttribute as CFString, for: window),
                                      processIdentifier: processIdentifier,
                                      window: window,
                                      frame: frame,
                                      screenVisibleFrame: screenVisibleFrame)
            }
        }
    }

    func autoTile(windows: [AutoTileWindow],
                  orderedWindowIDs: [AutoTileWindowID],
                  affectedScreenFrames: [CGRect],
                  layoutMode: AutoTileLayoutMode,
                  reservedSlotBundleIdentifiers: [String] = [],
                  fillsFirstWindow: Bool,
                  fillsSingleVisibleWindow: Bool = false,
                  screenLayoutMode: AutoTileScreenLayoutMode,
                  maximumColumnCount: Int = 3,
                  tileDirection: AutoTileDirection = .leftToRight,
                  ignoresSecondAppInList: Bool,
                  ignoredSecondWindowStartMode: AutoTileIgnoredSecondWindowStartMode,
                  primaryWidthFractionOverride: CGFloat? = nil,
                  primaryWindowIDOverride: AutoTileWindowID? = nil,
                  primaryWindowSlotOverride: Int? = nil,
                  preservesPrimaryWindowPosition: Bool = false) throws -> AutoTileResult {
        let currentWindowIDs = Set(windows.map(\.id))
        minimumAutoTileSizesByWindowID = minimumAutoTileSizesByWindowID.filter {
            currentWindowIDs.contains($0.key)
        }

        let targetScreens = Set(affectedScreenFrames.map(ScreenKey.init))

        var tiledWindowCount = 0
        var skippedWindowCount = 0
        var firstError: Error?
        var appliedFramesByWindowID: [AutoTileWindowID: CGRect] = [:]

        for screen in targetScreens {
            let screenWindows = windows.filter { ScreenKey($0.screenVisibleFrame) == screen }
            let candidateWindows = autoTileCandidateWindows(screenWindows, orderedWindowIDs: orderedWindowIDs)
            guard let screenVisibleFrame = candidateWindows.first?.screenVisibleFrame else {
                continue
            }

            let forcesEqualThirds = layoutMode == .sharedGrid &&
                screenLayoutMode.splitDirection == .horizontal &&
                candidateWindows.count == 3
            let layout = forcesEqualThirds ?
                equalThirdsLayout(for: candidateWindows,
                                  in: screenVisibleFrame,
                                  tileDirection: tileDirection) :
                autoTileLayout(for: candidateWindows,
                               in: screenVisibleFrame,
                               layoutMode: layoutMode,
                               reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers,
                               fillsFirstWindow: fillsFirstWindow,
                               fillsSingleVisibleWindow: fillsSingleVisibleWindow,
                               screenLayoutMode: screenLayoutMode,
                               maximumColumnCount: maximumColumnCount,
                               tileDirection: tileDirection,
                               ignoresSecondAppInList: ignoresSecondAppInList,
                               ignoredSecondWindowStartMode: ignoredSecondWindowStartMode,
                               primaryWidthFractionOverride: primaryWidthFractionOverride,
                               primaryWindowIDOverride: primaryWindowIDOverride,
                               primaryWindowSlotOverride: primaryWindowSlotOverride,
                               preservesPrimaryWindowPosition: preservesPrimaryWindowPosition)
            skippedWindowCount += layout.skippedWindowCount

            var assignments = forcesEqualThirds ?
                layout.assignments :
                adjustedAssignmentsForObservedMinimumSizes(layout.assignments,
                                                           in: screenVisibleFrame)
            var assignmentsToApply = assignments.filter {
                !Self.framesMatch($0.window.frame, $0.frame)
            }
            var writeResult = applyAutoTile(assignments: assignmentsToApply)
            tiledWindowCount += writeResult.tiledWindowCount
            firstError = firstError ?? writeResult.firstError
            appliedFramesByWindowID.merge(writeResult.appliedFramesByWindowID) { _, new in new }

            if !forcesEqualThirds,
               rememberMinimumSizeObservations(writeResult.minimumSizeObservations) {
                let previousTargetFramesByWindowID: [AutoTileWindowID: CGRect] = Dictionary(uniqueKeysWithValues: assignments.map { ($0.window.id, $0.frame) })
                assignments = adjustedAssignmentsForObservedMinimumSizes(layout.assignments,
                                                                         in: screenVisibleFrame)
                assignmentsToApply = assignments.filter { assignment in
                    guard let previousFrame = previousTargetFramesByWindowID[assignment.window.id] else {
                        return true
                    }

                    return !Self.framesMatch(previousFrame, assignment.frame)
                }
                writeResult = applyAutoTile(assignments: assignmentsToApply)
                tiledWindowCount += writeResult.tiledWindowCount
                firstError = firstError ?? writeResult.firstError
                appliedFramesByWindowID.merge(writeResult.appliedFramesByWindowID) { _, new in new }
                _ = rememberMinimumSizeObservations(writeResult.minimumSizeObservations)
            }
        }

        if tiledWindowCount == 0, let firstError {
            throw firstError
        }

        return AutoTileResult(tiledWindowCount: tiledWindowCount,
                              screenCount: targetScreens.count,
                              skippedWindowCount: skippedWindowCount,
                              appliedFramesByWindowID: appliedFramesByWindowID)
    }

    func restoreAutoTileFrames(_ framesByWindowID: [AutoTileWindowID: CGRect],
                               windows: [AutoTileWindow]) -> AutoTileResult {
        guard !framesByWindowID.isEmpty else {
            return AutoTileResult(tiledWindowCount: 0,
                                  screenCount: 0,
                                  skippedWindowCount: 0)
        }

        let assignments = windows.compactMap { window -> (window: AutoTileWindow, frame: CGRect)? in
            guard let frame = framesByWindowID[window.id],
                  !Self.framesMatch(window.frame, frame) else {
                return nil
            }

            return (window: window, frame: frame)
        }
        let writeResult = applyAutoTile(assignments: assignments)
        let screenCount = Set(assignments.map { ScreenKey($0.window.screenVisibleFrame) }).count

        return AutoTileResult(tiledWindowCount: writeResult.tiledWindowCount,
                              screenCount: screenCount,
                              skippedWindowCount: 0,
                              appliedFramesByWindowID: writeResult.appliedFramesByWindowID)
    }

    private func applyAutoTile(assignments: [(window: AutoTileWindow, frame: CGRect)]) -> (tiledWindowCount: Int, firstError: Error?, minimumSizeObservations: [(AutoTileWindowID, CGSize)], appliedFramesByWindowID: [AutoTileWindowID: CGRect]) {
        guard !assignments.isEmpty else {
            return (0, nil, [], [:])
        }

        guard assignments.count > 1 else {
            do {
                let assignment = assignments[0]
                let finalFrame = try setAutoTile(frame: assignment.frame,
                                                 currentFrame: assignment.window.frame,
                                                 for: assignment.window.window,
                                                 processIdentifier: assignment.window.processIdentifier)
                return (1, nil, minimumSizeObservation(for: assignment,
                                                       finalFrame: finalFrame).map { [$0] } ?? [], [assignment.window.id: finalFrame])
            } catch {
                return (0, error, [], [:])
            }
        }

        let lock = NSLock()
        var tiledWindowCount = 0
        var firstError: Error?
        var minimumSizeObservations: [(AutoTileWindowID, CGSize)] = []
        var appliedFramesByWindowID: [AutoTileWindowID: CGRect] = [:]

        let applyAssignment: (Int) -> Void = { index in
            let assignment = assignments[index]

            do {
                let finalFrame = try self.setAutoTile(frame: assignment.frame,
                                                      currentFrame: assignment.window.frame,
                                                      for: assignment.window.window,
                                                      processIdentifier: assignment.window.processIdentifier)
                lock.withLock {
                    tiledWindowCount += 1
                    appliedFramesByWindowID[assignment.window.id] = finalFrame
                    if let observation = self.minimumSizeObservation(for: assignment,
                                                                     finalFrame: finalFrame) {
                        minimumSizeObservations.append(observation)
                    }
                }
            } catch {
                lock.withLock {
                    firstError = firstError ?? error
                }
            }
        }

        if assignments.count < 4 {
            for index in assignments.indices {
                applyAssignment(index)
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: assignments.count, execute: applyAssignment)
        }

        return (tiledWindowCount, firstError, minimumSizeObservations, appliedFramesByWindowID)
    }

    private func minimumSizeObservation(for assignment: (window: AutoTileWindow, frame: CGRect),
                                        finalFrame: CGRect) -> (AutoTileWindowID, CGSize)? {
        let widthOverflow = finalFrame.width - assignment.frame.width
        let heightOverflow = finalFrame.height - assignment.frame.height

        guard widthOverflow > 2 || heightOverflow > 2 else {
            return nil
        }

        return (assignment.window.id, finalFrame.size)
    }

    @discardableResult
    private func rememberMinimumSizeObservations(_ observations: [(AutoTileWindowID, CGSize)]) -> Bool {
        var didChange = false

        for (windowID, observedSize) in observations {
            let currentSize = minimumAutoTileSizesByWindowID[windowID] ?? .zero
            let mergedSize = CGSize(width: max(currentSize.width, observedSize.width),
                                    height: max(currentSize.height, observedSize.height))

            guard !Self.sizesMatch(currentSize, mergedSize) else {
                continue
            }

            minimumAutoTileSizesByWindowID[windowID] = mergedSize
            didChange = true
        }

        return didChange
    }

    private func adjustedAssignmentsForObservedMinimumSizes(_ assignments: [(window: AutoTileWindow, frame: CGRect)],
                                                            in availableFrame: CGRect) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard !assignments.isEmpty,
              assignments.contains(where: { minimumAutoTileSizesByWindowID[$0.window.id] != nil }) else {
            return assignments
        }

        let rows = visualRows(from: assignments)
        let baseRowHeights = rows.map { row -> CGFloat in
            guard let minY = row.map({ $0.frame.minY }).min(),
                  let maxY = row.map({ $0.frame.maxY }).max() else {
                return 0
            }

            return max(0, maxY - minY)
        }
        let minimumRowHeights = rows.enumerated().map { index, row -> CGFloat in
            let observedMinimumHeight = row
                .compactMap { minimumAutoTileSizesByWindowID[$0.window.id]?.height }
                .max() ?? 0

            return max(minimumFlexibleSize(for: baseRowHeights[index]), observedMinimumHeight)
        }
        let rowHeights = allocatedSizes(baseSizes: baseRowHeights,
                                        minimumSizes: minimumRowHeights,
                                        totalSize: availableFrame.height)
        var y = availableFrame.minY

        return rows.enumerated().flatMap { index, row -> [(window: AutoTileWindow, frame: CGRect)] in
            let rowHeight = rowHeights[index]
            let rowAssignments = adjustedRowAssignmentsForObservedMinimumSizes(row,
                                                                               y: y,
                                                                               height: rowHeight)
            y += rowHeight

            return rowAssignments
        }
    }

    private func adjustedRowAssignmentsForObservedMinimumSizes(_ row: [(window: AutoTileWindow, frame: CGRect)],
                                                               y: CGFloat,
                                                               height: CGFloat) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard let minX = row.map({ $0.frame.minX }).min(),
              let maxX = row.map({ $0.frame.maxX }).max() else {
            return row
        }

        let rowWidth = max(0, maxX - minX)
        let baseWidths = row.map { max(0, $0.frame.width) }
        let minimumWidths = row.enumerated().map { index, assignment -> CGFloat in
            let observedMinimumWidth = minimumAutoTileSizesByWindowID[assignment.window.id]?.width ?? 0
            return max(minimumFlexibleSize(for: baseWidths[index]), observedMinimumWidth)
        }
        let widths = allocatedSizes(baseSizes: baseWidths,
                                    minimumSizes: minimumWidths,
                                    totalSize: rowWidth)
        var x = minX

        return row.enumerated().map { index, assignment in
            let isLast = index == row.count - 1
            let nextX = isLast ? maxX : x + widths[index]
            let frame = roundedFrame(CGRect(x: x,
                                            y: y,
                                            width: max(0, nextX - x),
                                            height: height))
            x = nextX

            return (window: assignment.window, frame: frame)
        }
    }

    private func allocatedSizes(baseSizes: [CGFloat],
                                minimumSizes: [CGFloat],
                                totalSize: CGFloat) -> [CGFloat] {
        guard baseSizes.count == minimumSizes.count,
              !baseSizes.isEmpty else {
            return baseSizes
        }

        let totalSize = max(0, totalSize)
        let lowerBounds = minimumSizes.map { max(1, $0) }
        let lowerBoundTotal = lowerBounds.reduce(0, +)

        if lowerBoundTotal >= totalSize {
            guard lowerBoundTotal > 0 else {
                return Array(repeating: 0, count: baseSizes.count)
            }

            return lowerBounds.map { totalSize * ($0 / lowerBoundTotal) }
        }

        let desiredSizes = zip(baseSizes, lowerBounds).map { max($0, $1) }
        let desiredTotal = desiredSizes.reduce(0, +)
        guard desiredTotal > totalSize else {
            let extra = totalSize - desiredTotal
            let baseTotal = baseSizes.reduce(0, +)

            guard extra > 0,
                  baseTotal > 0 else {
                return desiredSizes
            }

            return zip(desiredSizes, baseSizes).map { desiredSize, baseSize in
                desiredSize + extra * (baseSize / baseTotal)
            }
        }

        let remainingSize = totalSize - lowerBoundTotal
        let flexibleSizes = zip(desiredSizes, lowerBounds).map { max(0, $0 - $1) }
        let flexibleTotal = flexibleSizes.reduce(0, +)

        guard flexibleTotal > 0 else {
            return lowerBounds
        }

        return zip(lowerBounds, flexibleSizes).map { lowerBound, flexibleSize in
            lowerBound + remainingSize * (flexibleSize / flexibleTotal)
        }
    }

    private func minimumFlexibleSize(for baseSize: CGFloat) -> CGFloat {
        min(max(1, baseSize), Self.minimumFlexibleAutoTileWindowSize)
    }

    private func focusedWindow(for applicationElement: AXUIElement, applicationName: String) throws -> AXUIElement {
        var focusedWindow: CFTypeRef?
        let focusedWindowError = AXUIElementCopyAttributeValue(applicationElement,
                                                              kAXFocusedWindowAttribute as CFString,
                                                              &focusedWindow)

        if focusedWindowError == .success,
           let focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            return focusedWindow as! AXUIElement
        }

        var mainWindow: CFTypeRef?
        let mainWindowError = AXUIElementCopyAttributeValue(applicationElement,
                                                           kAXMainWindowAttribute as CFString,
                                                           &mainWindow)

        guard mainWindowError == .success,
              let mainWindow,
              CFGetTypeID(mainWindow) == AXUIElementGetTypeID() else {
            throw WindowMoveError.noFocusedWindow(applicationName)
        }

        return mainWindow as! AXUIElement
    }

    private func windows(for applicationElement: AXUIElement, applicationName: String) throws -> [AXUIElement] {
        var windowsValue: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(applicationElement,
                                                        kAXWindowsAttribute as CFString,
                                                        &windowsValue)

        guard windowsError == .success,
              let windowsValue,
              CFGetTypeID(windowsValue) == CFArrayGetTypeID() else {
            throw WindowMoveError.noNextWindow(applicationName)
        }

        let windows = windowsValue as! [AXUIElement]
        return windows.filter { !isMinimized($0) }
    }

    private func allWindows(for applicationElement: AXUIElement) -> [AXUIElement] {
        var windowsValue: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(applicationElement,
                                                        kAXWindowsAttribute as CFString,
                                                        &windowsValue)

        guard windowsError == .success,
              let windowsValue,
              CFGetTypeID(windowsValue) == CFArrayGetTypeID() else {
            return []
        }

        return windowsValue as! [AXUIElement]
    }

    private func unminimizeWindows(for application: NSRunningApplication) -> Int {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        return allWindows(for: applicationElement).reduce(0) { count, window in
            guard isStandardWindow(window),
                  isMinimized(window) else {
                return count
            }

            let error = AXUIElementSetAttributeValue(window,
                                                     kAXMinimizedAttribute as CFString,
                                                     kCFBooleanFalse)
            return error == .success ? count + 1 : count
        }
    }

    private func minimizeWindows(for application: NSRunningApplication) -> Int {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        return allWindows(for: applicationElement).reduce(0) { count, window in
            guard isStandardWindow(window),
                  !isMinimized(window) else {
                return count
            }

            let error = AXUIElementSetAttributeValue(window,
                                                     kAXMinimizedAttribute as CFString,
                                                     kCFBooleanTrue)
            return error == .success ? count + 1 : count
        }
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute as CFString, for: window) == (kAXWindowRole as String) else {
            return false
        }

        guard let subrole = stringAttribute(kAXSubroleAttribute as CFString, for: window) else {
            return true
        }

        return subrole == (kAXStandardWindowSubrole as String)
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }

        return value as? String
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let minimizedError = AXUIElementCopyAttributeValue(window,
                                                          kAXMinimizedAttribute as CFString,
                                                          &minimizedValue)

        guard minimizedError == .success,
              let minimizedValue,
              CFGetTypeID(minimizedValue) == CFBooleanGetTypeID() else {
            return false
        }

        let minimized = minimizedValue as! CFBoolean
        return CFBooleanGetValue(minimized)
    }

    func currentFrame(of window: AXUIElement) -> CGRect? {
        try? frame(of: window)
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let positionError = AXUIElementCopyAttributeValue(window,
                                                         kAXPositionAttribute as CFString,
                                                         &positionValue)
        let sizeError = AXUIElementCopyAttributeValue(window,
                                                     kAXSizeAttribute as CFString,
                                                     &sizeValue)

        guard positionError == .success,
              sizeError == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        return CGRect(origin: position, size: size)
    }

    private func set(frame targetFrame: CGRect,
                     for window: AXUIElement,
                     processIdentifier: pid_t) throws {
        let currentFrame = try frame(of: window)
        let targetFrame = frame(targetFrame, constrainedToVisibleFrameFor: currentFrame)
        guard !Self.framesMatch(currentFrame, targetFrame) else {
            return
        }

        if usesInstantWindowMovement {
            if try writeFrameAttributeIfSupported(targetFrame,
                                                  for: window,
                                                  processIdentifier: processIdentifier) {
                correctFrameIfNeeded(of: window,
                                     targetFrame: targetFrame,
                                     currentFrame: currentFrame,
                                     processIdentifier: processIdentifier)
                return
            }

            try writeInstant(frame: targetFrame,
                             currentFrame: currentFrame,
                             for: window,
                             processIdentifier: processIdentifier)
            correctFrameIfNeeded(of: window,
                                 targetFrame: targetFrame,
                                 currentFrame: currentFrame,
                                 processIdentifier: processIdentifier)
            return
        }

        try write(frame: targetFrame,
                  currentFrame: currentFrame,
                  for: window)
        correctFrameIfNeeded(of: window,
                             targetFrame: targetFrame,
                             currentFrame: currentFrame,
                             processIdentifier: processIdentifier)
    }

    private func setAutoTile(frame targetFrame: CGRect,
                             currentFrame: CGRect,
                             for window: AXUIElement,
                             processIdentifier: pid_t) throws -> CGRect {
        let targetFrame = frame(targetFrame, constrainedToVisibleFrameFor: currentFrame)
        guard !Self.framesMatch(currentFrame, targetFrame) else {
            return currentFrame
        }

        guard usesInstantWindowMovement else {
            try write(frame: targetFrame,
                      currentFrame: currentFrame,
                      for: window)
            return correctFrameIfNeeded(of: window,
                                        targetFrame: targetFrame,
                                        currentFrame: currentFrame,
                                        processIdentifier: processIdentifier) ?? targetFrame
        }

        do {
            if try writeFrameAttributeIfSupported(targetFrame,
                                                 for: window,
                                                 processIdentifier: processIdentifier) {
                return correctFrameIfNeeded(of: window,
                                            targetFrame: targetFrame,
                                            currentFrame: currentFrame,
                                            processIdentifier: processIdentifier) ?? targetFrame
            }

            try writeInstant(frame: targetFrame,
                             currentFrame: currentFrame,
                             for: window,
                             processIdentifier: processIdentifier)
            return correctFrameIfNeeded(of: window,
                                        targetFrame: targetFrame,
                                        currentFrame: currentFrame,
                                        processIdentifier: processIdentifier) ?? targetFrame
        } catch {
            try write(frame: targetFrame,
                      currentFrame: currentFrame,
                      for: window)
            return correctFrameIfNeeded(of: window,
                                        targetFrame: targetFrame,
                                        currentFrame: currentFrame,
                                        processIdentifier: processIdentifier) ?? targetFrame
        }
    }

    @discardableResult
    private func correctFrameIfNeeded(of window: AXUIElement,
                                      targetFrame: CGRect,
                                      currentFrame: CGRect,
                                      processIdentifier: pid_t) -> CGRect? {
        guard var finalFrame = try? frame(of: window) else {
            return nil
        }

        guard !Self.framesMatch(finalFrame, targetFrame) else {
            return finalFrame
        }

        guard let visibleFrame = visibleFrame(containing: targetFrame) ?? visibleFrame(containing: currentFrame) else {
            return finalFrame
        }

        for _ in 0..<3 {
            let constrainedFrame = frame(finalFrame, constrainedTo: visibleFrame)
            let correctedFrame = centerPreservingFrameIfNeeded(targetFrame: targetFrame,
                                                               acceptedFrame: constrainedFrame,
                                                               visibleFrame: visibleFrame) ?? constrainedFrame
            guard !Self.framesMatch(finalFrame, correctedFrame) else {
                return finalFrame
            }

            try? writeConstrainedCorrection(frame: correctedFrame,
                                            visibleFrame: visibleFrame,
                                            currentFrame: finalFrame,
                                            for: window,
                                            processIdentifier: processIdentifier)

            guard let correctedFrame = try? frame(of: window) else {
                return constrainedFrame
            }

            if Self.framesMatch(correctedFrame, finalFrame) {
                return correctedFrame
            }

            finalFrame = correctedFrame
        }

        return finalFrame
    }

    private func centerPreservingFrameIfNeeded(targetFrame: CGRect,
                                               acceptedFrame: CGRect,
                                               visibleFrame: CGRect) -> CGRect? {
        let roundedTargetFrame = roundedFrame(targetFrame)
        let roundedAcceptedFrame = roundedFrame(acceptedFrame)
        let roundedVisibleFrame = roundedFrame(visibleFrame)

        guard abs(roundedTargetFrame.midX - roundedVisibleFrame.midX) <= 1 else {
            return nil
        }

        let centeredOriginX = clampedOrigin(roundedVisibleFrame.midX - roundedAcceptedFrame.width / 2,
                                            size: roundedAcceptedFrame.width,
                                            visibleMin: roundedVisibleFrame.minX,
                                            visibleMax: roundedVisibleFrame.maxX)
        let originY = clampedOrigin(roundedAcceptedFrame.minY,
                                    size: roundedAcceptedFrame.height,
                                    visibleMin: roundedVisibleFrame.minY,
                                    visibleMax: roundedVisibleFrame.maxY)

        return CGRect(x: centeredOriginX,
                      y: originY,
                      width: roundedAcceptedFrame.width,
                      height: roundedAcceptedFrame.height)
    }

    private func writeConstrainedCorrection(frame targetFrame: CGRect,
                                            visibleFrame: CGRect,
                                            currentFrame: CGRect,
                                            for window: AXUIElement,
                                            processIdentifier: pid_t) throws {
        var targetSize = targetFrame.size
        guard let targetSizeValue = AXValueCreate(.cgSize, &targetSize) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let shouldResize = !Self.sizesMatch(currentFrame.size, targetSize)
        if shouldResize {
            let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, targetSizeValue)
            guard sizeError == .success else {
                throw WindowMoveError.cannotResize(sizeError)
            }
        }

        let acceptedFrame = (try? frame(of: window)) ?? CGRect(origin: currentFrame.origin, size: targetSize)
        let acceptedOrigin = origin(for: acceptedFrame.size,
                                    near: targetFrame.origin,
                                    constrainedTo: visibleFrame)

        guard !Self.pointsMatch(acceptedFrame.origin, acceptedOrigin) else {
            return
        }

        if moveWithWindowServerIfPossible(window,
                                          processIdentifier: processIdentifier,
                                          to: acceptedOrigin) {
            return
        }

        var position = acceptedOrigin
        guard let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard positionError == .success else {
            throw WindowMoveError.cannotMove(positionError)
        }
    }

    private func frame(_ targetFrame: CGRect,
                       constrainedToVisibleFrameFor referenceFrame: CGRect) -> CGRect {
        guard let visibleFrame = visibleFrame(containing: referenceFrame) ?? visibleFrame(containing: targetFrame) else {
            return roundedFrame(targetFrame)
        }

        return frame(targetFrame, constrainedTo: visibleFrame)
    }

    private func frame(_ targetFrame: CGRect,
                       constrainedTo visibleFrame: CGRect) -> CGRect {
        let roundedTargetFrame = roundedFrame(targetFrame)
        let roundedVisibleFrame = roundedFrame(visibleFrame)
        let width = min(max(1, roundedTargetFrame.width), max(1, roundedVisibleFrame.width))
        let height = min(max(1, roundedTargetFrame.height), max(1, roundedVisibleFrame.height))
        let minX = clampedOrigin(roundedTargetFrame.minX,
                                 size: width,
                                 visibleMin: roundedVisibleFrame.minX,
                                 visibleMax: roundedVisibleFrame.maxX)
        let minY = clampedOrigin(roundedTargetFrame.minY,
                                 size: height,
                                 visibleMin: roundedVisibleFrame.minY,
                                 visibleMax: roundedVisibleFrame.maxY)

        return CGRect(x: minX,
                      y: minY,
                      width: width,
                      height: height)
    }

    private func origin(for size: CGSize,
                        near origin: CGPoint,
                        constrainedTo visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: clampedOrigin(origin.x,
                                 size: size.width,
                                 visibleMin: visibleFrame.minX,
                                 visibleMax: visibleFrame.maxX),
                y: clampedOrigin(origin.y,
                                 size: size.height,
                                 visibleMin: visibleFrame.minY,
                                 visibleMax: visibleFrame.maxY))
    }

    private func clampedOrigin(_ origin: CGFloat,
                               size: CGFloat,
                               visibleMin: CGFloat,
                               visibleMax: CGFloat) -> CGFloat {
        guard size < visibleMax - visibleMin else {
            return visibleMin
        }

        return min(max(origin, visibleMin), visibleMax - size)
    }

    private func writeFrameAttributeIfSupported(_ frame: CGRect,
                                                for window: AXUIElement,
                                                processIdentifier: pid_t) throws -> Bool {
        if frameAttributeSupportLock.withLock({ frameAttributeSupportByProcessIdentifier[processIdentifier] == false }) {
            return false
        }

        var frame = frame

        guard let frameValue = AXValueCreate(.cgRect, &frame) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let error = AXUIElementSetAttributeValue(window, "AXFrame" as CFString, frameValue)
        let isSupported = error == .success
        frameAttributeSupportLock.withLock {
            frameAttributeSupportByProcessIdentifier[processIdentifier] = isSupported
        }
        return isSupported
    }

    private func writeInstant(frame targetFrame: CGRect,
                              currentFrame: CGRect,
                              for window: AXUIElement,
                              processIdentifier: pid_t) throws {
        var size = targetFrame.size
        var position = targetFrame.origin

        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let shouldMove = !Self.pointsMatch(currentFrame.origin, targetFrame.origin)
        let shouldResize = !Self.sizesMatch(currentFrame.size, targetFrame.size)
        guard shouldMove || shouldResize else {
            return
        }

        let didMoveWithWindowServer = shouldMove &&
            moveWithWindowServerIfPossible(window,
                                           processIdentifier: processIdentifier,
                                           to: targetFrame.origin)

        if shouldMove, shouldResize, !didMoveWithWindowServer {
            let positionError = AXUIElementSetAttributeValue(window,
                                                            kAXPositionAttribute as CFString,
                                                            positionValue)
            guard positionError == .success else {
                throw WindowMoveError.cannotMove(positionError)
            }

            let sizeError = AXUIElementSetAttributeValue(window,
                                                        kAXSizeAttribute as CFString,
                                                        sizeValue)
            guard sizeError == .success else {
                throw WindowMoveError.cannotResize(sizeError)
            }

            return
        }

        if shouldResize {
            let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            guard sizeError == .success else {
                throw WindowMoveError.cannotResize(sizeError)
            }
        }

        if shouldMove, !didMoveWithWindowServer {
            let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            guard positionError == .success else {
                throw WindowMoveError.cannotMove(positionError)
            }

            if !shouldResize {
                try nudgeSizeIfPossible(of: window, from: targetFrame.size)
                let finalPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
                guard finalPositionError == .success else {
                    throw WindowMoveError.cannotMove(finalPositionError)
                }
            }
        }

        if shouldMove, didMoveWithWindowServer, shouldResize {
            _ = moveWithWindowServerIfPossible(window,
                                               processIdentifier: processIdentifier,
                                               to: targetFrame.origin)
        }
    }

    private func moveWithWindowServerIfPossible(_ window: AXUIElement,
                                                processIdentifier: pid_t,
                                                to origin: CGPoint) -> Bool {
        if windowServerMoveSupportLock.withLock({ windowServerMoveSupportByProcessIdentifier[processIdentifier] == false }) {
            return false
        }

        guard let windowID = windowNumber(for: window) else {
            windowServerMoveSupportLock.withLock {
                windowServerMoveSupportByProcessIdentifier[processIdentifier] = false
            }
            return false
        }

        var origin = origin
        let error = withUnsafePointer(to: &origin) { originPointer in
            CGSMoveWindow(CGSMainConnectionID(), windowID, originPointer)
        }
        let isSupported = error == .success
        windowServerMoveSupportLock.withLock {
            windowServerMoveSupportByProcessIdentifier[processIdentifier] = isSupported
        }
        return isSupported
    }

    private func windowNumber(for window: AXUIElement) -> CGWindowID? {
        var windowNumberValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window,
                                                  "AXWindowNumber" as CFString,
                                                  &windowNumberValue)

        guard error == .success,
              let windowNumberValue,
              CFGetTypeID(windowNumberValue) == CFNumberGetTypeID() else {
            return nil
        }

        let windowNumber = (windowNumberValue as! NSNumber).uint32Value
        guard windowNumber > 0 else {
            return nil
        }

        return CGWindowID(windowNumber)
    }

    private func write(frame: CGRect,
                       currentFrame: CGRect? = nil,
                       for window: AXUIElement) throws {
        var size = frame.size
        var position = frame.origin

        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        let originalFrame = try currentFrame ?? self.frame(of: window)
        let shouldNudgeMoveOnlyWindow = !Self.pointsMatch(originalFrame.origin, frame.origin) &&
            Self.sizesMatch(originalFrame.size, frame.size)
        let firstPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let firstSizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        if shouldNudgeMoveOnlyWindow {
            try nudgeSizeIfPossible(of: window, from: frame.size)
        }

        let secondPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard secondPositionError == .success else {
            throw WindowMoveError.cannotMove(firstPositionError == .success ? secondPositionError : firstPositionError)
        }

        let finalSizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard finalSizeError == .success else {
            throw WindowMoveError.cannotResize(firstSizeError == .success ? finalSizeError : firstSizeError)
        }

        let finalPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard finalPositionError == .success else {
            throw WindowMoveError.cannotMove(finalPositionError)
        }
    }

    private func nudgeSizeIfPossible(of window: AXUIElement, from targetSize: CGSize) throws {
        let nudgeAmount = min(48, max(16, targetSize.width * 0.08))
        let candidateSizes = [
            CGSize(width: max(1, targetSize.width - nudgeAmount),
                   height: targetSize.height),
            CGSize(width: targetSize.width + nudgeAmount,
                   height: targetSize.height),
            CGSize(width: targetSize.width,
                   height: max(1, targetSize.height - nudgeAmount)),
            CGSize(width: targetSize.width,
                   height: targetSize.height + nudgeAmount)
        ]
        var restoredSize = targetSize

        guard let restoredSizeValue = AXValueCreate(.cgSize, &restoredSize) else {
            throw WindowMoveError.cannotReadWindowFrame
        }

        for candidateSize in candidateSizes {
            var nudgeSize = candidateSize
            guard let nudgeSizeValue = AXValueCreate(.cgSize, &nudgeSize) else {
                throw WindowMoveError.cannotReadWindowFrame
            }

            let nudgeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, nudgeSizeValue)
            guard nudgeError == .success else {
                continue
            }

            let restoreError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, restoredSizeValue)
            guard restoreError == .success else {
                throw WindowMoveError.cannotResize(restoreError)
            }

            return
        }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 &&
            abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 &&
            abs(lhs.height - rhs.height) <= 1
    }

    private static func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 &&
            abs(lhs.y - rhs.y) <= 1
    }

    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 &&
            abs(lhs.height - rhs.height) <= 1
    }

    private func activeScreenVisibleFrame() -> CGRect? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            let applicationName = frontmostApplication.localizedName ?? "Frontmost app"
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)

            if let focusedWindow = try? focusedWindow(for: applicationElement, applicationName: applicationName),
               let focusedFrame = try? frame(of: focusedWindow),
               let visibleFrame = visibleFrame(containing: focusedFrame) {
                return visibleFrame
            }
        }

        guard let primaryScreen = primaryScreen() else {
            return nil
        }

        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? primaryScreen
        return accessibilityFrame(from: mouseScreen.visibleFrame, primaryFrame: primaryScreen.frame)
    }

    private func visibleFrame(containing windowFrame: CGRect) -> CGRect? {
        visibleFrame(containing: windowFrame, screenGeometries: screenGeometries())
    }

    private func visibleFrame(containing windowFrame: CGRect,
                              screenGeometries: [ScreenGeometry]) -> CGRect? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        if let screen = screenGeometries.first(where: { $0.frame.contains(center) }) {
            return screen.visibleFrame
        }

        if let screen = screenGeometries
            .map({ geometry -> (geometry: ScreenGeometry, area: CGFloat) in
                let intersection = geometry.frame.intersection(windowFrame)
                let area = max(0, intersection.width) * max(0, intersection.height)
                return (geometry, area)
            })
            .max(by: { $0.area < $1.area }),
            screen.area > 0 {
            return screen.geometry.visibleFrame
        }

        return screenGeometries
            .min { distanceSquared(from: center, to: $0.frame) < distanceSquared(from: center, to: $1.frame) }?
            .visibleFrame
    }

    private func screenGeometries() -> [ScreenGeometry] {
        guard let primaryScreen = primaryScreen() else {
            return []
        }

        let primaryFrame = primaryScreen.frame
        return NSScreen.screens.map { screen in
            ScreenGeometry(frame: accessibilityFrame(from: screen.frame, primaryFrame: primaryFrame),
                           visibleFrame: accessibilityFrame(from: screen.visibleFrame, primaryFrame: primaryFrame))
        }
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    private func accessibilityFrame(from cocoaFrame: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: cocoaFrame.minX - primaryFrame.minX,
               y: primaryFrame.maxY - cocoaFrame.maxY,
               width: cocoaFrame.width,
               height: cocoaFrame.height)
    }

    private func distanceSquared(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, frame.minX), frame.maxX)
        let clampedY = min(max(point.y, frame.minY), frame.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func distanceSquared(from point: CGPoint, to otherPoint: CGPoint) -> CGFloat {
        let dx = point.x - otherPoint.x
        let dy = point.y - otherPoint.y
        return dx * dx + dy * dy
    }

    private func autoTileCandidateWindows(_ windows: [AutoTileWindow],
                                          orderedWindowIDs: [AutoTileWindowID]) -> [AutoTileWindow] {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let orderedWindows = orderedWindowIDs.compactMap { windowsByID[$0] }
        let orderedWindowIDSet = Set(orderedWindows.map(\.id))
        let unorderedWindows = windows
            .filter { !orderedWindowIDSet.contains($0.id) }
            .sorted(by: windowSpatialSort)

        return orderedWindows + unorderedWindows
    }

    private func autoTileLayout(for windows: [AutoTileWindow],
                                in screenVisibleFrame: CGRect,
                                layoutMode: AutoTileLayoutMode,
                                reservedSlotBundleIdentifiers: [String],
                                fillsFirstWindow: Bool,
                                fillsSingleVisibleWindow: Bool,
                                screenLayoutMode: AutoTileScreenLayoutMode,
                                maximumColumnCount: Int,
                                tileDirection: AutoTileDirection,
                                ignoresSecondAppInList: Bool,
                                ignoredSecondWindowStartMode: AutoTileIgnoredSecondWindowStartMode,
                                primaryWidthFractionOverride: CGFloat?,
                                primaryWindowIDOverride: AutoTileWindowID?,
                                primaryWindowSlotOverride: Int?,
                                preservesPrimaryWindowPosition: Bool) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        guard !windows.isEmpty else {
            return ([], 0)
        }

        if layoutMode == .sharedGrid,
           screenLayoutMode.splitDirection == .horizontal,
           windows.count == 3 {
            return equalThirdsLayout(for: windows,
                                     in: screenVisibleFrame,
                                     tileDirection: tileDirection)
        }

        if layoutMode == .sharedGrid,
           screenLayoutMode.splitDirection == .vertical,
           windows.count > 2 {
            return verticalOverlayLayout(for: windows,
                                         in: screenVisibleFrame,
                                         primaryFraction: screenLayoutMode.primaryFraction,
                                         tileDirection: tileDirection)
        }

        if windows.count == 1,
           let window = windows.first {
            if preservesPrimaryWindowPosition,
               primaryWindowIDOverride == window.id {
                return ([(window: window, frame: roundedFrame(window.frame))], 0)
            }

            let frame: CGRect

            if let reservedSlot = reservedSlotBundleIdentifiers.firstIndex(of: window.bundleIdentifier),
               reservedSlotBundleIdentifiers.count > 1 {
                let frames = autoTileFrames(count: reservedSlotBundleIdentifiers.count,
                                            in: screenVisibleFrame,
                                            maximumColumnCount: maximumColumnCount,
                                            tileDirection: tileDirection)
                frame = frames[min(reservedSlot, frames.count - 1)]
            } else {
                let canFillScreen = Self.isBrowserBundleIdentifier(window.bundleIdentifier)
                if screenLayoutMode == .fullScreen {
                    frame = screenVisibleFrame
                } else if screenLayoutMode.prioritizesFirstWindow ||
                          screenLayoutMode == .verticalScreen {
                    frame = splitPrimaryFrames(in: screenVisibleFrame,
                                               primaryFraction: screenLayoutMode.primaryFraction,
                                               direction: screenLayoutMode.splitDirection,
                                               tileDirection: tileDirection).originalFrame
                } else if (fillsFirstWindow || fillsSingleVisibleWindow) && canFillScreen {
                    frame = screenVisibleFrame
                } else {
                    frame = singleWindowStartFrame(in: screenVisibleFrame,
                                                   tileDirection: tileDirection,
                                                   maximumColumnCount: maximumColumnCount)
                }
            }

            return ([(window: window, frame: frame)], 0)
        }

        if let primaryWidthFractionOverride,
           let primaryWindowIDOverride,
           windows.contains(where: { $0.id == primaryWindowIDOverride }) {
            if preservesPrimaryWindowPosition {
                return positionPreservingPrimaryLayout(for: windows,
                                                       in: screenVisibleFrame,
                                                       primaryWindowID: primaryWindowIDOverride,
                                                       primaryWidthFraction: primaryWidthFractionOverride,
                                                       primaryWindowSlot: primaryWindowSlotOverride,
                                                       maximumColumnCount: maximumColumnCount,
                                                       tileDirection: tileDirection)
            }

            let baseLayout = primaryBaseLayout(for: windows,
                                               in: screenVisibleFrame,
                                               layoutMode: layoutMode,
                                               reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers,
                                               screenLayoutMode: screenLayoutMode,
                                               maximumColumnCount: maximumColumnCount,
                                               tileDirection: tileDirection,
                                               ignoresSecondAppInList: ignoresSecondAppInList,
                                               ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)

            return visuallyWeightedPrimaryLayout(primaryWindowID: primaryWindowIDOverride,
                                                 primaryTwoWindowWidthFraction: primaryWidthFractionOverride,
                                                 baseAssignments: baseLayout.assignments,
                                                 skippedWindowCount: baseLayout.skippedWindowCount)
        }

        if let primaryWidthFractionOverride,
           usesFirstWindowPriorityLayout(layoutMode: layoutMode,
                                         screenLayoutMode: screenLayoutMode,
                                         windowCount: windows.count,
                                         maximumColumnCount: maximumColumnCount) {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: primaryWidthFractionOverride,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if layoutMode == .sharedGrid,
           usesFirstWindowPriorityLayout(layoutMode: layoutMode,
                                         screenLayoutMode: screenLayoutMode,
                                         windowCount: windows.count,
                                         maximumColumnCount: maximumColumnCount) {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if layoutMode == .sharedGrid,
           windows.count == 2,
           screenLayoutMode != .fullScreen,
           tileDirection != .centerOut {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if layoutMode == .sharedGrid,
           screenLayoutMode.splitDirection == .vertical {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if ignoredSecondWindowStartMode == .middleStart {
            let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
            let tiledWindows = Array(windows.prefix(maximumWindowCount))
            let skippedWindowCount = max(0, windows.count - tiledWindows.count)

            return (middleStartGridAssignments(for: tiledWindows,
                                               in: screenVisibleFrame,
                                               maximumColumnCount: maximumColumnCount,
                                               tileDirection: tileDirection,
                                               reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers),
                    skippedWindowCount)
        }

        switch layoutMode {
        case .sharedGrid:
            let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
            let tiledWindows = Array(windows.prefix(maximumWindowCount))
            let skippedWindowCount = max(0, windows.count - tiledWindows.count)
            let assignments: [(window: AutoTileWindow, frame: CGRect)]

            if ignoresSecondAppInList,
               ignoredSecondWindowStartMode == .normalStart {
                assignments = fullScreenGridAssignmentsIgnoringSecondWindow(for: tiledWindows,
                                                                            in: screenVisibleFrame,
                                                                            maximumColumnCount: maximumColumnCount,
                                                                            tileDirection: tileDirection,
                                                                            reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers)
            } else {
                assignments = autoTileAssignments(for: tiledWindows,
                                                  in: screenVisibleFrame,
                                                  maximumColumnCount: maximumColumnCount,
                                                  tileDirection: tileDirection,
                                                  reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers)
            }

            return (assignments, skippedWindowCount)
        case .splitOriginal:
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: 0.5,
                                             splitDirection: .horizontal,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }
    }

    private func equalThirdsLayout(for windows: [AutoTileWindow],
                                   in screenVisibleFrame: CGRect,
                                   tileDirection: AutoTileDirection) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        let orderedWindows: [AutoTileWindow]

        switch tileDirection {
        case .leftToRight, .centerOut:
            orderedWindows = windows
        case .rightToLeft:
            orderedWindows = Array(windows.reversed())
        }

        let frames = autoTileFrames(count: 3,
                                    in: screenVisibleFrame,
                                    maximumColumnCount: 3,
                                    tileDirection: .leftToRight)

        return (zip(orderedWindows, frames).map { (window: $0.0, frame: $0.1) }, 0)
    }

    private func verticalOverlayLayout(for windows: [AutoTileWindow],
                                       in screenVisibleFrame: CGRect,
                                       primaryFraction: CGFloat,
                                       tileDirection: AutoTileDirection) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        let splitFrames = splitPrimaryFrames(in: screenVisibleFrame,
                                             primaryFraction: primaryFraction,
                                             direction: .vertical,
                                             tileDirection: tileDirection)
        let horizontalOverlayFrames = splitPrimaryFrames(in: screenVisibleFrame,
                                                         primaryFraction: 0.5,
                                                         direction: .horizontal,
                                                         tileDirection: tileDirection)
        let centeredVerticalOverlayFrame = roundedFrame(CGRect(x: screenVisibleFrame.minX,
                                                               y: screenVisibleFrame.minY + (screenVisibleFrame.height * 0.25),
                                                               width: screenVisibleFrame.width,
                                                               height: screenVisibleFrame.height * 0.5))
        let overflowWindows = Array(windows.dropFirst(3))
        let overflowFrames: [CGRect]

        switch overflowWindows.count {
        case 0:
            overflowFrames = []
        case 1:
            overflowFrames = [horizontalOverlayFrames.originalFrame]
        case 2:
            overflowFrames = [horizontalOverlayFrames.originalFrame, horizontalOverlayFrames.remainingFrame]
        default:
            overflowFrames = autoTileFrames(count: overflowWindows.count,
                                            in: screenVisibleFrame,
                                            maximumColumnCount: overflowWindows.count,
                                            tileDirection: tileDirection)
        }

        let assignments = windows.enumerated().map { index, window in
            switch index {
            case 0:
                return (window: window, frame: splitFrames.originalFrame)
            case 1:
                return (window: window, frame: splitFrames.remainingFrame)
            case 2:
                return (window: window, frame: centeredVerticalOverlayFrame)
            default:
                return (window: window, frame: overflowFrames[index - 3])
            }
        }

        return (assignments, 0)
    }

    private func usesFirstWindowPriorityLayout(layoutMode: AutoTileLayoutMode,
                                               screenLayoutMode: AutoTileScreenLayoutMode,
                                               windowCount: Int,
                                               maximumColumnCount: Int) -> Bool {
        guard layoutMode == .sharedGrid,
              screenLayoutMode.prioritizesFirstWindow else {
            return false
        }

        return windowCount <= Self.normalizedMaximumAutoTileColumns(maximumColumnCount)
    }

    private func primaryBaseLayout(for windows: [AutoTileWindow],
                                   in screenVisibleFrame: CGRect,
                                   layoutMode: AutoTileLayoutMode,
                                   reservedSlotBundleIdentifiers: [String],
                                   screenLayoutMode: AutoTileScreenLayoutMode,
                                   maximumColumnCount: Int,
                                   tileDirection: AutoTileDirection,
                                   ignoresSecondAppInList: Bool,
                                   ignoredSecondWindowStartMode: AutoTileIgnoredSecondWindowStartMode) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        if usesFirstWindowPriorityLayout(layoutMode: layoutMode,
                                         screenLayoutMode: screenLayoutMode,
                                         windowCount: windows.count,
                                         maximumColumnCount: maximumColumnCount) {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if layoutMode == .sharedGrid,
           windows.count == 2,
           screenLayoutMode != .fullScreen,
           tileDirection != .centerOut {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if layoutMode == .sharedGrid,
           screenLayoutMode.splitDirection == .vertical {
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: screenLayoutMode.primaryFraction,
                                             splitDirection: screenLayoutMode.splitDirection,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }

        if ignoredSecondWindowStartMode == .middleStart {
            let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
            let tiledWindows = Array(windows.prefix(maximumWindowCount))
            let skippedWindowCount = max(0, windows.count - tiledWindows.count)

            return (middleStartGridAssignments(for: tiledWindows,
                                               in: screenVisibleFrame,
                                               maximumColumnCount: maximumColumnCount,
                                               tileDirection: tileDirection,
                                               reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers),
                    skippedWindowCount)
        }

        switch layoutMode {
        case .sharedGrid:
            let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
            let tiledWindows = Array(windows.prefix(maximumWindowCount))
            let skippedWindowCount = max(0, windows.count - tiledWindows.count)
            let assignments: [(window: AutoTileWindow, frame: CGRect)]

            if ignoresSecondAppInList,
               ignoredSecondWindowStartMode == .normalStart {
                assignments = fullScreenGridAssignmentsIgnoringSecondWindow(for: tiledWindows,
                                                                            in: screenVisibleFrame,
                                                                            maximumColumnCount: maximumColumnCount,
                                                                            tileDirection: tileDirection,
                                                                            reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers)
            } else {
                assignments = autoTileAssignments(for: tiledWindows,
                                                  in: screenVisibleFrame,
                                                  maximumColumnCount: maximumColumnCount,
                                                  tileDirection: tileDirection,
                                                  reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers)
            }

            return (assignments, skippedWindowCount)
        case .splitOriginal:
            return firstWindowPriorityLayout(for: windows,
                                             in: screenVisibleFrame,
                                             primaryFraction: 0.5,
                                             splitDirection: .horizontal,
                                             maximumColumnCount: maximumColumnCount,
                                             tileDirection: tileDirection,
                                             ignoresSecondAppInList: ignoresSecondAppInList,
                                             ignoredSecondWindowStartMode: ignoredSecondWindowStartMode)
        }
    }

    private func windowSortKey(_ window: AutoTileWindow) -> String {
        "\(window.processIdentifier)-\(window.id.elementHash)"
    }

    private func windowSpatialSort(_ lhs: AutoTileWindow, _ rhs: AutoTileWindow) -> Bool {
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

    private func positionPreservingPrimaryLayout(for windows: [AutoTileWindow],
                                                 in screenVisibleFrame: CGRect,
                                                 primaryWindowID: AutoTileWindowID,
                                                 primaryWidthFraction: CGFloat,
                                                 primaryWindowSlot: Int?,
                                                 maximumColumnCount: Int,
                                                 tileDirection: AutoTileDirection) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        guard let primaryIndex = windows.firstIndex(where: { $0.id == primaryWindowID }) else {
            return ([], windows.count)
        }

        let selectedWindows = positionPreservingPrimaryWindows(from: windows,
                                                               primaryIndex: primaryIndex,
                                                               maximumColumnCount: maximumColumnCount)
        let skippedWindowCount = max(0, windows.count - selectedWindows.count)

        guard let selectedPrimaryIndex = selectedWindows.firstIndex(where: { $0.id == primaryWindowID }) else {
            return ([], skippedWindowCount)
        }

        let primaryWindow = selectedWindows[selectedPrimaryIndex]
        let primaryWidth = screenVisibleFrame.width * primaryWidthFraction
        let primaryCenterX = primaryWindowSlotCenterX(slot: primaryWindowSlot,
                                                      windowCount: selectedWindows.count,
                                                      fallback: primaryWindow.frame.midX,
                                                      in: screenVisibleFrame,
                                                      tileDirection: tileDirection)
        let primaryX = min(max(primaryCenterX - (primaryWidth / 2), screenVisibleFrame.minX),
                           screenVisibleFrame.maxX - primaryWidth)
        let primaryFrame = roundedFrame(CGRect(x: primaryX,
                                               y: screenVisibleFrame.minY,
                                               width: primaryWidth,
                                               height: screenVisibleFrame.height))
        let leadingFrame = roundedFrame(CGRect(x: screenVisibleFrame.minX,
                                               y: screenVisibleFrame.minY,
                                               width: max(0, primaryFrame.minX - screenVisibleFrame.minX),
                                               height: screenVisibleFrame.height))
        let trailingFrame = roundedFrame(CGRect(x: primaryFrame.maxX,
                                                y: screenVisibleFrame.minY,
                                                width: max(0, screenVisibleFrame.maxX - primaryFrame.maxX),
                                                height: screenVisibleFrame.height))
        let leadingWindows = Array(selectedWindows[..<selectedPrimaryIndex])
        let trailingWindows = Array(selectedWindows.dropFirst(selectedPrimaryIndex + 1))
        let leadingAssignments = sideAssignments(for: leadingWindows,
                                                 in: leadingFrame,
                                                 maximumColumnCount: maximumColumnCount,
                                                 tileDirection: tileDirection)
        let trailingAssignments = sideAssignments(for: trailingWindows,
                                                  in: trailingFrame,
                                                  maximumColumnCount: maximumColumnCount,
                                                  tileDirection: tileDirection)

        return (leadingAssignments + [(window: primaryWindow, frame: primaryFrame)] + trailingAssignments,
                skippedWindowCount)
    }

    private func primaryWindowSlotCenterX(slot: Int?,
                                          windowCount: Int,
                                          fallback: CGFloat,
                                          in screenVisibleFrame: CGRect,
                                          tileDirection: AutoTileDirection) -> CGFloat {
        guard let slot,
              windowCount > 0 else {
            return fallback
        }

        let clampedSlot = min(max(slot, 0), windowCount - 1)
        let slotWidth = screenVisibleFrame.width / CGFloat(windowCount)
        switch tileDirection {
        case .leftToRight, .centerOut:
            return screenVisibleFrame.minX + (CGFloat(clampedSlot) + 0.5) * slotWidth
        case .rightToLeft:
            return screenVisibleFrame.maxX - (CGFloat(clampedSlot) + 0.5) * slotWidth
        }
    }

    private func positionPreservingPrimaryWindows(from windows: [AutoTileWindow],
                                                  primaryIndex: Int,
                                                  maximumColumnCount: Int) -> [AutoTileWindow] {
        let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
        guard windows.count > maximumWindowCount else {
            return windows
        }

        var selectedIndices = Set([primaryIndex])

        for index in windows.indices where index != primaryIndex {
            guard selectedIndices.count < maximumWindowCount else {
                break
            }

            selectedIndices.insert(index)
        }

        return windows.indices
            .filter { selectedIndices.contains($0) }
            .map { windows[$0] }
    }

    private func visuallyWeightedPrimaryLayout(primaryWindowID: AutoTileWindowID,
                                               primaryTwoWindowWidthFraction: CGFloat,
                                               baseAssignments: [(window: AutoTileWindow, frame: CGRect)],
                                               skippedWindowCount: Int) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        guard baseAssignments.contains(where: { $0.window.id == primaryWindowID }) else {
            return (baseAssignments, skippedWindowCount)
        }

        let primaryWeight = max(1.0, primaryTwoWindowWidthFraction / max(0.01, 1.0 - primaryTwoWindowWidthFraction))
        let rows = visualRows(from: baseAssignments)
        let assignments = rows.flatMap { row -> [(window: AutoTileWindow, frame: CGRect)] in
            guard row.contains(where: { $0.window.id == primaryWindowID }) else {
                return row
            }

            return weightedRowAssignments(for: row,
                                          primaryWindowID: primaryWindowID,
                                          primaryWeight: primaryWeight)
        }

        return (assignments, skippedWindowCount)
    }

    private func visualRows(from assignments: [(window: AutoTileWindow, frame: CGRect)]) -> [[(window: AutoTileWindow, frame: CGRect)]] {
        assignments
            .sorted(by: assignmentVisualSort)
            .reduce(into: [[(window: AutoTileWindow, frame: CGRect)]]()) { rows, assignment in
                if let rowIndex = rows.firstIndex(where: { row in
                    guard let rowFrame = row.first?.frame else {
                        return false
                    }

                    return framesShareVisualRow(assignment.frame, rowFrame)
                }) {
                    rows[rowIndex].append(assignment)
                    rows[rowIndex].sort(by: assignmentHorizontalSort)
                } else {
                    rows.append([assignment])
                }
            }
    }

    private func weightedRowAssignments(for row: [(window: AutoTileWindow, frame: CGRect)],
                                        primaryWindowID: AutoTileWindowID,
                                        primaryWeight: CGFloat) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard row.count > 1,
              let minX = row.map({ $0.frame.minX }).min(),
              let maxX = row.map({ $0.frame.maxX }).max(),
              let minY = row.map({ $0.frame.minY }).min(),
              let maxY = row.map({ $0.frame.maxY }).max() else {
            return row
        }

        let rowWidth = max(0, maxX - minX)
        let rowHeight = max(0, maxY - minY)
        let nonPrimaryCount = max(0, row.count - 1)
        let totalWeight = primaryWeight + CGFloat(nonPrimaryCount)
        let maximumPrimaryWidth = max(1, rowWidth - Self.minimumAutoTileWindowWidth * CGFloat(nonPrimaryCount))
        let desiredPrimaryWidth = rowWidth * (primaryWeight / totalWeight)
        let primaryWidth = min(desiredPrimaryWidth, maximumPrimaryWidth)
        let nonPrimaryWidth = nonPrimaryCount > 0 ?
            max(1, (rowWidth - primaryWidth) / CGFloat(nonPrimaryCount)) :
            rowWidth
        var x = minX

        return row.enumerated().map { index, assignment in
            let isLast = index == row.count - 1
            let width = assignment.window.id == primaryWindowID ? primaryWidth : nonPrimaryWidth
            let nextX = isLast ? maxX : x + width
            let frame = roundedFrame(CGRect(x: x,
                                            y: minY,
                                            width: max(0, nextX - x),
                                            height: rowHeight))
            x = nextX

            return (window: assignment.window, frame: frame)
        }
    }

    private func assignmentVisualSort(_ lhs: (window: AutoTileWindow, frame: CGRect),
                                      _ rhs: (window: AutoTileWindow, frame: CGRect)) -> Bool {
        if abs(lhs.frame.minY - rhs.frame.minY) > 8 {
            return lhs.frame.minY < rhs.frame.minY
        }

        return assignmentHorizontalSort(lhs, rhs)
    }

    private func assignmentHorizontalSort(_ lhs: (window: AutoTileWindow, frame: CGRect),
                                          _ rhs: (window: AutoTileWindow, frame: CGRect)) -> Bool {
        if abs(lhs.frame.minX - rhs.frame.minX) > 8 {
            return lhs.frame.minX < rhs.frame.minX
        }

        return windowSortKey(lhs.window) < windowSortKey(rhs.window)
    }

    private func framesShareVisualRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minY - rhs.minY) <= 8 &&
            abs(lhs.height - rhs.height) <= 8
    }

    private func sideAssignments(for windows: [AutoTileWindow],
                                 in availableFrame: CGRect,
                                 maximumColumnCount: Int,
                                 tileDirection: AutoTileDirection) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard !windows.isEmpty,
              availableFrame.width >= 1,
              availableFrame.height >= 1 else {
            return []
        }

        return autoTileAssignments(for: windows,
                                   in: availableFrame,
                                   maximumColumnCount: maximumColumnCount,
                                   tileDirection: tileDirection,
                                   reservedSlotBundleIdentifiers: [])
    }

    private func firstWindowPriorityLayout(for windows: [AutoTileWindow],
                                           in screenVisibleFrame: CGRect,
                                           primaryFraction: CGFloat,
                                           splitDirection: AutoTileSplitDirection,
                                           maximumColumnCount: Int,
                                           tileDirection: AutoTileDirection,
                                           ignoresSecondAppInList: Bool,
                                           ignoredSecondWindowStartMode: AutoTileIgnoredSecondWindowStartMode) -> (assignments: [(window: AutoTileWindow, frame: CGRect)], skippedWindowCount: Int) {
        guard let originalWindow = windows.first else {
            return ([], 0)
        }

        let maximumWindowCount = Self.maximumAutoTileWindows(for: maximumColumnCount)
        let otherWindows = Array(windows.dropFirst().prefix(maximumWindowCount))
        let skippedWindowCount = max(0, windows.dropFirst().count - otherWindows.count)
        let splitFrames = splitPrimaryFrames(in: screenVisibleFrame,
                                             primaryFraction: primaryFraction,
                                             direction: splitDirection,
                                             tileDirection: tileDirection)
        if splitFrames.remainingFrame.width < 1 ||
           splitFrames.remainingFrame.height < 1 {
            return ([(window: originalWindow, frame: splitFrames.originalFrame)],
                    windows.count - 1)
        }

        let assignments: [(window: AutoTileWindow, frame: CGRect)]

        if ignoresSecondAppInList,
           ignoredSecondWindowStartMode == .normalStart,
           let secondWindow = otherWindows.first {
            let secondWindowFrame = autoTileFrames(count: 1,
                                                   in: splitFrames.remainingFrame,
                                                   maximumColumnCount: maximumColumnCount,
                                                   tileDirection: tileDirection).first ?? splitFrames.remainingFrame
            let remainingWindows = Array(otherWindows.dropFirst())
            assignments = [(window: secondWindow, frame: secondWindowFrame),
                           (window: originalWindow, frame: splitFrames.originalFrame)] +
                normalStartTrailingAssignments(for: remainingWindows,
                                               in: splitFrames.remainingFrame,
                                               maximumColumnCount: maximumColumnCount,
                                               tileDirection: tileDirection,
                                               reverseFrameOrderFromCount: 2)
        } else {
            assignments = [(window: originalWindow, frame: splitFrames.originalFrame)] +
                normalStartTrailingAssignments(for: otherWindows,
                                               in: splitFrames.remainingFrame,
                                               maximumColumnCount: maximumColumnCount,
                                               tileDirection: tileDirection,
                                               reverseFrameOrderFromCount: 3)
        }

        return (assignments, skippedWindowCount)
    }

    private func normalStartTrailingAssignments(for windows: [AutoTileWindow],
                                                in availableFrame: CGRect,
                                                maximumColumnCount: Int,
                                                tileDirection: AutoTileDirection,
                                                reverseFrameOrderFromCount: Int) -> [(window: AutoTileWindow, frame: CGRect)] {
        var frames = autoTileFrames(count: windows.count,
                                    in: availableFrame,
                                    maximumColumnCount: maximumColumnCount,
                                    tileDirection: tileDirection)

        if windows.count >= reverseFrameOrderFromCount {
            frames.sort { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > 8 {
                    return lhs.minY < rhs.minY
                }

                return lhs.minX > rhs.minX
            }
        }

        return zip(windows, frames).map { (window: $0.0, frame: $0.1) }
    }

    private func autoTileAssignments(for windows: [AutoTileWindow],
                                     in availableFrame: CGRect,
                                     maximumColumnCount: Int,
                                     tileDirection: AutoTileDirection,
                                     reservedSlotBundleIdentifiers: [String] = []) -> [(window: AutoTileWindow, frame: CGRect)] {
        let frameCount = max(windows.count, reservedSlotBundleIdentifiers.count)
        let frames = autoTileFrames(count: frameCount,
                                    in: availableFrame,
                                    maximumColumnCount: maximumColumnCount,
                                    tileDirection: tileDirection)
        var usedFrameIndices: Set<Int> = []
        var assignments: [(window: AutoTileWindow, frame: CGRect)] = []

        for window in windows {
            if let reservedSlot = reservedSlotBundleIdentifiers.firstIndex(of: window.bundleIdentifier),
               frames.indices.contains(reservedSlot),
               usedFrameIndices.insert(reservedSlot).inserted {
                assignments.append((window: window, frame: frames[reservedSlot]))
                continue
            }

            guard let frameIndex = frames.indices.first(where: { !usedFrameIndices.contains($0) }) else {
                continue
            }

            usedFrameIndices.insert(frameIndex)
            assignments.append((window: window, frame: frames[frameIndex]))
        }

        return assignments
    }

    private func fullScreenGridAssignmentsIgnoringSecondWindow(for windows: [AutoTileWindow],
                                                               in screenVisibleFrame: CGRect,
                                                               maximumColumnCount: Int,
                                                               tileDirection: AutoTileDirection,
                                                               reservedSlotBundleIdentifiers: [String]) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard let originalWindow = windows.first else {
            return []
        }

        let splitFrames = splitOriginalFrames(in: screenVisibleFrame,
                                              primaryWidthFraction: 0.5,
                                              tileDirection: tileDirection)
        let ignoredWindowAssignments = windows.dropFirst().prefix(1).map { window in
            (window: window, frame: splitFrames.remainingFrame)
        }
        let gridWindows = [originalWindow] + Array(windows.dropFirst(2))
        var gridFrames = autoTileFrames(count: max(gridWindows.count, reservedSlotBundleIdentifiers.count),
                                        in: screenVisibleFrame,
                                        maximumColumnCount: maximumColumnCount,
                                        tileDirection: tileDirection)
        if !gridFrames.isEmpty {
            gridFrames.removeFirst()
        }
        let trailingFrames = gridFrames.sorted { lhs, rhs in
            if abs(lhs.minY - rhs.minY) > 8 {
                return lhs.minY < rhs.minY
            }

            return lhs.minX > rhs.minX
        }
        let gridAssignments = [(window: originalWindow, frame: splitFrames.originalFrame)] +
            zip(gridWindows.dropFirst(), trailingFrames).map { (window: $0.0, frame: $0.1) }

        return ignoredWindowAssignments +
            gridAssignments
    }

    private func middleStartGridAssignments(for windows: [AutoTileWindow],
                                            in screenVisibleFrame: CGRect,
                                            maximumColumnCount: Int,
                                            tileDirection: AutoTileDirection,
                                            reservedSlotBundleIdentifiers: [String]) -> [(window: AutoTileWindow, frame: CGRect)] {
        guard let originalWindow = windows.first else {
            return []
        }

        guard windows.count > 2 else {
            let splitFrames = splitOriginalFrames(in: screenVisibleFrame,
                                                  primaryWidthFraction: 0.5,
                                                  tileDirection: tileDirection)
            let secondWindowAssignments = windows.dropFirst().map { window in
                (window: window, frame: splitFrames.remainingFrame)
            }

            return [(window: originalWindow, frame: splitFrames.originalFrame)] + secondWindowAssignments
        }

        let middleWindows = Array(windows.dropFirst(2)).reversed()
        let orderedWindows = [originalWindow] + middleWindows + [windows[1]]

        return autoTileAssignments(for: orderedWindows,
                                   in: screenVisibleFrame,
                                   maximumColumnCount: maximumColumnCount,
                                   tileDirection: tileDirection,
                                   reservedSlotBundleIdentifiers: reservedSlotBundleIdentifiers)
    }

    private func splitOriginalFrames(in availableFrame: CGRect,
                                     primaryWidthFraction: CGFloat,
                                     tileDirection: AutoTileDirection) -> (originalFrame: CGRect, remainingFrame: CGRect) {
        splitPrimaryFrames(in: availableFrame,
                           primaryFraction: primaryWidthFraction,
                           direction: .horizontal,
                           tileDirection: tileDirection)
    }

    private func splitPrimaryFrames(in availableFrame: CGRect,
                                    primaryFraction: CGFloat,
                                    direction: AutoTileSplitDirection,
                                    tileDirection: AutoTileDirection) -> (originalFrame: CGRect, remainingFrame: CGRect) {
        switch direction {
        case .horizontal:
            let primaryWidth = availableFrame.width * primaryFraction
            let remainingWidth = availableFrame.width - primaryWidth
            let primaryX: CGFloat
            let remainingX: CGFloat

            switch tileDirection {
            case .leftToRight, .centerOut:
                primaryX = availableFrame.minX
                remainingX = availableFrame.minX + primaryWidth
            case .rightToLeft:
                primaryX = availableFrame.maxX - primaryWidth
                remainingX = availableFrame.minX
            }

            let originalFrame = CGRect(x: primaryX,
                                       y: availableFrame.minY,
                                       width: primaryWidth,
                                       height: availableFrame.height)
            let remainingFrame = CGRect(x: remainingX,
                                        y: availableFrame.minY,
                                        width: remainingWidth,
                                        height: availableFrame.height)

            return (roundedFrame(originalFrame), roundedFrame(remainingFrame))
        case .vertical:
            let primaryHeight = availableFrame.height * primaryFraction
            let remainingHeight = availableFrame.height - primaryHeight

            let originalFrame = CGRect(x: availableFrame.minX,
                                       y: availableFrame.minY,
                                       width: availableFrame.width,
                                       height: primaryHeight)
            let remainingFrame = CGRect(x: availableFrame.minX,
                                        y: availableFrame.minY + primaryHeight,
                                        width: availableFrame.width,
                                        height: remainingHeight)

            return (roundedFrame(originalFrame), roundedFrame(remainingFrame))
        }
    }

    private func singleWindowStartFrame(in availableFrame: CGRect,
                                        tileDirection: AutoTileDirection = .leftToRight,
                                        maximumColumnCount: Int = 3) -> CGRect {
        switch tileDirection {
        case .leftToRight, .rightToLeft:
            return splitOriginalFrames(in: availableFrame,
                                       primaryWidthFraction: 0.5,
                                       tileDirection: tileDirection).originalFrame
        case .centerOut:
            return autoTileFrames(count: 1,
                                  in: availableFrame,
                                  maximumColumnCount: maximumColumnCount,
                                  tileDirection: tileDirection).first ?? roundedFrame(availableFrame)
        }
    }

    private static func isBrowserBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        browserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func normalizedMaximumAutoTileColumns(_ maximumColumnCount: Int) -> Int {
        min(max(maximumColumnCount, 1), supportedMaximumAutoTileColumns)
    }

    private static func maximumAutoTileWindows(for maximumColumnCount: Int) -> Int {
        maximumAutoTileRows * normalizedMaximumAutoTileColumns(maximumColumnCount)
    }

    private func autoTileFrames(count: Int,
                                in availableFrame: CGRect,
                                maximumColumnCount: Int = 3,
                                tileDirection: AutoTileDirection = .leftToRight) -> [CGRect] {
        guard count > 0 else {
            return []
        }

        let normalizedMaximumColumnCount = Self.normalizedMaximumAutoTileColumns(maximumColumnCount)
        let effectiveMaximumColumnCount = tileDirection == .centerOut ?
            max(normalizedMaximumColumnCount, 3) :
            normalizedMaximumColumnCount
        let limitedCount = min(count, Self.maximumAutoTileWindows(for: normalizedMaximumColumnCount))
        let preferredCenterColumnCount = min(3, effectiveMaximumColumnCount)
        let columnCount = tileDirection == .centerOut ?
            min(max(limitedCount, preferredCenterColumnCount), effectiveMaximumColumnCount) :
            min(limitedCount, effectiveMaximumColumnCount)
        let rowCount = Int(ceil(Double(limitedCount) / Double(columnCount)))
        let xEdges = partitionEdges(from: availableFrame.minX,
                                    to: availableFrame.maxX,
                                    count: columnCount)
        let yEdges = partitionEdges(from: availableFrame.minY,
                                    to: availableFrame.maxY,
                                    count: rowCount)
        var frames: [CGRect] = []

        let columnIndices: [Int]
        switch tileDirection {
        case .leftToRight:
            columnIndices = Array(0..<columnCount)
        case .centerOut:
            columnIndices = centerOutColumnIndices(count: columnCount)
        case .rightToLeft:
            columnIndices = Array((0..<columnCount).reversed())
        }

        for rowIndex in 0..<rowCount {
            for columnIndex in columnIndices {
                guard frames.count < limitedCount else {
                    break
                }

                frames.append(CGRect(x: xEdges[columnIndex],
                                     y: yEdges[rowIndex],
                                     width: max(0, xEdges[columnIndex + 1] - xEdges[columnIndex]),
                                     height: max(0, yEdges[rowIndex + 1] - yEdges[rowIndex])))
            }
        }

        return frames
    }

    private func centerOutColumnIndices(count: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        let centerIndex = (count - 1) / 2
        var indices = [centerIndex]
        var offset = 1

        while indices.count < count {
            let rightIndex = centerIndex + offset
            if rightIndex < count {
                indices.append(rightIndex)
            }

            let leftIndex = centerIndex - offset
            if leftIndex >= 0 {
                indices.append(leftIndex)
            }

            offset += 1
        }

        return indices
    }

    private func roundedFrame(_ frame: CGRect) -> CGRect {
        let minX = frame.minX.rounded(.toNearestOrAwayFromZero)
        let minY = frame.minY.rounded(.toNearestOrAwayFromZero)
        let maxX = frame.maxX.rounded(.toNearestOrAwayFromZero)
        let maxY = frame.maxY.rounded(.toNearestOrAwayFromZero)

        return CGRect(x: minX,
                      y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    private func partitionEdges(from start: CGFloat, to end: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else {
            return []
        }

        let size = end - start
        return (0...count).map { index in
            if index == 0 {
                return start.rounded(.toNearestOrAwayFromZero)
            }

            if index == count {
                return end.rounded(.toNearestOrAwayFromZero)
            }

            return (start + size * (CGFloat(index) / CGFloat(count))).rounded(.toNearestOrAwayFromZero)
        }
    }
}

private struct ScreenGeometry {
    let frame: CGRect
    let visibleFrame: CGRect
}

private struct ScreenKey: Hashable {
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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}

private extension AXError {
    var readableName: String {
        switch self {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegal argument"
        case .invalidUIElement: "invalid UI element"
        case .invalidUIElementObserver: "invalid UI element observer"
        case .cannotComplete: "cannot complete"
        case .attributeUnsupported: "attribute unsupported"
        case .actionUnsupported: "action unsupported"
        case .notificationUnsupported: "notification unsupported"
        case .notImplemented: "not implemented"
        case .notificationAlreadyRegistered: "notification already registered"
        case .notificationNotRegistered: "notification not registered"
        case .apiDisabled: "API disabled"
        case .noValue: "no value"
        case .parameterizedAttributeUnsupported: "parameterized attribute unsupported"
        case .notEnoughPrecision: "not enough precision"
        @unknown default: "unknown error"
        }
    }
}
