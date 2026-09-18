import AppKit
import HerdrKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    @State private var deviceButtonHovered = false
    @State private var draggingSpaceID: String?
    @State private var spaceDrop: (id: String, after: Bool)?
    @State private var draggingSessionID: String?
    @State private var sessionDrop: (id: String, after: Bool)?
    @AppStorage(SidebarSectionID.spacesHiddenKey) private var spacesHidden = false
    @AppStorage(SidebarSectionID.spacesExpandedKey) private var spacesExpanded = true
    @AppStorage(SidebarActionID.newTerminal.hiddenKey) private var newTerminalHidden = false
    @AppStorage(SidebarActionID.newSpace.hiddenKey) private var newSpaceHidden = false
    @AppStorage(SidebarActionID.files.hiddenKey) private var filesHidden = false
    @AppStorage(SidebarActionID.search.hiddenKey) private var searchHidden = false
    @StateObject private var sessionIndexHints = SessionIndexHintController()
    @AppStorage(AppModel.prioritySessionsKey) private var prioritySessions = false
    @FocusState private var bellFocused: Bool

    private var showsPrioritySessions: Bool { prioritySessions && !spacesHidden }

    /// The header's plus follows the section: Priority sessions put sessions
    /// there, and space creation moved inside that sheet.
    private var addButtonTitle: LocalizedStringKey {
        showsPrioritySessions ? "New Session" : "New Space"
    }

    var body: some View {
        let sessions = model.sidebarSessions
        let firstOtherID = sessions.first(where: { !model.isPriorityGroup($0) })?.id
        VStack(spacing: 0) {
            // 28pt titlebar strip: traffic lights on the left, collapse toggle on the right
            HStack {
                Spacer()
                TitlebarIconButton(systemName: "sidebar.left", title: "Hide Sidebar", shortcut: .toggleSidebar) {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)
            .windowTitlebarInteraction()

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                if !newTerminalHidden {
                    quickActionRow(.newTerminal) { model.quickNewTerminal() }
                }
                // Also reachable from the plus button by the Spaces
                // header; promoted here alongside the other New … actions (#84).
                if !newSpaceHidden {
                    quickActionRow(.newSpace) { model.toggleNewSpace() }
                }
                if !filesHidden {
                    quickActionRow(.files) { model.toggleFileManager() }
                }
                if !searchHidden {
                    quickActionRow(.search) { model.toggleSearch() }
                }
            }
            .padding(.horizontal, 10)

            if !newTerminalHidden || !newSpaceHidden || !filesHidden || !searchHidden {
                Spacer().frame(height: 10)
            }

            ScrollView {
                VStack(spacing: 1) {
                    if !spacesHidden {
                        sectionHeader(showsPrioritySessions ? "High priority" : "Spaces") {
                            sectionAddButton(
                                systemImage: "plus",
                                title: addButtonTitle,
                                shortcut: showsPrioritySessions ? nil : .newSpace
                            ) {
                                if showsPrioritySessions {
                                    model.newSession = .choose
                                } else {
                                    model.showNewSpace = true
                                }
                            }
                            .accessibilityLabel(Text(addButtonTitle))
                            Button {
                                prioritySessions.toggle()
                                bellFocused = true
                            } label: {
                                Image(systemName: prioritySessions ? "bell.fill" : "bell")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($bellFocused)
                            .codexTooltip("Priority sessions")
                            .accessibilityLabel(Text("Priority sessions"))
                            .accessibilityValue(Text(prioritySessions ? "On" : "Off"))
                            .accessibilityAddTraits(prioritySessions ? .isSelected : [])
                        }
                        if spacesExpanded && !showsPrioritySessions {
                            allSpacesRow
                            ForEach(model.visibleSpaces) { entry in
                                SpaceRowView(
                                    entry: entry,
                                    model: model,
                                    isEmpty: model.isEmptySpace(entry),
                                    showIndexHints: sessionIndexHints.isShowingSpaces,
                                    draggingSpaceID: $draggingSpaceID,
                                    spaceDrop: $spaceDrop
                                )
                            }
                        }
                        Spacer().frame(height: 10)
                    }

                    Group {
                            if !showsPrioritySessions, sessions.isEmpty, model.shellSessions.isEmpty {
                                Text(emptySessionsHint)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textGhost)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            if showsPrioritySessions, !sessions.contains(where: model.isPriorityGroup) {
                                Text("No sessions need attention")
                                    .font(Theme.sidebarRowMeta)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            ForEach(sessions) { entry in
                                if showsPrioritySessions, entry.id == firstOtherID {
                                    sessionGroupHeader("Other sessions")
                                }
                                Group {
                                    switch entry {
                                    case .agent(let agent):
                                        AgentRowView(
                                            entry: agent,
                                            model: model,
                                            showsSpace: showsPrioritySessions,
                                            showIndexHints: sessionIndexHints.isShowing,
                                            draggingSessionID: $draggingSessionID,
                                            sessionDrop: $sessionDrop
                                        )
                                    case .terminal(let terminal):
                                        TerminalRowView(
                                            entry: terminal,
                                            model: model,
                                            showsSpace: showsPrioritySessions,
                                            showIndexHints: sessionIndexHints.isShowing,
                                            draggingSessionID: $draggingSessionID,
                                            sessionDrop: $sessionDrop
                                        )
                                    }
                                }
                                .focusable(showsPrioritySessions)
                                .onKeyPress(keys: [.return, .space]) { _ in
                                    guard showsPrioritySessions else { return .ignored }
                                    model.selectAgent(entry.ref)
                                    return .handled
                                }
                                .accessibilityAddTraits(
                                    !model.isFileManagerActive && model.selectedShellID == nil
                                        && model.selectedPane == entry.ref ? .isSelected : []
                                )
                            }
                            if showsPrioritySessions, firstOtherID == nil {
                                sessionGroupHeader("Other sessions")
                            }
                            if let launch = model.piLaunch, launch.pane == nil, model.showsPiLaunch {
                                HStack {
                                    Text(verbatim: "Pi")
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                                .padding(8)
                                .frame(height: 51)
                                .background(Theme.itemWashSelected, in: RoundedRectangle(cornerRadius: 7))
                                .anchorPreference(key: PiLaunchOriginKey.self, value: .bounds) { $0 }
                                .accessibilityLabel(Text("Loading Pi"))
                            }
                            ForEach(model.shellSessions) { session in
                                shellRow(session)
                                    .contextMenu {
                                        Button("Close Terminal", role: .destructive) {
                                            model.closeShellSession(session.id)
                                        }
                                    }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 260)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
        .onChange(of: showsPrioritySessions) {
            draggingSpaceID = nil
            spaceDrop = nil
            draggingSessionID = nil
            sessionDrop = nil
            model.objectWillChange.send()
        }
        // Only SwiftUI focus inside this sidebar handles Escape; terminal responders are siblings.
        .onKeyPress(.escape) {
            guard showsPrioritySessions else { return .ignored }
            prioritySessions = false
            bellFocused = true
            return .handled
        }
    }

    private func sessionGroupHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.sidebarGroupHeader)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(8)
    }

    private var emptySessionsHint: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed: return String(localized: "Couldn't connect")
        case .idle: return String(localized: "Not connected")
        default: return String(localized: "No sessions")
        }
    }

    // MARK: - Rows

    private func quickActionSelected(_ id: SidebarActionID) -> Bool {
        switch id {
        case .files: return model.isFileManagerActive
        case .search: return model.showSearch
        case .newTerminal: return false
        case .newSpace: return model.showNewSpace
        }
    }

    private func quickActionRow(_ id: SidebarActionID, action: @escaping () -> Void) -> some View {
        let selected = quickActionSelected(id)
        let _ = shortcutsRevision
        return Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if id == .newSpace {
                        SpaceIcon(systemName: id.systemImage)
                    } else {
                        Image(systemName: id.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                }
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Text(id.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
        .focusEffectDisabled()
        .help(quickActionHelp(id))
    }



    private func quickActionHelp(_ id: SidebarActionID) -> Text {
        switch id {
        case .newTerminal: return Text(id.title) + Text(" (\(AppShortcuts.display(for: .quickNewTerminal)))")
        case .newSpace: return Text(id.title) + Text(" (\(AppShortcuts.display(for: .newSpace)))")
        case .search: return Text(id.title) + Text(" (⌘K)")
        case .files: return Text(id.title)
        }
    }

    private func sectionAddButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SpaceIcon(systemName: systemImage, size: 10)
                .foregroundStyle(Theme.textGhost)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }

    private func sectionHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            if showsPrioritySessions {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { spacesExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textGhost)
                            .rotationEffect(.degrees(spacesExpanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(title)
                .accessibilityValue(Text(spacesExpanded ? "Expanded" : "Collapsed"))
            }
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }


    private var allSpacesRow: some View {
        let selected = model.selectedSpace == nil
        return Button {
            model.selectSpace(nil)
        } label: {
            HStack(spacing: 8) {
                BrandIcon(resource: "all-spaces", size: 14, fallbackSystemName: "square.stack")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                    .accessibilityHidden(true)
                Text("All Spaces")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
                SidebarSessionIndexSlot(
                    visible: sessionIndexHints.isShowingSpaces,
                    number: model.spaceSwitchNumber(for: nil)
                ) {
                    Text("\(model.scopeAgentCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textGhost)
                        .frame(minWidth: 20)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct TerminalRowView: View {
        let entry: AppModel.TerminalEntry
        @ObservedObject var model: AppModel
        var showIndexHints = false
        @Binding var draggingSessionID: String?
        @Binding var sessionDrop: (id: String, after: Bool)?
        @State private var hovered = false

        var body: some View {
            let selected = !model.isFileManagerActive
                && model.selectedPane == entry.ref
                && model.selectedShellID == nil
            let path = entry.pathDisplay
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    SidebarSessionIndexSlot(
                        visible: showIndexHints,
                        number: model.sessionSwitchNumber(for: .agent(entry.ref))
                    ) {
                        EmptyView()
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    if let path {
                        Text(path)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    } else {
                        ProjectSpaceIcon(
                            path: model.spaceIconPath(device: entry.device, workspaceID: entry.pane.workspaceID),
                            size: 11,
                            slot: 11
                        )
                        .foregroundStyle(Theme.textTertiary)
                        Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 51)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
            .onHover { hovered = $0 }
            .sidebarDragChrome(
                isDragging: draggingSessionID == entry.id,
                dropAfter: sessionDrop?.after,
                isTarget: sessionDrop?.id == entry.id
            )
            .overlay {
                TerminalRowDragHost(
                    allowsDrag: !model.prioritySessionsEnabled,
                    entryID: entry.id,
                    onClick: { model.selectAgent(entry.ref) },
                    onRename: { model.terminalToRename = entry },
                    onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                    onDragStart: { draggingSessionID = $0 },
                    onDragEnd: {
                        draggingSessionID = nil
                        sessionDrop = nil
                    },
                    onDropHover: { after in
                        sessionDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleSessions
                        )
                    },
                    onHoverExit: {
                        if sessionDrop?.id == entry.id { sessionDrop = nil }
                    },
                    onDrop: { sourceID, after in
                        draggingSessionID = nil
                        sessionDrop = nil
                        guard let source = model.visibleSessions.first(where: { $0.id == sourceID })
                        else { return }
                        model.moveSession(source, onto: .terminal(entry), placeAfter: after)
                    }
                )
            }
            .help(path ?? entry.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectAgent(entry.ref) }
            .accessibilityLabel(entry.title)
        }
    }

    /// App-owned standalone shell (local login shell or plain ssh), outside
    /// any herdr space.
    private func shellRow(_ session: ShellSession) -> some View {
        let selected = !model.isFileManagerActive && model.selectedShellID == session.id
        return Button {
            model.selectShell(session.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(session.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(session.device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
                SidebarSessionIndexSlot(
                    visible: sessionIndexHints.isShowing,
                    number: model.sessionSwitchNumber(for: .shell(session.id))
                ) {
                    EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
    var showIndexHints = false
    @Binding var draggingSessionID: String?
    @Binding var sessionDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let agent = entry.agent
        let selected = !model.isFileManagerActive
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        let unread = model.isUnread(entry)
        let priority = showsSpace && model.isPriorityGroup(.agent(entry))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    if showsSpace {
                        Text(entry.title).codexTooltip(verbatim: entry.title)
                    } else {
                        Text(entry.title)
                    }
                }
                .font(showsSpace ? Theme.sidebarRowTitle : .system(size: 13.5))
                .fontWeight(priority ? .semibold : .regular)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                SidebarSessionIndexSlot(
                    visible: showIndexHints,
                    number: model.sessionSwitchNumber(for: .agent(entry.ref)),
                    keepsStatus: true
                ) {
                    if model.piLaunch?.pane == entry.ref, model.showsPiLaunch,
                       !showsSpace || agent.status != .blocked {
                        if model.piLaunch?.failed == true {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                        } else {
                            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading Pi"))
                        }
                    } else {
                        HStack(spacing: 4) {
                            AgentStatusGlyph(status: agent.status, unreadDone: unread)
                            if let title = priorityStatusTitle {
                                Text(verbatim: title)
                                    .font(Theme.sidebarRowMeta)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            HStack(spacing: 5) {
                AgentKindBadge(
                    kind: agent.agent,
                    fontSize: showsSpace ? 11 : 11.5,
                    color: showsSpace ? Theme.textSecondary : Theme.textTertiary
                )
                .fixedSize(horizontal: showsSpace, vertical: false)
                Text("·")
                    .font(showsSpace ? Theme.sidebarRowMeta : .system(size: 11.5))
                    .foregroundStyle(showsSpace ? Theme.textSecondary : Theme.textGhost)
                ProjectSpaceIcon(
                    path: model.spaceIconPath(device: entry.device, workspaceID: agent.workspaceID),
                    size: 11,
                    slot: 11
                )
                .foregroundStyle(showsSpace ? Theme.textSecondary : Theme.textTertiary)
                Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                    .font(showsSpace ? Theme.sidebarRowMeta : .system(size: 11.5))
                    .foregroundStyle(showsSpace ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !showsSpace, agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                if model.showsRowDeviceBadges {
                    DeviceChip(device: entry.device)
                        .layoutPriority(showsSpace ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, showsSpace ? 8 : 7)
        .frame(minHeight: showsSpace ? 54 : 51, maxHeight: showsSpace ? nil : 51)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingSessionID == entry.id,
            dropAfter: sessionDrop?.after,
            isTarget: sessionDrop?.id == entry.id
        )
        .overlay {
            AgentRowDragHost(
                allowsDrag: !model.prioritySessionsEnabled,
                entryID: entry.id,
                onClick: { model.selectAgent(entry.ref) },
                onRename: { model.agentToRename = entry },
                onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                onDragStart: { draggingSessionID = $0 },
                onDragEnd: {
                    draggingSessionID = nil
                    sessionDrop = nil
                },
                    onDropHover: { after in
                        sessionDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleSessions
                        )
                    },
                onHoverExit: {
                    if sessionDrop?.id == entry.id { sessionDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingSessionID = nil
                    sessionDrop = nil
                    guard let source = model.visibleSessions.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveSession(source, onto: .agent(entry), placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectAgent(entry.ref) }
        .accessibilityLabel(accessibilityLabel(unread: unread))
    }

    private func accessibilityLabel(unread: Bool) -> String {
        var parts = [entry.title]
        switch entry.agent.status {
        case .working: parts.append(String(localized: "Working"))
        case .blocked: parts.append(String(localized: "Needs input"))
        case .done where unread: parts.append(String(localized: "Unread"))
        case .done: break
        case .idle, .unknown: break
        }
        return parts.joined(separator: ", ")
    }
}

    // MARK: - Footer (device filter)

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.showDevicePanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let device = model.filteredDevice {
                        DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 10)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.filteredDevice?.name ?? "All Devices")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(deviceButtonHovered || model.showDevicePanel
                          ? AnyShapeStyle(Theme.itemWashSelected)
                          : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.hairline, lineWidth: deviceButtonHovered ? 1 : 0)
            )
            .scaleEffect(deviceButtonHovered ? 1.04 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: deviceButtonHovered)
            .onHover { deviceButtonHovered = $0 }

            Spacer()

            OpenSettingsGearButton()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var connectionDotColor: Color {
        switch model.connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }
}

struct OpenSettingsGearButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "settings")
            DispatchQueue.main.async {
                for window in NSApp.windows where CloseCommandRouting.isSettingsWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(String(localized: "Settings"))
    }
}

/// Small icon button that sits in the 28pt titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Custom device switcher popover, matching the DeviceSwitcher design artboard:
/// two-line device rows with OS icon, status dot, and a check on the current device.
struct DevicePopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 24, alignment: .leading)

            // aggregate view across every connected device
            Button {
                isPresented = false
                model.setDeviceFilter(nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                        .foregroundStyle(model.deviceFilter == nil ? Theme.text : Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All Devices")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Text(String(localized: "\(model.devices.count) devices · \(connectedCount) connected"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if model.deviceFilter == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle(selected: model.deviceFilter == nil))

            ForEach(model.devices) { device in
                DevicePopoverRow(
                    device: device,
                    isActive: device.id == model.deviceFilter,
                    connection: model.session(device.id).connection
                ) {
                    isPresented = false
                    model.setDeviceFilter(device.id)
                }
                .contextMenu {
                    if !device.isLocal {
                        Button(String(localized: "Edit \(device.name)…")) {
                            isPresented = false
                            model.deviceToEdit = device
                        }
                        Button(String(localized: "Remove \(device.name)"), role: .destructive) {
                            isPresented = false
                            model.removeDevice(device)
                        }
                    }
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)

            actionRow(icon: "plus", label: "Add Device…") {
                isPresented = false
                model.showAddDevice = true
            }
        }
        .padding(5)
        .frame(width: 252)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var connectedCount: Int {
        model.devices.filter {
            if case .connected = model.session($0.id).connection { return true }
            return false
        }.count
    }

    private func actionRow(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }
}

struct DevicePopoverRow: View {
    let device: Device
    let isActive: Bool
    let connection: ConnectionState
    let action: () -> Void
    @State private var hovered = false

    private var dotColor: Color {
        switch connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 13)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(device.localizedSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered || isActive ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
    }
}

/// `after A` and `before B` are the same gap. Always draw that gap on B's
/// top edge so the line does not jump when the pointer crosses the seam.
private func sidebarDropTarget<T: Identifiable>(
    onto id: T.ID, after: Bool, items: [T]
) -> (id: T.ID, after: Bool) {
    guard after,
          let index = items.firstIndex(where: { $0.id == id }),
          items.indices.contains(index + 1)
    else { return (id, after) }
    return (items[index + 1].id, false)
}

private extension View {
    func sidebarDragChrome(isDragging: Bool, dropAfter: Bool?, isTarget: Bool) -> some View {
        opacity(isDragging ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .overlay(alignment: (dropAfter ?? false) ? .bottom : .top) {
                if isTarget {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .transaction { $0.animation = nil }
                }
            }
    }
}

private struct EmptySpaceHelp: ViewModifier {
    let isEmpty: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmpty {
            content.help(String(localized: "No terminals — click to create one"))
        } else {
            content
        }
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusEffectDisabled()
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

private struct SpaceIcon: View {
    let systemName: String
    var size: CGFloat = 14
    var slot: CGFloat = 20

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .font(.system(size: size, weight: .regular))
            .frame(width: size, height: size)
            .frame(width: slot, height: slot)
    }
}

struct ProjectSpaceIcon: View {
    let path: String?
    var size: CGFloat = 14
    var slot: CGFloat = 20
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .frame(width: slot, height: slot)
            } else {
                SpaceIcon(systemName: "square", size: min(size, 12), slot: slot)
            }
        }
        .accessibilityHidden(true)
        .task(id: path) {
            image = nil
            guard let path else { return }
            let loaded = await ProjectIconLoader.shared.image(for: path)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Not a `Button`: on macOS, `Button` consumes mouseDown so SwiftUI `.onDrag`
/// never starts. Click and reorder go through `SpaceRowDragHost`.
private struct SpaceRowView: View {
    let entry: AppModel.SpaceEntry
    @ObservedObject var model: AppModel
    let isEmpty: Bool
    var showIndexHints = false
    @Binding var draggingSpaceID: String?
    @Binding var spaceDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let selected = model.selectedSpace == entry.ref
        let nameColor: Color = isEmpty
            ? Theme.textGhost
            : (selected ? Theme.text : Theme.textSecondary)
        let iconColor: Color = isEmpty
            ? Theme.textGhost
            : (selected ? Theme.textSecondary : Theme.textTertiary)
        HStack(spacing: 8) {
            ProjectSpaceIcon(path: model.spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID))
                .foregroundStyle(iconColor)
            Text(entry.workspace.label)
                .font(.system(size: 13))
                .foregroundStyle(nameColor)
                .lineLimit(1)
            Spacer()
            if !isEmpty {
                SpaceAttentionGlyph(attention: model.attention(in: entry))
                if model.showsRowDeviceBadges {
                    DeviceChip(device: entry.device)
                }
                Text("\(model.agentCount(in: entry))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
                    .frame(minWidth: 20)
            } else if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingSpaceID == entry.id,
            dropAfter: spaceDrop?.after,
            isTarget: spaceDrop?.id == entry.id
        )
        .overlay {
            SpaceRowDragHost(
                entryID: entry.id,
                label: entry.workspace.label,
                onClick: { model.activateSpace(entry.ref) },
                onRename: { model.spaceToRename = entry },
                onCopyPath: model.spacePath(for: entry).map { path in
                    {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                },
                onClose: { model.requestCloseSpace(entry) },
                onDragStart: { draggingSpaceID = $0 },
                onDragEnd: {
                    draggingSpaceID = nil
                    spaceDrop = nil
                },
                    onDropHover: { after in
                        spaceDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleSpaces
                        )
                    },
                onHoverExit: {
                    if spaceDrop?.id == entry.id { spaceDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingSpaceID = nil
                    spaceDrop = nil
                    guard let source = model.visibleSpaces.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveSpace(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.activateSpace(entry.ref) }
        .accessibilityLabel(accessibilityLabel)
        .modifier(EmptySpaceHelp(isEmpty: isEmpty))
    }

    private var accessibilityLabel: String {
        var parts = [entry.workspace.label]
        if isEmpty { parts.append(String(localized: "No terminals")) }
        switch model.attention(in: entry) {
        case .blocked: parts.append(String(localized: "Needs input"))
        case .unreadDone: parts.append(String(localized: "Unread"))
        case .working: parts.append(String(localized: "Working"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}

struct SpinnerView: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
