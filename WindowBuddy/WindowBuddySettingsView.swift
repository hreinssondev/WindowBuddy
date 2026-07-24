import AppKit
import SwiftUI

private enum WindowBuddySidebarSelection: Hashable {
    case general
    case tiling
    case focusKeys
    case focusGroup(Int)
}

struct WindowBuddySettingsView: View {
    @ObservedObject var model: WindowBuddyModel
    @State private var didPositionWindow = false
    @State private var appPickerGroup: AutoTileAppGroup?
    @State private var sidebarSelection: WindowBuddySidebarSelection? = .general
    @State private var focusGroupsExpanded = true
    @State private var didChooseInitialSelection = false

    var body: some View {
        VStack(spacing: 0) {
            settingsShortcutBar

            Divider()

            splitView
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private var settingsShortcutBar: some View {
        HStack(spacing: 8) {
            Text("Open this window shortcut")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            ShortcutRecorder(shortcut: model.settingsShortcut) { shortcut in
                model.setSettingsShortcut(shortcut)
            }
            .frame(width: 184, height: 32)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .help("Click, press shortcut, then press Enter to save")
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            WindowAccessor { window in
                positionWindowIfNeeded(window)
            }
        }
        .onAppear {
            model.start()
            chooseInitialSidebarSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccessibilityStatus()
        }
        .onChange(of: model.visibleAutoTileAppGroups.map(\.id)) { _, _ in
            ensureValidSidebarSelection()
        }
        .sheet(item: $appPickerGroup) { group in
            AutoTileAppPickerSheet(group: group,
                                   availableApps: model.availableAutoTileApps,
                                   isLoading: model.isLoadingAvailableAutoTileApps,
                                   add: { apps in
                                       model.addAutoTileApps(apps, in: group)
                                       sidebarSelection = .focusGroup(group.id)
                                       appPickerGroup = nil
                                   },
                                   browse: {
                                       appPickerGroup = nil

                                       DispatchQueue.main.async {
                                           model.browseAutoTileApps(in: group)
                                       }
                                   },
                                   cancel: {
                                       appPickerGroup = nil
                                   })
                .onAppear {
                    model.loadAvailableAutoTileAppsIfNeeded()
                }
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Label("General", systemImage: "gearshape")
                .tag(WindowBuddySidebarSelection.general)

            Label("Tiling", systemImage: "square.grid.3x3")
                .tag(WindowBuddySidebarSelection.tiling)

            Label("Focus Keys", systemImage: "keyboard")
                .tag(WindowBuddySidebarSelection.focusKeys)

            DisclosureGroup(isExpanded: $focusGroupsExpanded) {
                ForEach(model.visibleAutoTileAppGroups) { group in
                    FocusGroupSidebarRow(group: group)
                        .tag(WindowBuddySidebarSelection.focusGroup(group.id))
                        .contextMenu {
                            Button(role: .destructive) {
                                clearFocusGroup(group)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }

                if model.canAddAutoTileGroup {
                    Button(action: addFocusGroup) {
                        Label("Add Focus Group", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Label("Focus Groups", systemImage: "rectangle.3.group")
                    .fontWeight(.medium)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("WindowBuddy Settings")
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sidebarSelection ?? .general {
        case .general:
            generalDetail
        case .tiling:
            tilingDetail
        case .focusKeys:
            focusKeysDetail
        case let .focusGroup(groupIdentifier):
            if let group = model.visibleAutoTileAppGroups.first(where: { $0.id == groupIdentifier }) {
                focusGroupDetail(group)
            } else {
                unavailableFocusGroupDetail
            }
        }
    }

    private var generalDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                InspectorHeading(title: "General",
                                 subtitle: "Choose how WindowBuddy behaves across macOS.",
                                 systemImage: "gearshape")

                if !model.accessibilityGranted {
                    accessSection
                }

                GroupBox {
                    VStack(spacing: 0) {
                        InspectorToggleRow(title: "Show Dock Icon",
                                           systemImage: "dock.rectangle",
                                           isOn: $model.showsDockIcon)

                        Divider()

                        InspectorToggleRow(title: "Hide Other Focus Groups",
                                           systemImage: "rectangle.stack.badge.minus",
                                           isOn: $model.focusGroupSwitchingHidesOthers)

                        Divider()

                        InspectorToggleRow(title: "Reveal Grouped Apps Together",
                                           systemImage: "rectangle.on.rectangle",
                                           isOn: $model.revealsActiveAutoTileGroupApps)

                        Divider()

                        switchInsteadOfHideRow

                        Divider()

                        switchTimingRow
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("Behavior", systemImage: "switch.2")
                        .font(.headline)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tilingDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                InspectorHeading(title: "Tiling",
                                 subtitle: "Control how focused windows resize while you work.",
                                 systemImage: "square.grid.3x3")

                tilingOptionsSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var focusKeysDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                InspectorHeading(title: "Focus Keys",
                                 subtitle: "Assign keys and tune how quickly focus groups cycle.",
                                 systemImage: "keyboard")

                focusGroupKeysSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func focusGroupDetail(_ group: AutoTileAppGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AutoTileGroupView(group: group,
                                  add: { appPickerGroup = group },
                                  setScreenLayoutMode: { screenLayoutMode in
                                      model.setScreenLayoutMode(screenLayoutMode, in: group)
                                  },
                                  setTileDirection: { tileDirection in
                                      model.setTileDirection(tileDirection, in: group)
                                  },
                                  setMaximumColumnCount: { maximumColumnCount in
                                      model.setMaximumColumnCount(maximumColumnCount, in: group)
                                  },
                                  setIgnoredSecondWindowStartMode: { startMode in
                                      model.setIgnoredSecondWindowStartMode(startMode, in: group)
                                  },
                                  focusedGroupNumber: model.focusedGroupNumber(in: group),
                                  setFocusedGroupNumber: { number in
                                      model.setFocusedGroupNumber(number, in: group)
                                  },
                                  setMainApp: { app, isMain in
                                      model.setAutoTileAppIsMain(isMain, app: app, in: group)
                                  },
                                  remove: { app in
                                      model.removeAutoTileApp(app, from: group)
                                      ensureValidSidebarSelection()
                                  })

                Button(role: .destructive) {
                    clearFocusGroup(group)
                } label: {
                    Label("Delete focus group", systemImage: "trash")
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var unavailableFocusGroupDetail: some View {
        ContentUnavailableView {
            Label("Focus Group Unavailable", systemImage: "rectangle.3.group")
        } description: {
            Text("Select another focus group from the sidebar.")
        }
    }

    private func positionWindowIfNeeded(_ window: NSWindow) {
        guard !didPositionWindow, let screen = window.screen ?? NSScreen.main else {
            return
        }

        didPositionWindow = true

        let visibleFrame = screen.visibleFrame
        let width = max(window.frame.width, 900)
        let frame = NSRect(x: visibleFrame.midX - width / 2,
                           y: visibleFrame.minY,
                           width: width,
                           height: visibleFrame.height)

        window.setFrame(frame, display: true)
    }

    private var tilingOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent {
                    Toggle("", isOn: $model.widensFocusedAutoTileWindow)
                        .labelsHidden()
                } label: {
                    Label("Focused Tile Widening", systemImage: "arrow.left.and.right")
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $model.focusedAutoTileWindowWidthFraction,
                               in: WindowBuddyModel.focusedAutoTileWindowWidthFractionRange,
                               step: 0.01)
                            .frame(width: 180)

                        Text(model.focusedAutoTileWindowWidthText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .disabled(!model.widensFocusedAutoTileWindow)
                } label: {
                    Label("Focused Width", systemImage: "arrow.left.and.right")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Focus Tile Wider Apps", systemImage: "arrow.left.and.right")
                        .font(.callout.weight(.medium))

                    FocusResizeListsView(resizableApps: model.focusTileWiderResizableAutoTileApps,
                                         fixedApps: model.focusTileWiderFixedAutoTileApps,
                                         setMode: model.setFocusTileWiderResizeMode)
                }

            }
            .padding(.top, 2)
        } label: {
            Label("Focused Windows", systemImage: "arrow.left.and.right")
                .font(.headline)
        }
    }

    private var focusGroupKeysSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("A single press cycles forward. Hold Command while pressing the same key to cycle backward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent {
                    FocusGroupPhysicalKeyRecorder(key: model.focusGroupOnePhysicalKey) { key in
                        let didSave = model.setFocusGroupPhysicalKey(key, number: 1)
                        if !didSave {
                            NSSound.beep()
                        }
                        return didSave
                    }
                    .frame(width: 240)
                } label: {
                    Label("Focus Key 1", systemImage: "1.circle")
                }

                LabeledContent {
                    FocusGroupPhysicalKeyRecorder(key: model.focusGroupTwoPhysicalKey) { key in
                        let didSave = model.setFocusGroupPhysicalKey(key, number: 2)
                        if !didSave {
                            NSSound.beep()
                        }
                        return didSave
                    }
                    .frame(width: 240)
                } label: {
                    Label("Focus Key 2", systemImage: "2.circle")
                }

                if let validationMessage = model.focusGroupPhysicalKeyValidationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("The selected physical keys are reserved globally while WindowBuddy runs. Each group needs a different key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button("Reset Defaults") {
                        model.resetFocusGroupPhysicalKeys()
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Global Keys", systemImage: "keyboard")
                .font(.headline)
        }
    }

    private var switchInsteadOfHideRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("Switch Instead of Hide", systemImage: "arrow.left.arrow.right")

                Spacer(minLength: 20)

                Toggle("", isOn: $model.switchesAwayFromSingleAppFocusGroups)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .focusable(false)
            }

            Text("When cycling would hide a focus group containing one app, switch to the other focused group instead. If no other focused group is running, hide and reveal remains the fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var switchTimingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("Delay Between Switches", systemImage: "timer")

                Spacer(minLength: 20)

                HStack(spacing: 10) {
                    Slider(value: $model.focusGroupSwitchDelay,
                           in: WindowBuddyModel.focusGroupSwitchDelayRange,
                           step: 0.01)
                        .frame(minWidth: 180)

                    Text(model.focusGroupSwitchDelayText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }

            Text("The first switch stays immediate. Rapid additional presses are queued and spaced by this delay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func addFocusGroup() {
        guard let group = model.addAutoTileGroup() else {
            return
        }

        focusGroupsExpanded = true
        sidebarSelection = .focusGroup(group.id)
        appPickerGroup = group
    }

    private func chooseInitialSidebarSelectionIfNeeded() {
        guard !didChooseInitialSelection else {
            return
        }

        didChooseInitialSelection = true
        if let firstGroup = model.visibleAutoTileAppGroups.first {
            sidebarSelection = .focusGroup(firstGroup.id)
        }
    }

    private func clearFocusGroup(_ group: AutoTileAppGroup) {
        model.clearAutoTileApps(in: group)
        ensureValidSidebarSelection()
    }

    private func ensureValidSidebarSelection() {
        guard case let .focusGroup(groupIdentifier) = sidebarSelection,
              !model.visibleAutoTileAppGroups.contains(where: { $0.id == groupIdentifier }) else {
            return
        }

        if let firstGroup = model.visibleAutoTileAppGroups.first {
            sidebarSelection = .focusGroup(firstGroup.id)
        } else {
            sidebarSelection = .general
        }
    }


    private var accessSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusLine(title: model.permissionStatusTitle,
                               systemImage: model.accessibilityGranted ? "checkmark.shield.fill" : "hand.raised.fill",
                               tint: model.accessibilityGranted ? .green : .orange)

                    Text(model.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        model.requestAccessibilityPermission()
                    } label: {
                        Label("Request", systemImage: "lock.open")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.openAccessibilitySettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Spacer()

                    Button {
                        model.refreshAccessibilityStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Check permission status")
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Accessibility", systemImage: "lock.shield")
                .font(.headline)
        }
    }
}

private struct FocusGroupSidebarRow: View {
    let group: AutoTileAppGroup

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .lineLimit(1)

                Text(group.apps.count == 1 ? "1 app" : "\(group.apps.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct InspectorHeading: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InspectorToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)

            Spacer(minLength: 20)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .focusable(false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct FocusResizeListsView: View {
    let resizableApps: [AutoTileAppSelection]
    let fixedApps: [AutoTileAppSelection]
    let setMode: (AutoTileFocusedResizeMode, AutoTileAppSelection) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FocusResizeColumn(title: AutoTileFocusedResizeMode.resizesWithFocus.title,
                              apps: resizableApps,
                              emptyTitle: "No apps",
                              actionSystemImage: "arrow.right",
                              actionHelp: "Keep same size on focus") { app in
                setMode(.keepsSizeOnFocus, app)
            }

            FocusResizeColumn(title: AutoTileFocusedResizeMode.keepsSizeOnFocus.title,
                              apps: fixedApps,
                              emptyTitle: "No apps",
                              actionSystemImage: "arrow.left",
                              actionHelp: "Resize bigger on focus") { app in
                setMode(.resizesWithFocus, app)
            }
        }
    }
}

private struct FocusResizeColumn: View {
    let title: String
    let apps: [AutoTileAppSelection]
    let emptyTitle: String
    let actionSystemImage: String
    let actionHelp: String
    let action: (AutoTileAppSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    if apps.isEmpty {
                        Text(emptyTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    } else {
                        ForEach(apps) { app in
                            FocusResizeAppRow(app: app,
                                              actionSystemImage: actionSystemImage,
                                              actionHelp: actionHelp,
                                              action: action)

                            if app.id != apps.last?.id {
                                Divider()
                                    .padding(.leading, 26)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 118, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FocusResizeAppRow: View {
    let app: AutoTileAppSelection
    let actionSystemImage: String
    let actionHelp: String
    let action: (AutoTileAppSelection) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }

            Text(app.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button {
                action(app)
            } label: {
                Image(systemName: actionSystemImage)
            }
            .buttonStyle(.borderless)
            .help(actionHelp)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }
}

private struct AutoTileGroupView: View {
    let group: AutoTileAppGroup
    let add: () -> Void
    let setScreenLayoutMode: (AutoTileScreenLayoutMode) -> Void
    let setTileDirection: (AutoTileDirection) -> Void
    let setMaximumColumnCount: (Int) -> Void
    let setIgnoredSecondWindowStartMode: (AutoTileIgnoredSecondWindowStartMode) -> Void
    let focusedGroupNumber: Int
    let setFocusedGroupNumber: (Int) -> Void
    let setMainApp: (AutoTileAppSelection, Bool) -> Void
    let remove: (AutoTileAppSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            appsSection

            autoTilingSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autoTilingSection: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
                    settingGridRow(title: "First Window",
                                   systemImage: "rectangle.split.2x1",
                                   help: "Choose how much of the display the first window uses.") {
                        PictogramSegmentedPicker(selection: Binding(
                            get: { group.screenLayoutMode },
                            set: setScreenLayoutMode
                        ), options: group.availableScreenLayoutModes,
                        title: { $0.title }) { option, isSelected in
                            ScreenLayoutPictogram(mode: option, isSelected: isSelected)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider()
                        .gridCellColumns(2)

                    settingGridRow(title: "Starting point",
                                   systemImage: "arrow.left.arrow.right",
                                   help: "Choose where this focus group begins tiling.") {
                        PictogramSegmentedPicker(selection: Binding(
                            get: { group.tileDirection },
                            set: setTileDirection
                        ), options: AutoTileDirection.allCases,
                        title: { $0.title }) { option, isSelected in
                            StartingSidePictogram(direction: option, isSelected: isSelected)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider()
                        .gridCellColumns(2)

                    settingGridRow(title: "Tiling direction",
                                   systemImage: "rectangle.split.2x1",
                                   help: "Choose which side receives the secondary window.") {
                        PictogramSegmentedPicker(selection: Binding(
                            get: { group.ignoredSecondWindowStartMode },
                            set: setIgnoredSecondWindowStartMode
                        ), options: AutoTileIgnoredSecondWindowStartMode.allCases,
                        title: { $0.title }) { option, isSelected in
                            SecondWindowSidePictogram(side: option, isSelected: isSelected)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider()
                        .gridCellColumns(2)

                    settingGridRow(title: "Focus key",
                                   systemImage: "scope",
                                   help: "Choose which focus-key set can cycle to this group.") {
                        Picker("Focus Group", selection: Binding(
                            get: { focusedGroupNumber },
                            set: setFocusedGroupNumber
                        )) {
                            Text("None").tag(0)
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("1+2").tag(3)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }

                    Divider()
                        .gridCellColumns(2)

                    settingGridRow(title: "Max Columns",
                                   systemImage: "rectangle.grid.3x2",
                                   help: "Choose the maximum number of columns before wrapping.") {
                        HStack {
                            Spacer()

                            Stepper(value: Binding(
                                get: { group.maximumColumnCount },
                                set: setMaximumColumnCount
                            ), in: WindowBuddyModel.maximumColumnCountRange) {
                                Text("\(group.maximumColumnCount)")
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 22, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 2)
            } label: {
                Label("Auto Tiling", systemImage: "rectangle.split.2x1")
                    .font(.headline)
            }
    }

    private var appsSection: some View {
        GroupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(group.apps.count == 1 ? "1 included app" : "\(group.apps.count) included apps")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(action: add) {
                            Label("Add App", systemImage: "plus")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    if !group.apps.isEmpty {
                        Divider()

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(group.apps) { app in
                                AutoTileAppRow(app: app,
                                               isMain: group.isMainApp(app),
                                               setMain: { isMain in
                                                   setMainApp(app, isMain)
                                               },
                                               remove: {
                                                   remove(app)
                                               })

                                if app.id != group.apps.last?.id {
                                    Divider()
                                        .padding(.leading, 48)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            } label: {
                Label("Apps", systemImage: "app.badge")
                    .font(.headline)
            }
    }

    private func settingGridRow<Control: View>(
        title: String,
        systemImage: String,
        help: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        GridRow {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

            control()
                .frame(maxWidth: .infinity)
                .padding(.trailing, 10)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .help(help)
    }
}

private struct PictogramSegmentedPicker<Option: Hashable, Pictogram: View>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    let pictogram: (Option, Bool) -> Pictogram

    init(
        selection: Binding<Option>,
        options: [Option],
        title: @escaping (Option) -> String,
        @ViewBuilder pictogram: @escaping (Option, Bool) -> Pictogram
    ) {
        _selection = selection
        self.options = options
        self.title = title
        self.pictogram = pictogram
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isSelected = selection == option

                Button {
                    selection = option
                } label: {
                    VStack(spacing: 4) {
                        pictogram(option, isSelected)

                        Text(title(option))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .padding(1)
                    }
                }
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                if index < options.count - 1 {
                    Divider()
                        .frame(height: 38)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.85), lineWidth: 1)
        }
    }
}

private struct ScreenLayoutPictogram: View {
    let mode: AutoTileScreenLayoutMode
    let isSelected: Bool

    private var tint: Color {
        isSelected ? .accentColor : Color(nsColor: .secondaryLabelColor)
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 2.5
            let innerWidth = max(0, geometry.size.width - inset * 2)
            let innerHeight = max(0, geometry.size.height - inset * 2)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(tint.opacity(0.9), lineWidth: 1.2)

                if mode == .verticalScreen {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.45 : 0.28))
                        .frame(width: innerWidth, height: innerHeight / 2)
                        .offset(x: inset, y: inset)

                    Rectangle()
                        .fill(tint.opacity(0.55))
                        .frame(width: innerWidth, height: 1)
                        .offset(x: inset, y: inset + innerHeight / 2)
                } else {
                    let activeWidth = innerWidth * mode.primaryFraction

                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.45 : 0.28))
                        .frame(width: activeWidth, height: innerHeight)
                        .offset(x: inset, y: inset)

                    if mode != .fullScreen {
                        Rectangle()
                            .fill(tint.opacity(0.55))
                            .frame(width: 1, height: innerHeight)
                            .offset(x: inset + activeWidth, y: inset)
                    }
                }
            }
        }
        .frame(width: 36, height: 22)
    }
}

private struct StartingSidePictogram: View {
    let direction: AutoTileDirection
    let isSelected: Bool

    private var tint: Color {
        isSelected ? .accentColor : Color(nsColor: .secondaryLabelColor)
    }

    private var highlightedIndex: Int {
        switch direction {
        case .leftToRight:
            0
        case .centerOut:
            1
        case .rightToLeft:
            2
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(tint.opacity(0.9), lineWidth: 1.2)

            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index == highlightedIndex ?
                              tint.opacity(isSelected ? 0.48 : 0.3) :
                              Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .stroke(tint.opacity(0.35), lineWidth: 0.8)
                        }
                }
            }
            .padding(3)
        }
        .frame(width: 36, height: 22)
    }
}

private struct SecondWindowSidePictogram: View {
    let side: AutoTileIgnoredSecondWindowStartMode
    let isSelected: Bool

    private var tint: Color {
        isSelected ? .accentColor : Color(nsColor: .secondaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 3) {
            if side == .middleStart {
                directionArrow(systemImage: "arrow.left")
            }

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint.opacity(isSelected ? 0.28 : 0.16))
                .frame(width: 20, height: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(tint.opacity(0.9), lineWidth: 1.1)
                }

            if side == .normalStart {
                directionArrow(systemImage: "arrow.right")
            }
        }
        .frame(width: 42, height: 22)
    }

    private func directionArrow(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
    }
}

private struct StatusLine: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
    }
}

private struct AutoTileAppPickerSheet: View {
    let group: AutoTileAppGroup
    let availableApps: [AutoTileAppSelection]
    let isLoading: Bool
    let add: ([AutoTileAppSelection]) -> Void
    let browse: () -> Void
    let cancel: () -> Void

    @State private var searchText = ""
    @State private var selectedBundleIdentifiers = Set<String>()

    private var existingBundleIdentifiers: Set<String> {
        Set(group.apps.map(\.bundleIdentifier))
    }

    private var filteredApps: [AutoTileAppSelection] {
        let selectableApps = availableApps.filter { !existingBundleIdentifiers.contains($0.bundleIdentifier) }

        guard !searchText.isEmpty else {
            return selectableApps
        }

        return selectableApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(searchText) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedApps: [AutoTileAppSelection] {
        availableApps.filter { selectedBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Add Apps to \(group.title)", systemImage: "app.badge")
                    .font(.headline)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)

            appList

            HStack(spacing: 8) {
                Button("Browse...", action: browse)

                Spacer()

                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button {
                    add(selectedApps)
                } label: {
                    Text(selectedBundleIdentifiers.isEmpty ? "Add" : "Add \(selectedBundleIdentifiers.count)")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBundleIdentifiers.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460, height: 520)
    }

    @ViewBuilder
    private var appList: some View {
        if filteredApps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: isLoading ? "app.badge" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)

                Text(isLoading ? "Loading apps..." : "No matching apps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredApps) { app in
                        AutoTileAppPickerRow(app: app,
                                             isSelected: selectedBundleIdentifiers.contains(app.bundleIdentifier)) {
                            toggle(app)
                        }

                        if app.id != filteredApps.last?.id {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55))
            }
        }
    }

    private func toggle(_ app: AutoTileAppSelection) {
        if selectedBundleIdentifiers.contains(app.bundleIdentifier) {
            selectedBundleIdentifiers.remove(app.bundleIdentifier)
        } else {
            selectedBundleIdentifiers.insert(app.bundleIdentifier)
        }
    }
}

private struct AutoTileAppPickerRow: View {
    let app: AutoTileAppSelection
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)

                appIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.callout)
                        .lineLimit(1)

                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 21))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowAvailable(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowAvailable(window)
            }
        }
    }
}

private struct AutoTileAppRow: View {
    let app: AutoTileAppSelection
    let isMain: Bool
    let setMain: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.callout)
                    .lineLimit(1)

                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                setMain(!isMain)
            } label: {
                Image(systemName: isMain ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(isMain ? "Main app" : "Make main app")

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(app.displayName)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var icon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

#Preview {
    WindowBuddySettingsView(model: WindowBuddyModel())
}
