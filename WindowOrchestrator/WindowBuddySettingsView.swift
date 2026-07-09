import AppKit
import SwiftUI

struct WindowBuddySettingsView: View {
    @ObservedObject var model: WindowBuddyModel
    @State private var didPositionWindow = false
    @State private var appPickerGroup: AutoTileAppGroup?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.accessibilityGranted {
                        accessSection
                    }

                    appearanceSection
                    tilingSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 680)
        .background {
            WindowAccessor { window in
                positionWindowIfNeeded(window)
            }
        }
        .onAppear {
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccessibilityStatus()
        }
        .sheet(item: $appPickerGroup) { group in
            AutoTileAppPickerSheet(group: group,
                                   availableApps: model.availableAutoTileApps,
                                   isLoading: model.isLoadingAvailableAutoTileApps,
                                   add: { apps in
                                       model.addAutoTileApps(apps, in: group)
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

    private func positionWindowIfNeeded(_ window: NSWindow) {
        guard !didPositionWindow, let screen = window.screen ?? NSScreen.main else {
            return
        }

        didPositionWindow = true

        let visibleFrame = screen.visibleFrame
        let width = max(window.frame.width, 680)
        let frame = NSRect(x: visibleFrame.midX - width / 2,
                           y: visibleFrame.minY,
                           width: width,
                           height: visibleFrame.height)

        window.setFrame(frame, display: true)
    }

    private var appearanceSection: some View {
        GroupBox {
            HStack(spacing: 22) {
                Toggle(isOn: $model.showsDockIcon) {
                    Label("Show Dock Icon", systemImage: "dock.rectangle")
                }
                .toggleStyle(.switch)
                .focusable(false)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tilingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            tilingOptionsSection
            autoTileAppsSection
        }
        .frame(maxWidth: .infinity)
    }

    private var tilingOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent {
                    Toggle("", isOn: $model.revealsActiveAutoTileGroupApps)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    Label("Hide/unhide apps in same group together", systemImage: "rectangle.on.rectangle")
                }

                LabeledContent {
                    Toggle("", isOn: $model.focusGroupSwitchingHidesOthers)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    Label("Focus group switching hides others", systemImage: "rectangle.stack.badge.minus")
                }

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
            Label("Tiling", systemImage: "square.grid.3x3")
                .font(.headline)
        }
    }

    private var autoTileAppsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(model.visibleAutoTileAppGroups) { group in
                        AutoTileGroupView(group: group,
                                          add: { appPickerGroup = group },
                                          clear: { model.clearAutoTileApps(in: group) },
                                          setScreenLayoutMode: { screenLayoutMode in
                                              model.setScreenLayoutMode(screenLayoutMode, in: group)
                                          },
                                          setTileDirection: { tileDirection in
                                              model.setTileDirection(tileDirection, in: group)
                                          },
                                          setMaximumColumnCount: { maximumColumnCount in
                                              model.setMaximumColumnCount(maximumColumnCount, in: group)
                                          },
                                          setIgnoresSecondAppInList: { ignoresSecondAppInList in
                                              model.setIgnoresSecondAppInList(ignoresSecondAppInList, in: group)
                                          },
                                          setFillsFirstWindow: { fillsFirstWindow in
                                              model.setFillsFirstWindow(fillsFirstWindow, in: group)
                                          },
                                          setMainApp: { app, isMain in
                                              model.setAutoTileAppIsMain(isMain, app: app, in: group)
                                          },
                                          setIgnoredSecondWindowStartMode: { startMode in
                                              model.setIgnoredSecondWindowStartMode(startMode, in: group)
                                          },
                                          isFocusGroup: model.isFocusGroup(group),
                                          setFocusGroup: { isFocusGroup in
                                              model.setFocusGroup(isFocusGroup, in: group)
                                          },
                                          remove: { app in
                                              model.removeAutoTileApp(app, from: group)
                                          })
                    }

                    if model.canAddAutoTileGroup {
                        Button {
                            appPickerGroup = model.addAutoTileGroup()
                        } label: {
                            Label("Add Group", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Add app group")
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Apps", systemImage: "app.badge")
                .font(.headline)
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
    let clear: () -> Void
    let setScreenLayoutMode: (AutoTileScreenLayoutMode) -> Void
    let setTileDirection: (AutoTileDirection) -> Void
    let setMaximumColumnCount: (Int) -> Void
    let setIgnoresSecondAppInList: (Bool) -> Void
    let setFillsFirstWindow: (Bool) -> Void
    let setMainApp: (AutoTileAppSelection, Bool) -> Void
    let setIgnoredSecondWindowStartMode: (AutoTileIgnoredSecondWindowStartMode) -> Void
    let isFocusGroup: Bool
    let setFocusGroup: (Bool) -> Void
    let remove: (AutoTileAppSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(group.title, systemImage: "rectangle.3.group")
                    .font(.callout.weight(.medium))

                Spacer()

                Button(action: clear) {
                    Image(systemName: "trash")
                }
                .help("Clear \(group.title)")
                .disabled(group.apps.isEmpty)
            }

            HStack(spacing: 8) {
                Label("Tile Layout", systemImage: "rectangle.split.2x1")

                Spacer()

                Picker("Tile Layout", selection: Binding(
                    get: { group.screenLayoutMode },
                    set: setScreenLayoutMode
                )) {
                    ForEach(group.availableScreenLayoutModes) { screenLayoutMode in
                        Text(screenLayoutMode.title)
                            .tag(screenLayoutMode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 370)
            }
            .font(.callout)
            .help("Choose whether this group tiles left to right or top to bottom.")

            HStack(spacing: 8) {
                Label("Tiling startingpoint", systemImage: "arrow.left.arrow.right")

                Spacer()

                Picker("Tiling startingpoint", selection: Binding(
                    get: { group.tileDirection },
                    set: setTileDirection
                )) {
                    ForEach(AutoTileDirection.allCases) { tileDirection in
                        Text(tileDirection.title)
                            .tag(tileDirection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 370)
            }
            .font(.callout)
            .help("Choose whether the first tile starts on the left or right side.")

            HStack(spacing: 8) {
                Label("Tiling direction", systemImage: "rectangle.split.2x1")

                Spacer()

                Picker("Tiling direction", selection: Binding(
                    get: { group.ignoredSecondWindowStartMode },
                    set: setIgnoredSecondWindowStartMode
                )) {
                    ForEach(AutoTileIgnoredSecondWindowStartMode.allCases) { startMode in
                        Text(startMode.title)
                            .tag(startMode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 370)
            }
            .font(.callout)
            .help("Normal Start keeps secondary tiles on the right and leaves window #2 behind them. Middle Start opens new apps in the middle. Focus Stack keeps every window visible as a thin clickable strip while the focused window gets the remaining width.")

            HStack(spacing: 8) {
                Label("Max Columns", systemImage: "rectangle.grid.3x2")

                Spacer()

                Stepper(value: Binding(
                    get: { group.maximumColumnCount },
                    set: setMaximumColumnCount
                ), in: WindowBuddyModel.maximumColumnCountRange) {
                    Text("\(group.maximumColumnCount)")
                        .font(.callout.monospacedDigit())
                        .frame(width: 18, alignment: .trailing)
                }
            }
            .font(.callout)
            .help("Choose the maximum number of columns this group can use before wrapping to another row.")

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { isFocusGroup },
                    set: setFocusGroup
                )) {
                    Label("Focused group", systemImage: "scope")
                }
                .toggleStyle(.switch)

                Spacer()

                Button(action: add) {
                    Image(systemName: "plus")
                }
                .offset(y: 10)
                .help("Add apps to \(group.title)")
            }

            if group.apps.isEmpty {
                Text("No apps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            } else {
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
                                .padding(.leading, 40)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
        }
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
