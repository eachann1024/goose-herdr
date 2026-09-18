import AppKit
import HerdrKit
import SwiftUI

struct RootView: View {
    // Owned by AppDelegate so it outlives the window — see AppDelegate in GooseAgentApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false
    @State private var newSpaceListing: NewSpaceListing?
    @AppStorage(SidebarSectionID.spacesHiddenKey) private var spacesHidden = false
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0

    var body: some View {
        let _ = shortcutsRevision  // the hidden ⌘B / ⌘K buttons must follow a remap
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                SidebarView(model: model, collapsed: $sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 0 : 260, alignment: .trailing)
                    .clipped()
                Rectangle()
                    .fill(Theme.sidebarBorder)
                    .frame(width: sidebarCollapsed ? 0 : 1)
                    .ignoresSafeArea()
                DetailView(model: model, sidebarCollapsed: $sidebarCollapsed)
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .focusEffectDisabled()
                            .hidden()
                    )
            }
        }
        .overlayPreferenceValue(PiLaunchOriginKey.self) { anchor in
            if let launch = model.piLaunch, model.showsPiLaunch {
                GeometryReader { geometry in
                    let leading: CGFloat = sidebarCollapsed ? 0 : 261
                    let top = TitlebarMetrics.height + 1
                    PiLaunchInkView(
                        model: model,
                        launchID: launch.id,
                        origin: CGPoint(
                            x: 0,
                            y: anchor.map { min(max(geometry[$0].minY + 16 - top, 0), geometry.size.height - top) }
                                ?? (geometry.size.height - top) / 2
                        )
                    )
                    .frame(width: max(0, geometry.size.width - leading), height: max(0, geometry.size.height - top))
                    .offset(x: leading, y: top)
                    .id(launch.id)
                }
            }
        }
        .overlayPreferenceValue(TooltipRequestKey.self) { request in
            if let request {
                TooltipLayer(request: request)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut(AppShortcuts.chord(for: .toggleSidebar).keyEquivalent,
                                  modifiers: AppShortcuts.chord(for: .toggleSidebar).modifiers)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut(AppShortcuts.chord(for: .search).keyEquivalent,
                                  modifiers: AppShortcuts.chord(for: .search).modifiers)
                .hidden()
        )
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.terminalSplitTree, model.currentSplitTree)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .herdrmHideFocusRing()
        .onAppear { model.start() }
        .onChange(of: spacesHidden, initial: true) { _, _ in
            model.synchronizeSpaceVisibility()
        }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(isPresented: $model.showNewItem, onDismiss: { model.showNewItem = false }) {
            NewItemSheet(model: model)
        }
        .task(id: model.showNewSpace) { await prepareNewSpace() }
        .sheet(item: $newSpaceListing, onDismiss: { model.showNewSpace = false }) { listing in
            NewSpaceSheet(model: model, listing: listing)
        }
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in RenameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in RenameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }

    @MainActor
    private func prepareNewSpace() async {
        guard model.showNewSpace else {
            newSpaceListing = nil
            return
        }
        let device = model.deviceFilter.flatMap { model.device($0) } ?? model.devices.first ?? .local
        do {
            let entries = try await model.service(for: device).listDirectories(at: "~")
            guard !Task.isCancelled, model.showNewSpace else { return }
            newSpaceListing = NewSpaceListing(device: device, entries: entries)
        } catch {
            guard !Task.isCancelled, model.showNewSpace else { return }
            model.showNewSpace = false
            model.actionError = error.localizedDescription
        }
    }
}

/// The custom title strip is the source of truth for window-button alignment.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

private struct WindowTitlebarInteraction: NSViewRepresentable {
    var alignsWindowButtons = false

    func makeNSView(context _: Context) -> NSView {
        let view = WindowTitlebarInteractionView()
        view.alignsWindowButtons = alignsWindowButtons
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowTitlebarInteractionView: NSView {
    var alignsWindowButtons = false

    override func layout() {
        super.layout()
        alignWindowButtons()
    }

    private func alignWindowButtons() {
        guard alignsWindowButtons, bounds.height > 0, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: parent)
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: center.y - button.frame.height / 2))
        }
    }
    private static let fillRestoreFrames =
        NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var rememberFrameWorkItem: DispatchWorkItem?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.alignWindowButtons() }
        Self.rememberNonFilledFrame(of: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    deinit {
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowFrameDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.alignWindowButtons() }
        guard let window = notification.object as? NSWindow else { return }
        rememberFrameWorkItem?.cancel()
        let item = DispatchWorkItem { [weak window] in
            guard let window else { return }
            Self.rememberNonFilledFrame(of: window)
        }
        rememberFrameWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let action = UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick")?
            .lowercased()
        switch action {
        case "fill":
            Self.toggleFill(window)
        case nil:
            if #available(macOS 15.0, *) {
                Self.toggleFill(window)
            } else {
                Self.fillRestoreFrames.removeObject(forKey: window)
                window.performZoom(nil)
            }
        case "minimize":
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performMiniaturize(nil)
        case "none":
            break
        default:
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performZoom(nil)
        }
    }

    private static func toggleFill(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        if framesApproximatelyEqual(window.frame, visibleFrame) {
            let previous = fillRestoreFrames.object(forKey: window)?.rectValue
                ?? fallbackRestoreFrame(in: visibleFrame)
            fillRestoreFrames.removeObject(forKey: window)
            let restored = constrainedRestoreFrame(previous, for: window)
            window.setFrame(restored, display: true, animate: true)
        } else {
            fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
            window.setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private static func rememberNonFilledFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
              !framesApproximatelyEqual(window.frame, visibleFrame)
        else { return }
        fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
    }

    private static func fallbackRestoreFrame(in visibleFrame: NSRect) -> NSRect {
        visibleFrame.insetBy(
            dx: visibleFrame.width * 0.1,
            dy: visibleFrame.height * 0.1
        )
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private static func constrainedRestoreFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let intersectingScreen = NSScreen.screens
            .map { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            .max { $0.1 < $1.1 }
        let screen = if let intersectingScreen, intersectingScreen.1 > 0 {
            intersectingScreen.0
        } else {
            window.screen ?? NSScreen.main
        }
        guard let screen else { return frame }
        return window.constrainFrameRect(frame, to: screen)
    }
}

private struct WindowTitlebarInteractionModifier: ViewModifier {
    var alignsWindowButtons: Bool

    func body(content: Content) -> some View {
        content
            .background(WindowTitlebarInteraction(alignsWindowButtons: alignsWindowButtons))
    }
}

extension View {
    func windowTitlebarInteraction(alignsWindowButtons: Bool = false) -> some View {
        modifier(WindowTitlebarInteractionModifier(alignsWindowButtons: alignsWindowButtons))
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool
    @State private var hasOpenedFileManager = false

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            detailContent
                .onChange(of: model.isFileManagerActive) { _, active in
                    if active { hasOpenedFileManager = true }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
        .task(id: model.gitMetadataTaskKey) {
            guard let entry = model.selectedAttachedEntry else { return }
            while !Task.isCancelled {
                await model.refreshGitMetadata(for: entry)
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private var detailContent: some View {
        ZStack {
            terminal
                .clipped()
                .opacity(model.isFileManagerActive ? 0 : 1)
                .allowsHitTesting(!model.isFileManagerActive)
            if model.showsPiLaunch, model.piLaunch?.revealed != true {
                PiLoadingView(model: model)
            }
            if hasOpenedFileManager {
                DeviceFilesView(model: model)
                    .opacity(model.isFileManagerActive ? 1 : 0)
                    .allowsHitTesting(model.isFileManagerActive)
            }
        }
        .onAppear {
            if model.isFileManagerActive { hasOpenedFileManager = true }
        }
    }

    // MARK: - Titlebar strip (28pt, traditional)

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", title: "Show Sidebar", shortcut: .toggleSidebar) {
                    sidebarCollapsed = false
                }
            }
            Group {
                if model.isFileManagerActive {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Files")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                } else if model.showsPiLaunch {
                    Text(verbatim: "Pi")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                } else if let shell = model.terminalHeaderShell {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(shell.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(shell.device.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                } else if let attached = model.selectedAttachedEntry {
                    switch attached {
                    case .agent(let entry):
                        let agent = entry.agent
                        statusGlyph(agent.status)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .codexTooltip(verbatim: (agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        AgentKindBadge(kind: agent.agent)
                        Text("\u{b7}")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textGhost)
                        gitMetadataView(
                            for: attached,
                            spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID)
                        )
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                        paneLocationButton(agent.paneID)
                    case .terminal(let entry):
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .codexTooltip(verbatim: (entry.pane.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        gitMetadataView(
                            for: attached,
                            spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                        )
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                        paneLocationButton(entry.pane.paneID)
                    }
                } else {
                    Text("No terminal selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
        .windowTitlebarInteraction(alignsWindowButtons: true)
    }

    private func paneLocationButton(_ paneID: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paneID, forType: .string)
        } label: {
            Text(verbatim: paneID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy Herdr location") + Text(verbatim: " \(paneID)"))
        .codexTooltip("Copy Herdr location")
    }

    @ViewBuilder
    private func gitMetadataView(for entry: AppModel.AttachedEntry, spaceName: String) -> some View {
        Text(spaceName)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        if let info = model.gitRepositoryInfo(for: entry.ref) {
            if info.branch != nil || info.isWorktree {
                Text(verbatim: "·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textGhost)
            }
            if let branch = info.branch {
                Text(verbatim: branch)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(0)
            }
            if info.isWorktree {
                Text("Worktree")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(Theme.textTertiary.opacity(0.12), in: Capsule())
                Text(verbatim: info.repositoryName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .codexTooltip(verbatim: info.repositoryName)
            }
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working).frame(width: 13, height: 13)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            EmptyView()
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AgentStatus) -> some View {
        let label: String? = {
            switch status {
            case .working: return String(localized: "Working")
            case .blocked: return String(localized: "Needs input")
            case .done: return String(localized: "Done")
            case .idle, .unknown: return nil
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.statusColor(status))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.statusColor(status).opacity(0.13), in: Capsule())
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var terminalMouseReporting = true
    @Environment(\.colorScheme) private var colorScheme
    /// Per-entry attach state, keyed by `AttachedEntry.id`. `endedAttach` holds the exit
    /// code of a dead attach that *survived* refresh (nil code = no status, e.g. killed
    /// by a signal); a present key drives that entry's reconnect overlay. Ctrl+D / a
    /// normal shell exit closes the pane, so refresh drops the attach and this stays
    /// empty — otherwise the overlay would flash on the way out. `attachRetry` is a
    /// generation the Reconnect button bumps to rebuild just that one terminal.
    /// Per-entry so one dead terminal's overlay never covers another and Reconnect
    /// rebuilds only its own.
    @State private var endedAttach: [String: Int32?] = [:]
    @State private var attachRetry: [String: Int] = [:]
    @State private var uploadingAttachment = false

    @ViewBuilder
    private var terminal: some View {
        ZStack {
            TerminalSplitLayout(trees: model.splitTrees) {
                ForEach(model.attachSessions) { session in
                    if model.terminalLeafIsAlive(session.id, group: session.id) {
                        attachChild(session, isSelected: model.terminalGroupID == session.id)
                            .layoutValue(key: TerminalLeafLayoutKey.self, value: session.id)
                            .opacity(leafOpacity(session.id, group: session.id))
                    }
                }
                ForEach(model.shellSessions) { session in
                    if model.terminalLeafIsAlive(session.id.uuidString, group: session.id.uuidString) {
                        shellChild(id: session.id, group: session.id.uuidString, device: session.device, cwd: nil,
                                   onExit: {
                            if model.splitTrees[session.id.uuidString] != nil {
                                model.closeTerminalLeaf(session.id.uuidString, group: session.id.uuidString)
                            } else { model.closeShellSession(session.id) }
                        })
                    }
                }
                ForEach(model.splitShells) { shell in
                    shellChild(id: shell.id, group: shell.group, device: .local, cwd: shell.workingDirectory,
                               onExit: { model.closeTerminalLeaf(shell.id.uuidString, group: shell.group) })
                }
            }
            TerminalPaneHandles(model: model)
            TerminalSplitDividers(tree: model.layoutSplitTree, onRatio: model.setSplitRatio)
            if model.terminalGroupID == nil { terminalPlaceholder }
        }
        .background(Theme.terminalBackground)
        .overlay(alignment: .bottomTrailing) {
            if uploadingAttachment { uploadIndicator }
        }
        .onChange(of: model.terminalGroupID) { _, _ in
            uploadingAttachment = false
            model.restoreTerminalFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            let target = model.splitAgentView?.window
            var shouldRestore = false
            if model.pendingCreatedSessionFocus, window === target {
                shouldRestore = true
            }
            if model.pendingSplitAgentFocus {
                model.pendingSplitAgentFocus = false
                if window === target { shouldRestore = true }
            }
            if shouldRestore { model.restoreTerminalFocus() }
        }
    }

    private func paneHandleInset(group: String) -> CGFloat {
        (model.splitTrees[group]?.leaves.count ?? 1) > 1 ? TerminalPaneHandleMetrics.height : 0
    }

    private func leafOpacity(_ id: String, group: String) -> Double {
        guard model.terminalGroupID == group else { return 0 }
        return model.currentSplitTree?.focusedID == id ? 1 : 0.55
    }

    private func shellChild(id: UUID, group: String, device: Device, cwd: String?, onExit: @escaping () -> Void) -> some View {
        ShellTerminalView(
            sessionID: id, device: device, workingDirectory: cwd,
            fontName: terminalFontName, fontSize: terminalFontSize,
            thinStrokes: terminalThinStrokes, fontWeight: terminalFontWeight,
            lineSpacing: terminalLineSpacing, dark: colorScheme == .dark,
            mouseReporting: terminalMouseReporting, onExit: { _ in onExit() },
            onFocus: { model.focusTerminalLeaf(id.uuidString, group: group) }
        )
        .padding(.horizontal, 10).padding(.vertical, 8)
        .padding(.top, paneHandleInset(group: group))
        .background(Theme.terminalBackground)
        .opacity(leafOpacity(id.uuidString, group: group))
        .allowsHitTesting(model.terminalGroupID == group)
        .accessibilityHidden(model.terminalGroupID != group)
        .layoutValue(key: TerminalLeafLayoutKey.self, value: id.uuidString)
    }

    private var terminalPlaceholder: some View {
        VStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "EmptyState", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .accessibilityHidden(true)
            }
            Text(placeholderText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("New Terminal") {
                model.quickNewTerminal()
            }
            .controlSize(.large)
            .focusEffectDisabled()
            if model.hasReconnectableDevice {
                Button("Reconnect") {
                    model.reconnectFailedDevices()
                }
                .controlSize(.small)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }


    /// One kept-alive attach. Stays in the hierarchy while deselected (opacity 0, no hit
    /// testing) so its content survives; the selected one is visible and interactive.
    @ViewBuilder
    private func attachChild(_ session: AppModel.AttachedEntry, isSelected: Bool) -> some View {
        let attachmentCapabilities: AgentAttachmentCapabilities? = {
            guard case .agent(let agentEntry) = session else { return nil }
            return model.attachmentCapabilities(
                deviceID: agentEntry.device.id,
                agentKind: agentEntry.agent.agentKindRaw
            )
        }()
        ZStack {
            AttachTerminalView(
                device: session.device,
                target: session.attachTarget,
                sessionID: session.id,
                serverVersion: model.serverVersion(deviceID: session.device.id),
                attachmentCapabilities: attachmentCapabilities,
                fontName: terminalFontName,
                fontSize: terminalFontSize,
                thinStrokes: terminalThinStrokes,
                fontWeight: terminalFontWeight,
                lineSpacing: terminalLineSpacing,
                dark: colorScheme == .dark,
                mouseReporting: terminalMouseReporting,
                onAttachmentError: { model.actionError = $0 },
                onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                onExit: { code in confirmAttachEnded(session, code: code) },
                onFocus: { model.focusTerminalLeaf(session.id, group: session.id) },
                inputSuppressed: model.showsPiLaunch && model.piLaunch?.pane == session.ref
            )
                // Keyed on the retry generation only — NOT colorScheme. A theme toggle
                // must re-theme live via updateNSView (as the split shell already does);
                // rebuilding here would tear down every kept-alive terminal at once and
                // throw away the very content this keeps alive.
                .id("attach-\(session.id)-\(attachRetry[session.id] ?? 0)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.top, paneHandleInset(group: session.id))
            if isSelected, endedAttach[session.id] != nil,
               !model.closingPanes.contains(session.ref) {
                attachEndedOverlay(session)
            }
        }
        // Ghostty's Metal layer is non-opaque (clear background), and the
        // `.opacity` below forces SwiftUI to composite this child offscreen —
        // where glyph anti-aliasing falls back to a transparent backdrop and
        // renders pale (worst on dense CJK strokes). A solid backdrop inside
        // the compositing group gives the text an opaque background to blend
        // against, matching the pre-keep-alive single-view rendering.
        .background(Theme.terminalBackground)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected && !model.showsPiLaunch)
        .accessibilityHidden(!isSelected || model.showsPiLaunch)
    }

    /// Wait for the snapshot before surfacing Reconnect. A normal close (Ctrl+D,
    /// the far-end shell exiting) removes the pane; showing the overlay in that
    /// gap is the flash the user sees. Takeover and a dropped SSH path leave the
    /// pane in place, and that is the only case the overlay is for.
    private func confirmAttachEnded(_ session: AppModel.AttachedEntry, code: Int32?) {
        Task {
            await model.refresh(session.device.id)
            guard model.attachSessions.contains(where: { $0.id == session.id }) else { return }
            endedAttach[session.id] = code
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, or herdr stopping while the pane remains).
    private func attachEndedOverlay(_ entry: AppModel.AttachedEntry) -> some View {
        let dropped = (endedAttach[entry.id] ?? nil) == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttach[entry.id] = nil
                attachRetry[entry.id, default: 0] += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil && model.visibleSessions.isEmpty {
                return String(localized: "This space has no terminals. Click the space name to create one.")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}

struct AddDeviceSheet: View {
    enum Transport: String, CaseIterable {
        case ssh
        case tailcat
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var transport: Transport = .ssh
    @State private var token = ""

    private var canAdd: Bool {
        switch transport {
        case .ssh: return !target.trimmingCharacters(in: .whitespaces).isEmpty
        case .tailcat: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: transport == .ssh
                    ? String(localized: "Uses OpenSSH config, agent, Tailscale SSH, or password")
                    : String(localized: "WireGuard tunnel to a herdr behind NAT — no VPN, no account")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $transport) {
                    Text(String(localized: "SSH")).tag(Transport.ssh)
                    Text(String(localized: "Tailcat")).tag(Transport.tailcat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer().frame(height: 4)
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                Group {
                    if transport == .ssh {
                        SheetSectionLabel("SSH TARGET")
                        TextField("vincent@10.10.10.87", text: $target)
                            .textFieldStyle(.roundedBorder)
                        Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        SheetSectionLabel("TAILCAT TOKEN")
                        TextField("tcpGFwWCD…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("On the remote Mac: `herdr plugin install lbr77/herdr-plugin-tailcat`, then `herdr plugin action invoke herdr.tailcat.token` and paste the token here. The WireGuard tunnel is built in — no external tool. The token is stored in the Keychain. Standalone shells and the Files workspace need SSH.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(alignment: .topLeading)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    switch transport {
                    case .ssh:
                        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                        model.addDevice(
                            name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                            sshTarget: trimmedTarget
                        )
                    case .tailcat:
                        model.addTailcatDevice(
                            name: trimmedName.isEmpty ? String(localized: "Tailcat Device") : trimmedName,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(!canAdd)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: String(localized: "SSH Authentication"),
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(String(localized: "Saved in your macOS login Keychain"), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(alignment: .topLeading)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private enum SheetCardMetrics {
    static let height: CGFloat = 54
    static let cornerRadius: CGFloat = 10
    static let iconSize: CGFloat = 18
    static let gridSpacing: CGFloat = 8
}

/// Stable sheet widths — prefer min/ideal/max equal so AppKit doesn't reflow on click.
private enum SheetLayout {
    static let narrow: CGFloat = 400
    static let search: CGFloat = 440
    static let medium: CGFloat = 540
    static let wide: CGFloat = 580
    static let directoryBrowserHeight: CGFloat = 220
}

private extension View {
    func sheetFixedWidth(_ width: CGFloat) -> some View {
        frame(minWidth: width, idealWidth: width, maxWidth: width)
    }
}

struct SheetSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 4)
    }
}

/// Compact selectable card used for sheet choices instead of native Picker menus.
struct SheetChoiceCard<Icon: View>: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void
    let icon: Icon

    init(
        title: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.action = action
        self.icon = icon()
    }

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) where Icon == Image {
        self.init(title: title, subtitle: subtitle, selected: selected, action: action) {
            Image(systemName: systemImage)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: SheetCardMetrics.iconSize, height: SheetCardMetrics.iconSize)
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: SheetCardMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .fill(selected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .herdrmHideFocusRing()
    }
}

struct NewItemSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var spaceID: String?
    @State private var kind: String?

    private var spaces: [AppModel.SpaceEntry] { model.visibleSpaces }

    private var selectedSpace: AppModel.SpaceEntry? {
        spaces.first { $0.id == spaceID } ?? spaces.first
    }

    private var catalogDeviceID: UUID {
        selectedSpace?.device.id ?? Device.local.id
    }

    private var catalog: AgentCatalogState {
        model.session(catalogDeviceID).agentCatalog
    }

    private var kinds: [String] {
        AgentKindOrder.visibleSorted(catalog.kinds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "plus",
                title: String(localized: "New"),
                subtitle: String(localized: "Choose a space and an agent")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    spaceSection
                    Spacer().frame(height: 12)
                    agentSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("New") {
                    guard let space = selectedSpace, let kind else { return }
                    model.createNewItem(space: space, kind: kind)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(selectedSpace == nil || kind == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.medium)
        .herdrmHideFocusRing()
        .onAppear { syncDefaults() }
        .onChange(of: spaceID) { _, _ in
            model.reloadAgentCatalog(deviceID: catalogDeviceID)
            syncKindIfNeeded()
        }
        .onChange(of: catalogSignature) { _, _ in
            syncKindIfNeeded()
        }
    }

    private var catalogSignature: String {
        "\(catalogDeviceID.uuidString)|\(kinds.joined(separator: ","))"
    }

    @ViewBuilder
    private var spaceSection: some View {
        SheetSectionLabel("SPACE")
        if spaces.isEmpty {
            emptyHint(String(localized: "Create a space first to start an agent."))
            Button("New Space") {
                dismiss()
                model.showNewSpace = true
            }
            .focusEffectDisabled()
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                spacing: SheetCardMetrics.gridSpacing
            ) {
                ForEach(spaces) { entry in
                    SheetChoiceCard(
                        title: spaceTitle(entry),
                        selected: selectedSpace?.id == entry.id
                    ) {
                        spaceID = entry.id
                    } icon: {
                        ProjectSpaceIcon(
                            path: model.spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID),
                            size: 16,
                            slot: SheetCardMetrics.iconSize
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        SheetSectionLabel("AGENT")
        switch catalog {
        case .loading:
            emptyHint(String(localized: "Checking installed agent CLIs…"))
        case .failed(let reason):
            emptyHint(String(format: String(localized: "Couldn’t detect agents: %@"), reason))
        case .loaded(let loaded, _) where loaded.isEmpty:
            emptyHint(String(localized: "No agents detected"))
        case .loaded:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                spacing: SheetCardMetrics.gridSpacing
            ) {
                ForEach(kinds, id: \.self) { item in
                    SheetChoiceCard(
                        title: AgentKindDisplay.name(for: item),
                        selected: kind == item
                    ) {
                        kind = item
                    } icon: {
                        if let resource = BrandIconLoader.agentIcon(for: item) {
                            BrandIcon(resource: resource, size: 16)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func spaceTitle(_ entry: AppModel.SpaceEntry) -> String {
        if model.showsDeviceBadges {
            return "\(entry.workspace.label) · \(entry.device.name)"
        }
        return entry.workspace.label
    }

    private func syncDefaults() {
        if spaceID == nil {
            spaceID = model.selectedSpace.flatMap { ref in
                spaces.first { $0.ref == ref }?.id
            } ?? spaces.first?.id
        }
        model.reloadAgentCatalog(deviceID: catalogDeviceID)
        syncKindIfNeeded()
    }

    private func syncKindIfNeeded() {
        if let kind, kinds.contains(kind) { return }
        kind = kinds.first
    }
}

struct NewSpaceListing: Identifiable {
    let device: Device
    let entries: [String]
    var id: UUID { device.id }
}

struct NewSpaceSheet: View {
    @ObservedObject var model: AppModel
    let listing: NewSpaceListing
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID: UUID
    // The trailing slash keeps typing in filter position from the first keystroke.
    @State private var directory = "~/"
    @State private var label = ""

    init(model: AppModel, listing: NewSpaceListing) {
        self.model = model
        self.listing = listing
        _deviceID = State(initialValue: listing.device.id)
    }

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "plus",
                title: String(localized: "New Space"),
                subtitle: String(localized: "New space on \(chosenDevice.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            // Scroll the form; keep footer pinned so Cancel / New Space never clip.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.showsDeviceBadges {
                        SheetSectionLabel("DEVICE")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                            spacing: SheetCardMetrics.gridSpacing
                        ) {
                            ForEach(model.devices) { device in
                                SheetChoiceCard(
                                    title: device.name,
                                    systemImage: device.isLocal ? "laptopcomputer" : "desktopcomputer",
                                    selected: deviceID == device.id
                                ) {
                                    deviceID = device.id
                                }
                            }
                        }

                        Spacer().frame(height: 12)
                    }

                    SheetSectionLabel("DIRECTORY")
                    DirectoryPickerField(
                        model: model,
                        device: chosenDevice,
                        path: $directory,
                        initialEntries: chosenDevice.id == listing.device.id ? listing.entries : nil
                    )

                    Spacer().frame(height: 12)

                    SheetSectionLabel("NAME")
                    TextField("Defaults to the folder name", text: $label)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("New Space") {
                    model.createNewSpace(device: chosenDevice, directory: directory, label: label)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.medium)
        .herdrmHideFocusRing()
    }
}

/// Path field with an inline folder browser: type freely, click a row to descend,
/// arrow-up to the parent. Local devices list through FileManager (and keep the
/// native panel behind Browse…); remote devices list over one-shot SSH. A path
/// segment that isn't a directory yet filters its parent's listing instead, so
/// "~/de" narrows to Desktop and Developer as you type.
struct DirectoryPickerField: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Binding var path: String

    /// The directory whose children are on screen. Clicks resolve against it, so a
    /// half-typed path keeps showing (and completing from) its parent's folders.
    @State private var listedRoot = ""
    /// The device `listedRoot`/`entries` belong to. Without this, switching the
    /// device picker while the path still reads "~" matches the stale root and
    /// keeps showing the previous device's folders.
    @State private var listedDeviceID: UUID?
    @State private var entries: [String] = []
    /// Case-insensitive prefix applied to `entries` while the last typed segment
    /// isn't a directory of its own.
    @State private var filter = ""
    @State private var isListing = false
    @State private var hoveredEntry: String?

    init(model: AppModel, device: Device, path: Binding<String>, initialEntries: [String]? = nil) {
        self.model = model
        self.device = device
        _path = path
        _listedRoot = State(initialValue: initialEntries == nil ? "" : "~")
        _listedDeviceID = State(initialValue: initialEntries == nil ? nil : device.id)
        _entries = State(initialValue: initialEntries ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    path = Self.parent(of: listedRoot.isEmpty ? path : listedRoot)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Up to the parent folder")
                .disabled(atRoot)
                TextField("~/Projects/foo", text: $path)
                    .textFieldStyle(.roundedBorder)
                if device.isLocal {
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            path = (url.path as NSString).abbreviatingWithTildeInPath
                        }
                    }
                    .focusEffectDisabled()
                }
            }
            browser
        }
        .task(id: "\(device.id.uuidString)|\(path)") {
            // Debounce: retyping cancels this task before the sleep ends.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await refreshListing()
        }
    }

    private var visibleEntries: [String] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { $0.range(of: filter, options: [.caseInsensitive, .anchored]) != nil }
    }

    private var browser: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleEntries, id: \.self) { name in
                    Button {
                        // Trailing slash so the next keystrokes filter inside the
                        // folder instead of rewriting its name.
                        path = (listedRoot == "/" ? "/\(name)" : "\(listedRoot)/\(name)") + "/"
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            Text(name)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(hoveredEntry == name ? Theme.itemWash : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            hoveredEntry = name
                        } else if hoveredEntry == name {
                            hoveredEntry = nil
                        }
                    }
                }
                if visibleEntries.isEmpty && !isListing {
                    Text(entries.isEmpty ? String(localized: "No subfolders") : String(localized: "No folders match \"\(filter)\""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                        .padding(8)
                }
            }
            .padding(4)
        }
        .frame(height: SheetLayout.directoryBrowserHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if isListing {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            }
        }
    }

    private var atRoot: Bool {
        let current = Self.normalized(listedRoot.isEmpty ? path : listedRoot)
        return current == "/" || current == "~"
    }

    @MainActor
    private func refreshListing() async {
        let service = model.service(for: device)
        if listedDeviceID != device.id {
            listedDeviceID = device.id
            listedRoot = ""
            entries = []
            filter = ""
        }
        let typed = path.trimmingCharacters(in: .whitespaces)
        let root = Self.normalized(typed.isEmpty ? "~" : typed)
        if root == listedRoot {
            filter = ""
            return
        }
        let partial = Self.lastComponent(of: root)
        // Typing inside the directory already on screen filters it right away; the
        // fetch below still lets a fully typed (or dot-hidden) folder take over. A
        // trailing slash is an explicit "list this folder", never a filter.
        if !typed.hasSuffix("/"), Self.parent(of: root) == listedRoot {
            filter = partial
        }
        isListing = true
        defer { isListing = false }
        for candidate in [root, Self.parent(of: root)] {
            if candidate == listedRoot {
                // Already on screen; keep the listing, keep the filter, skip the fetch.
                filter = partial
                return
            }
            guard let names = try? await service.listDirectories(at: candidate) else { continue }
            // A slow reply for a path the user already left must not clobber the new one.
            guard !Task.isCancelled else { return }
            listedRoot = candidate
            entries = names
            filter = candidate == root ? "" : partial
            return
        }
        guard !Task.isCancelled else { return }
        entries = []
        filter = ""
    }

    /// "~/a/b" → "b"; the segment the filter matches against.
    static func lastComponent(of path: String) -> String {
        (normalized(path) as NSString).lastPathComponent
    }

    /// "~/a/b" → "~/a"; stops at "~" and "/".
    static func parent(of path: String) -> String {
        let normalized = normalized(path)
        if normalized == "~" || normalized == "/" { return normalized }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "~" : parent
    }

    /// Trims trailing slashes so paths compose predictably ("/" itself survives).
    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

struct RenameSpaceSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.SpaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Space"),
                subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameSpace(entry, label: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.workspace.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
        .onAppear { name = entry.workspace.label }
    }
}

struct RenameAgentSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.AgentEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Agent"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameAgent(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
        .onAppear { name = entry.title }
    }
}

struct RenameTerminalSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.TerminalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Terminal"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Terminal name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameTerminal(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
        .onAppear { name = entry.title }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Changing the SSH target reconnects the device")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(
                        device.id,
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .herdrmHideFocusRing()
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
        }
    }
}
