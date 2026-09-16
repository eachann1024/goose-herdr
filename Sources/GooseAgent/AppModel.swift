import Foundation
import HerdrKit
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// Agent kinds offered by the picker. Local manifests are filtered through the
/// login-shell search PATH; remote manifests stay server-owned.
enum AgentCatalogState: Equatable {
    case loading
    case loaded(kinds: [String], paths: [String: String] = [:])
    case failed(String)

    var kinds: [String] {
        guard case .loaded(let kinds, _) = self else { return [] }
        return kinds
    }

    var paths: [String: String] {
        guard case .loaded(_, let paths) = self else { return [:] }
        return paths
    }
}

/// Global pane identity: pane ids like "w1:p1" collide across devices.
struct PaneRef: Hashable, Codable {
    let deviceID: UUID
    let paneID: String
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

/// A space herdr dropped after its last tab closed. The app keeps it until the
/// user right-clicks Close; clicking the gray name recreates a terminal.
struct RetainedSpace: Codable, Equatable, Identifiable {
    var deviceID: UUID
    var workspaceID: String
    var label: String
    var cwd: String?
    var sortIndex: Int

    var id: String { "\(deviceID.uuidString)-\(workspaceID)" }
    var ref: SpaceRef { SpaceRef(deviceID: deviceID, workspaceID: workspaceID) }

    var workspaceInfo: WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: workspaceID,
            number: sortIndex,
            label: label,
            focused: false,
            paneCount: 0,
            tabCount: 0,
            cwd: cwd
        )
    }
}

enum RetainedSpaceStore {
    static let defaultsKey = "spaces.retained"

    static func load(defaults: UserDefaults = .standard) -> [RetainedSpace] {
        guard let data = defaults.data(forKey: defaultsKey),
              let spaces = try? JSONDecoder().decode([RetainedSpace].self, from: data)
        else { return [] }
        return spaces
    }

    static func save(_ spaces: [RetainedSpace], defaults: UserDefaults = .standard) {
        if spaces.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(spaces) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func merging(_ live: [WorkspaceInfo], with retained: [RetainedSpace]) -> [WorkspaceInfo] {
        let liveIDs = Set(live.map(\.workspaceID))
        var result = live
        for space in retained.sorted(by: { $0.sortIndex < $1.sortIndex })
        where !liveIDs.contains(space.workspaceID) {
            result.insert(space.workspaceInfo, at: min(max(space.sortIndex, 0), result.count))
        }
        return result
    }
}

/// Live state for one device's herdr session.
struct DeviceSessionState {
    var connection: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var workspaces: [WorkspaceInfo] = []
    var tabs: [TabInfo] = []
    var panes: [PaneInfo] = []
    var agentCatalog: AgentCatalogState = .loading
    var attachmentCapabilities = AgentAttachmentCapabilityRegistry()
}

struct SSHAuthenticationRequest: Identifiable {
    let deviceID: UUID
    let target: String

    var id: UUID { deviceID }
}

/// A standalone local or SSH shell shown as its own sidebar entry — app-owned,
/// outside any herdr space (unlike the persistent herdr terminals under
/// TERMINALS) and not the ⌘D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let device: Device
}

/// Per-kind CLI path overrides persisted in user defaults. Empty means automatic
/// lookup on the login-shell search PATH. Invalid paths hide that kind until
/// the user fixes or clears the field — they never silently fall back.
enum AgentBinaryOverrides {
    static let defaultsKey = "agent.binaryOverrides"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[entry.key] = value }
            }
    }

    static func save(_ overrides: [String: String], defaults: UserDefaults = .standard) {
        let trimmed = overrides.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    /// All devices stay connected in parallel; this only filters the sidebar.
    @Published var deviceFilter: UUID? {
        didSet {
            // Persisted so a relaunch restores the last selection (nil = All
            // Devices, which removes the key). Every reset path — removing the
            // filtered device, a notification jump to another device — goes
            // through this property, so the stored value can never go stale.
            UserDefaults.standard.set(deviceFilter?.uuidString, forKey: Self.deviceFilterKey)
        }
    }
    private static let deviceFilterKey = "device.filter"
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef? {
        didSet {
            // Async creation/refresh cannot restore a filter with no visible control.
            if selectedSpace != nil,
               UserDefaults.standard.bool(forKey: SidebarSectionID.spacesHiddenKey) {
                selectedSpace = nil
            }
        }
    }
    @Published var selectedPane: PaneRef? {
        didSet {
            // Opening (or reselecting) a finished agent marks it viewed.
            // Also acknowledge a completion seen before leaving the current pane.
            if let old = oldValue, old != selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: old.deviceID, paneID: old.paneID))
            }
            if let selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: selectedPane.deviceID, paneID: selectedPane.paneID))
            }
            if let selectedPane, let data = try? JSONEncoder().encode(selectedPane) {
                UserDefaults.standard.set(data, forKey: Self.selectedPaneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedPaneKey)
            }
            noteSelectedAttachSession()
        }
    }
    private static let selectedPaneKey = "session.selectedPane"

    /// Kept-alive attaches: every agent/terminal the user has opened stays
    /// mounted (hidden) so switching back preserves its scrollback and running
    /// state instead of re-attaching. Evicted when its pane closes.
    @Published var attachSessions: [AttachedEntry] = []

    /// Keeps the selected pane's attach alive so switching back preserves its content.
    /// Runs synchronously inside the `selectedPane` assignment, so the kept-alive entry
    /// is in `attachSessions` in the same update the selection lands in — a separate
    /// onAppear/onChange would leave a one-frame window with no view for the new pane.
    private func noteSelectedAttachSession() {
        guard let entry = selectedAttachedEntry,
              !attachSessions.contains(where: { $0.id == entry.id })
        else { return }
        attachSessions.append(entry)
    }
    /// Finished agents the user has not opened since they flipped to `done`.
    @Published private(set) var unreadAgents: Set<AgentUnreadKey> = []

    @Published var showAddDevice = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    @Published var isFileManagerActive = false
    @Published var shellSplitAxis: SplitAxis?
    /// Set by `reveal` when a jump lands while the ⌘D split is open, and consumed once the
    /// main window is key again. Only an actual jump sets it: dismissing the search with
    /// Escape never calls `reveal`, and the sidebar assigns `selectedPane` directly.
    @Published var pendingSplitAgentFocus = false
    /// The pane that currently holds the keyboard within the ⌘D split. Reset to
    /// the agent side whenever the split closes so reopening it is predictable.
    @Published var activeSplitSide: SplitSide = .agent
    /// Persisted divider ratio for the ⌘D split, shared with the resize commands.
    /// Deliberately not `@AppStorage`: that publishes only from inside a View, so the
    /// menu commands would write UserDefaults without ever redrawing the split.
    @Published var splitRatio: Double =
        UserDefaults.standard.object(forKey: AppModel.splitRatioKey) as? Double ?? 0.5
    {
        didSet { UserDefaults.standard.set(splitRatio, forKey: AppModel.splitRatioKey) }
    }
    static let splitRatioKey = "terminal.splitRatio"
    /// Live terminal views of the ⌘D split, used by menu commands to move focus.
    /// The agent side is resolved from the attach registry by the current selection
    /// (kept-alive attach views persist across switches, so a stored ref would go
    /// stale); the shell side stays a weak ref since the split shell is a single view.
    var splitAgentView: LineBreakTerminalView? {
        selectedAttachedEntry.flatMap { AttachViewRegistry.view(for: $0.id) }
    }
    weak var splitShellView: LineBreakTerminalView?
    /// Standalone terminals. Their views stay alive while deselected —
    /// unlike agents, a local shell has no server side to reattach to.
    @Published var shellSessions: [ShellSession] = []
    @Published var selectedShellID: UUID?
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    @Published var agentToRename: AgentEntry?
    @Published var terminalToRename: TerminalEntry?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?
    @Published private(set) var retainedSpaces: [RetainedSpace] = RetainedSpaceStore.load()

    private let store = DeviceStore()
    private var dismissedSpaceKeys: Set<String> = []
    private var spaceReviveTask: Task<Void, Never>?
    private var revivingSpaces: Set<SpaceRef> = []
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounceTokens: [UUID: UUID] = [:]
    private var refreshDebouncePending: Set<UUID> = []
    private var snapshotRefreshTasks: [UUID: Task<Bool, Never>] = [:]
    private var snapshotRefreshTokens: [UUID: UUID] = [:]
    private var refreshRequested: Set<UUID> = []
    private var statusGenerations: [UUID: UInt64] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    init() {
        let loaded = DeviceStore().load()
        devices = loaded
        // Reserve the selection before parallel device snapshots can pick a default.
        if let data = UserDefaults.standard.data(forKey: Self.selectedPaneKey) {
            selectedPane = try? JSONDecoder().decode(PaneRef.self, from: data)
        }
        // Restore the device filter only if that device still exists;
        // otherwise fall back to All Devices.
        if let raw = UserDefaults.standard.string(forKey: Self.deviceFilterKey),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            deviceFilter = id
        }
    }

    // MARK: - Derived state

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSessionState {
        sessions[id] ?? DeviceSessionState()
    }

    /// The herdr version the device's server reported on its last successful
    /// ping; the terminal attach uses it to pick a protocol-matching CLI binary.
    func serverVersion(deviceID: UUID) -> String? {
        if case .connected(let version) = session(deviceID).connection { return version }
        return nil
    }

    func attachmentCapabilities(
        deviceID: UUID,
        agentKind: String?
    ) -> AgentAttachmentCapabilities? {
        session(deviceID).attachmentCapabilities.capabilities(for: agentKind)
    }

    var filteredDevice: Device? {
        deviceFilter.flatMap(device)
    }

    private var devicesInScope: [Device] {
        if let filtered = filteredDevice { return [filtered] }
        return devices
    }

    /// Aggregate connection state for the current scope (footer dot, hints).
    var connection: ConnectionState {
        let states = devicesInScope.map { session($0.id).connection }
        if let failed = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failed
        }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ if case .connected = $0 { return true }; return false }) {
            return .connected(version: "")
        }
        return states.isEmpty ? .idle : .connecting
    }

    struct AgentEntry: Identifiable {
        let device: Device
        let agent: AgentInfo
        let tabLabel: String?

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
        var title: String { agent.title(tabLabel: tabLabel) }
    }

    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry {
        AgentEntry(
            device: device,
            agent: agent,
            tabLabel: session(device.id).tabs.first { $0.tabID == agent.tabID }?.customLabel
        )
    }

    struct TerminalEntry: Identifiable {
        let device: Device
        let pane: PaneInfo
        let tab: TabInfo?
        let terminalID: String

        var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }
        var tabID: String? { pane.tabID ?? tab?.tabID }

        var title: String {
            // User tab labels must win or `tab.rename` is invisible behind OSC.
            if let label = tab?.customLabel {
                return label
            }
            if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !terminalTitle.isEmpty {
                return terminalTitle
            }
            if let cwd = pane.cwd, !cwd.isEmpty {
                let basename = URL(fileURLWithPath: cwd).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return String(localized: "Terminal")
        }
    }

    enum AttachedEntry: Identifiable {
        case agent(AgentEntry)
        case terminal(TerminalEntry)

        // Starting/exiting an agent changes the pane's kind, not its live attach.
        var id: String { "\(ref.deviceID.uuidString)-\(ref.paneID)" }

        var device: Device {
            switch self {
            case .agent(let entry): return entry.device
            case .terminal(let entry): return entry.device
            }
        }

        var ref: PaneRef {
            switch self {
            case .agent(let entry): return entry.ref
            case .terminal(let entry): return entry.ref
            }
        }

        var title: String {
            switch self {
            case .agent(let entry): return entry.title
            case .terminal(let entry): return entry.title
            }
        }

        var isAgent: Bool {
            if case .agent = self { return true }
            return false
        }

        var workspaceID: String {
            switch self {
            case .agent(let entry): return entry.agent.workspaceID
            case .terminal(let entry): return entry.pane.workspaceID
            }
        }

        var attachTarget: TerminalAttachTarget {
            switch self {
            case .agent(let entry): return .agent(paneID: entry.agent.paneID)
            case .terminal(let entry): return .terminal(terminalID: entry.terminalID)
            }
        }
    }

    struct SpaceEntry: Identifiable {
        let device: Device
        let workspace: WorkspaceInfo

        var id: String { "\(device.id.uuidString)-\(workspace.workspaceID)" }
        var ref: SpaceRef { SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID) }
    }

    var visibleSpaces: [SpaceEntry] {
        devicesInScope.flatMap { device in
            session(device.id).workspaces.map { SpaceEntry(device: device, workspace: $0) }
        }
    }

    /// Agents across the scope, filtered by selected space, in herdr tab order
    /// (device → workspace → snapshot array) so sidebar drag matches the TUI.
    var visibleAgents: [AgentEntry] {
        var entries = devicesInScope.flatMap { device in
            session(device.id).agents.map { agentEntry(device: device, agent: $0) }
        }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.agent.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.agent.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.agent.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.agent.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.agent.tabID)
        }
    }

    func terminalEntries(for device: Device) -> [TerminalEntry] {
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        return state.panes.compactMap { pane in
            guard let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
    }

    var visibleTerminals: [TerminalEntry] {
        var entries = devicesInScope.flatMap { terminalEntries(for: $0) }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.pane.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.pane.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.pane.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.tabID)
        }
    }

    func isUnread(_ entry: AgentEntry) -> Bool {
        unreadAgents.contains(AgentUnreadKey(deviceID: entry.device.id, paneID: entry.agent.paneID))
    }

    func attention(in entry: SpaceEntry) -> SpaceAttention {
        let agents = session(entry.device.id).agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        }
        return SpaceAttention.rollup(agents.map {
            (
                status: $0.status,
                unreadDone: unreadAgents.contains(
                    AgentUnreadKey(deviceID: entry.device.id, paneID: $0.paneID)
                )
            )
        })
    }

    private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {
        session(deviceID).workspaces.firstIndex { $0.workspaceID == workspaceID } ?? Int.max
    }

    private func tabRank(deviceID: UUID, tabID: String?) -> Int {
        guard let tabID else { return Int.max }
        return session(deviceID).tabs.firstIndex { $0.tabID == tabID } ?? Int.max
    }

    private func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
        session(deviceID).tabs
            .filter { $0.workspaceID == workspaceID }
            .map(\.tabID)
    }

    var scopeAgentCount: Int {
        devicesInScope.reduce(0) { $0 + session($1.id).agents.count }
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return agentEntry(device: device, agent: agent)
    }

    var selectedTerminalEntry: TerminalEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        return terminalEntries(for: device).first { $0.pane.paneID == selected.paneID }
    }

    var selectedAttachedEntry: AttachedEntry? {
        if let selectedEntry { return .agent(selectedEntry) }
        if let selectedTerminalEntry { return .terminal(selectedTerminalEntry) }
        return nil
    }

    private var firstVisiblePaneRef: PaneRef? {
        visibleAgents.first?.ref ?? visibleTerminals.first?.ref
    }

    func agentCount(in entry: SpaceEntry) -> Int {
        session(entry.device.id).agents.filter { $0.workspaceID == entry.workspace.workspaceID }.count
    }

    func isRetainedSpace(_ ref: SpaceRef) -> Bool {
        retainedSpaces.contains { $0.deviceID == ref.deviceID && $0.workspaceID == ref.workspaceID }
    }

    func isEmptySpace(_ entry: SpaceEntry) -> Bool {
        isRetainedSpace(entry.ref)
    }

    /// Click a live space to filter it; click a gray empty space to recreate its terminal.
    func activateSpace(_ ref: SpaceRef) {
        if isRetainedSpace(ref) {
            reviveRetainedSpace(ref)
        } else {
            selectSpace(ref)
        }
    }

    /// Best-effort root path for a space: workspace.cwd, else any pane/agent cwd in it.
    func spacePath(for entry: SpaceEntry) -> String? {
        if let cwd = entry.workspace.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return cwd
        }
        let state = session(entry.device.id)
        let wid = entry.workspace.workspaceID
        if let cwd = state.agents.first(where: { $0.workspaceID == wid })?.cwd,
           let trimmed = optionalNonEmpty(cwd) {
            return trimmed
        }
        if let cwd = state.panes.first(where: { $0.workspaceID == wid })?.cwd,
           let trimmed = optionalNonEmpty(cwd) {
            return trimmed
        }
        return nil
    }

    private func optionalNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        session(deviceID).workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// Show device badges only when more than one device is configured.
    var showsDeviceBadges: Bool {
        devices.count > 1
    }

    /// Badges on sidebar/titlebar rows are scoped by the device filter: with a
    /// single device selected every row belongs to it, so the badge says
    /// nothing. ⌘K search and the New Space device picker stay on
    /// `showsDeviceBadges` — search crosses all devices regardless of the
    /// filter, and the pickers must stay reachable while filtered.
    var showsRowDeviceBadges: Bool {
        devices.count > 1 && deviceFilter == nil
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef?) {
        let ref = UserDefaults.standard.bool(forKey: SidebarSectionID.spacesHiddenKey) ? nil : ref
        isFileManagerActive = false
        selectedSpace = ref
        selectedShellID = nil
        if let entry = selectedAttachedEntry {
            if ref == nil { return }
            if entry.device.id == ref!.deviceID && entry.workspaceID == ref!.workspaceID { return }
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    func setDeviceFilter(_ id: UUID?) {
        deviceFilter = id
        if let id, let space = selectedSpace, space.deviceID != id {
            selectedSpace = nil
        }
        if let id, let selected = selectedPane, selected.deviceID != id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    /// Hiding Spaces removes only the filter, not the active terminal or Files view.
    func synchronizeSpaceVisibility() {
        if UserDefaults.standard.bool(forKey: SidebarSectionID.spacesHiddenKey) {
            selectedSpace = nil
        }
    }

    /// A new terminal/agent must never land on a device the sidebar has filtered out.
    private func isFilteredOut(_ deviceID: UUID) -> Bool {
        deviceFilter.map { $0 != deviceID } ?? false
    }

    /// When jumping into a space, land on whoever still needs a look — not
    /// merely the first tab.
    private func preferredVisibleAgent() -> AgentEntry? {
        let agents = visibleAgents
        if let blocked = agents.first(where: { $0.agent.status == .blocked }) { return blocked }
        if let unread = agents.first(where: { $0.agent.status == .done && isUnread($0) }) {
            return unread
        }
        if let working = agents.first(where: { $0.agent.status == .working }) { return working }
        return agents.first
    }

    /// Jump target used by the search sheet and by notification clicks.
    func reveal(_ ref: PaneRef, preservingSpaceScope: Bool = false) {
        isFileManagerActive = false
        if let filter = deviceFilter, filter != ref.deviceID {
            deviceFilter = nil
        }
        if preservingSpaceScope, selectedSpace != nil {
            let state = session(ref.deviceID)
            let workspaceID = state.panes.first { $0.paneID == ref.paneID }?.workspaceID
                ?? state.agents.first { $0.paneID == ref.paneID }?.workspaceID
            selectedSpace = workspaceID.map { SpaceRef(deviceID: ref.deviceID, workspaceID: $0) }
        } else {
            selectedSpace = nil
        }
        selectedPane = ref
        selectedShellID = nil
        // Only the search sheet needs the deferred request: its dismissal restores the
        // parent window's previous responder after the view tree has asked for focus.
        // `showSearch` is still true here — SearchView calls this before dismissing.
        //
        // Notification clicks deliberately do NOT arm it. With the app already frontmost
        // there may be no key-window transition at all, so nothing would consume the flag
        // and a later unrelated activation would cash it in, pulling the keyboard out of
        // the shell. Those clicks get focus from the recreated attach and from the
        // entry-change request instead.
        if shellSplitAxis != nil, showSearch { pendingSplitAgentFocus = true }
    }

    // MARK: - Shell terminals

    func openFileManager() {
        isFileManagerActive = true
        selectedShellID = nil
    }

    /// Sidebar Files is a mode toggle: open when idle, leave when already active.
    func toggleFileManager() {
        if isFileManagerActive {
            isFileManagerActive = false
        } else {
            openFileManager()
        }
    }

    func toggleSearch() {
        showSearch.toggle()
    }

    func toggleNewSpace() {
        showNewSpace.toggle()
    }

    func selectAgent(_ ref: PaneRef) {
        isFileManagerActive = false
        selectedPane = ref
        selectedShellID = nil
    }

    var selectedShell: ShellSession? {
        selectedShellID.flatMap { id in shellSessions.first { $0.id == id } }
    }

    /// Every click opens another terminal.
    func newShellSession(on device: Device) {
        let n = shellSessions.count + 1
        let session = ShellSession(
            id: UUID(),
            title: String(localized: "Terminal \(n)"),
            device: device
        )
        shellSessions.append(session)
        selectShell(session.id)
    }

    func selectShell(_ id: UUID) {
        isFileManagerActive = false
        selectedShellID = id
        ShellViewRegistry.focus(id)
    }

    /// Sidebar order for ⌘1…9: Agents → remote Terminals → local shell sessions,
    /// already filtered by the selected space (when any).
    enum SwitchableSession: Equatable {
        case agent(PaneRef)
        case shell(UUID)
    }

    var switchableSessions: [SwitchableSession] {
        var items: [SwitchableSession] = visibleAgents.map { .agent($0.ref) }
        items += visibleTerminals.map { .agent($0.ref) }
        items += shellSessions.map { .shell($0.id) }
        return items
    }

    /// `number` is 1…9. ⌘9 jumps to the last item (browser-style); ⌘1…8 are fixed slots.
    func selectSwitchableSession(number: Int) {
        let items = switchableSessions
        guard !items.isEmpty, (1...9).contains(number) else { return }
        let index: Int
        if number == 9 {
            index = items.count - 1
        } else {
            guard number - 1 < items.count else { return }
            index = number - 1
        }
        switch items[index] {
        case .agent(let ref):
            selectAgent(ref)
        case .shell(let id):
            selectShell(id)
        }
    }

    func closeShellSession(_ id: UUID) {
        shellSessions.removeAll { $0.id == id }
        if selectedShellID == id {
            selectedShellID = shellSessions.last?.id
            if let remaining = selectedShellID { ShellViewRegistry.focus(remaining) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        NotificationManager.shared.setup(model: self)
        // Finder-launched apps have launchd's PATH. Capture the login +
        // interactive shell environment on a background thread once; New Agent
        // lookup, herdr spawn, and terminal attach all read the same snapshot.
        Task.detached(priority: .utility) {
            _ = await ShellEnvironment.ensure()
        }
        for device in devices {
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Surface any herdr named sessions running now (issue #81).
        refreshNamedSessions()
        // Named-session devices are only available after discovery.
        if let selectedPane, device(selectedPane.deviceID) == nil {
            self.selectedPane = nil
        }
    }

    func service(for device: Device) -> HerdrService {
        if let service = services[device.id] { return service }
        // Only the built-in Local device (no socket override) may auto-start a
        // herdr server. A named-session device points at an existing session's
        // socket; that server is the user's to run, and auto-start would spawn a
        // default-session server on the wrong socket.
        let service = HerdrService(
            device: device,
            autoStartLocalServer: device.isLocal && device.socketPath == nil
        )
        services[device.id] = service
        return service
    }

    /// Merges live herdr named sessions in as extra Local devices (issue #81)
    /// and drops ones whose session went away. Discovered, never persisted:
    /// named sessions come and go, unlike user-added SSH/tailcat devices.
    func refreshNamedSessions() {
        let discovered = HerdrSessionDiscovery.namedSessions()
            .map(HerdrSessionDiscovery.device(for:))
        let discoveredIDs = Set(discovered.map(\.id))
        // Named-session devices already present, by id.
        let existingIDs = Set(devices.filter(\.isNamedSession).map(\.id))

        for device in discovered where !existingIDs.contains(device.id) {
            devices.append(device)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Remove named-session devices whose session is gone.
        for device in devices where device.isNamedSession && !discoveredIDs.contains(device.id) {
            stopSession(device.id)
            attachSessions.removeAll { $0.device.id == device.id }
            devices.removeAll { $0.id == device.id }
            if deviceFilter == device.id { deviceFilter = nil }
            if selectedSpace?.deviceID == device.id { selectedSpace = nil }
            if selectedPane?.deviceID == device.id {
                selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
            }
            removeRetainedSpaces(deviceID: device.id)
        }
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        sessionTasks[device.id]?.cancel()
        if sessions[device.id] == nil {
            sessions[device.id] = DeviceSessionState(
                workspaces: RetainedSpaceStore.merging(
                    [],
                    with: retainedSpaces.filter { $0.deviceID == device.id }
                )
            )
        }
        let service = service(for: device)
        sessionTasks[device.id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.sessions[device.id]?.connection = .connecting
                do {
                    let pong = try await service.connect()
                    self.sessions[device.id]?.connection = .connected(version: pong.version)
                    backoff = 1
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    await self.loadAgentCatalog(deviceID: device.id, using: service)
                    eventSubscriptions: while !Task.isCancelled {
                        let subscribedPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                        let stream = try await service.events(statusPaneIDs: subscribedPaneIDs)
                        var needsResubscribe = false
                        var resubscribeDelay: UInt64 = 100_000_000
                        for try await event in stream {
                            guard !Task.isCancelled else { return }
                            if event.kind == HerdrEvent.agentStatusChangedKind {
                                if self.applyAgentStatusEvent(event, deviceID: device.id) {
                                    self.scheduleRefresh(device.id)
                                } else {
                                    _ = await self.refreshImmediately(device.id)
                                }
                            } else if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                if !(await self.refreshImmediately(device.id)) {
                                    needsResubscribe = true
                                    resubscribeDelay = 500_000_000
                                    break
                                }
                            } else {
                                self.scheduleRefresh(device.id)
                            }

                            if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                let currentPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                                if currentPaneIDs != subscribedPaneIDs {
                                    needsResubscribe = true
                                    break
                                }
                            }
                        }
                        if needsResubscribe {
                            try? await Task.sleep(nanoseconds: resubscribeDelay)
                            continue eventSubscriptions
                        }
                        guard !Task.isCancelled else { return }
                        throw HerdrError.connectionFailed("event stream ended")
                    }
                } catch {
                    self.sessions[device.id]?.connection = .failed(error.localizedDescription)
                    // The catalog's initial state is .loading; when connect()
                    // itself fails the load never runs, and without this the
                    // New Agent panel spins on "Checking agents…" forever
                    // while the only hint is the footer indicator (#69).
                    if case .loading = self.sessions[device.id]?.agentCatalog ?? .loading {
                        self.sessions[device.id]?.agentCatalog = .failed(
                            self.actionErrorMessage(error, device: device)
                        )
                    }
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Locally, keeps only advertised CLIs whose binaries are on the login-shell
    /// search PATH (or a Settings override). SSH hosts keep their server-owned
    /// catalog; `agent.start` validates in the target pane instead. Manifests
    /// also feed the attachment-capability registry (paste path vs upload).
    private func loadAgentCatalog(deviceID: UUID, using service: HerdrService) async {
        // Keep the last loaded catalog visible while refreshing so Settings/New Agent
        // don't collapse to a single row (or empty) during the round-trip.
        if case .loaded = sessions[deviceID]?.agentCatalog {
            // leave as-is
        } else {
            sessions[deviceID]?.agentCatalog = .loading
        }
        do {
            let manifests = try await service.agentManifests()
            sessions[deviceID]?.attachmentCapabilities =
                AgentAttachmentCapabilityRegistry(manifests: manifests)
            let advertised = manifests.map(\.agent)
            if device(deviceID)?.isLocal == true {
                // Herdr supports OMP through its lifecycle extension, so it has
                // no screen-detection manifest in server.agent_manifests.
                let found = await service.installedAgents(
                    from: advertised,
                    includingIntegrationKinds: ["omp"],
                    overrides: AgentBinaryOverrides.load()
                )
                sessions[deviceID]?.agentCatalog = .loaded(
                    kinds: found.map(\.kind),
                    paths: Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0.path) })
                )
            } else {
                sessions[deviceID]?.agentCatalog = .loaded(kinds: advertised)
            }
        } catch {
            sessions[deviceID]?.agentCatalog = .failed(error.localizedDescription)
        }
    }

    func reloadAgentCatalog(deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { await loadAgentCatalog(deviceID: deviceID, using: service) }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        refreshDebounceTokens[id] = nil
        refreshDebouncePending.remove(id)
        snapshotRefreshTasks[id]?.cancel()
        snapshotRefreshTasks[id] = nil
        snapshotRefreshTokens[id] = nil
        refreshRequested.remove(id)
        statusGenerations[id] = nil
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        Task { await service?.disconnect() }
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        startSession(device)
        probeOSIfNeeded(device)
        setDeviceFilter(device.id)
    }

    /// Adds a tailcat-tunnel device. The token is a bearer credential and goes
    /// straight to the Keychain — devices.json never sees it.
    func addTailcatDevice(name: String, token: String) {
        let device = Device(name: name, kind: .tailcat)
        do {
            try TailcatCredentialStore.setToken(token, for: device.id)
        } catch {
            actionError = error.localizedDescription
            return
        }
        devices.append(device)
        store.save(devices)
        startSession(device)
        setDeviceFilter(device.id)
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again"))
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Reconnect is also the natural moment to pick up a named session that
        // started (or dropped) since launch (issue #81).
        refreshNamedSessions()
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target (e.g. after an IP change).
    func updateDevice(_ id: UUID, name: String, sshTarget: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].isLocal else { return }
        let targetChanged = devices[index].sshTarget != sshTarget
        devices[index].name = name
        if targetChanged {
            removeSSHPassword(for: id)
            devices[index].kind = .ssh(target: sshTarget)
            devices[index].osID = nil
            stopSession(id)
            startSession(devices[index])
            probeOSIfNeeded(devices[index])
        }
        store.save(devices)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        TailcatCredentialStore.removeToken(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        attachSessions.removeAll { $0.device.id == device.id }
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if deviceFilter == device.id { deviceFilter = nil }
        if selectedSpace?.deviceID == device.id { selectedSpace = nil }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
        removeRetainedSpaces(deviceID: device.id)
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(_ deviceID: UUID) async -> Bool {
        refreshRequested.insert(deviceID)
        if let task = snapshotRefreshTasks[deviceID] {
            return await task.value
        }
        let token = UUID()
        snapshotRefreshTokens[deviceID] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var latestSucceeded = false
            while !Task.isCancelled, self.refreshRequested.remove(deviceID) != nil {
                latestSucceeded = await self.performRefresh(deviceID)
            }
            if self.snapshotRefreshTokens[deviceID] == token {
                self.snapshotRefreshTokens[deviceID] = nil
                self.snapshotRefreshTasks[deviceID] = nil
            }
            return latestSucceeded
        }
        snapshotRefreshTasks[deviceID] = task
        return await task.value
    }

    private func performRefresh(_ deviceID: UUID) async -> Bool {
        guard let device = device(deviceID), let service = services[deviceID],
              !revivingSpaces.contains(where: { $0.deviceID == deviceID }) else {
            return false
        }
        let statusGeneration = statusGenerations[deviceID, default: 0]
        do {
            let snapshot = try await service.snapshot()
            guard services[deviceID] === service, sessions[deviceID] != nil,
                  !revivingSpaces.contains(where: { $0.deviceID == deviceID }) else {
                return false
            }
            guard statusGenerations[deviceID, default: 0] == statusGeneration else {
                // A status event or workspace restoration overtook this request.
                // Discard the older snapshot and fetch the completed state.
                refreshRequested.insert(deviceID)
                return true
            }
            unreadAgents = AgentUnread.applying(
                previous: previousStatuses[deviceID] ?? [:],
                agents: snapshot.agents,
                unread: unreadAgents,
                deviceID: device.id
            )
            notifyTransitions(
                device: device,
                from: previousStatuses[deviceID] ?? [:],
                to: snapshot.agents,
                workspaces: snapshot.workspaces,
                tabs: snapshot.tabs ?? []
            )
            previousStatuses[deviceID] = Dictionary(
                uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
            )
            let previousPaneOrder = visibleAgents.map(\.ref) + visibleTerminals.map(\.ref)
            let previousWorkspaces = sessions[deviceID]?.workspaces ?? []
            let liveIDs = Set(snapshot.workspaces.map(\.workspaceID))
            retainDisappearedSpaces(
                deviceID: deviceID,
                previous: previousWorkspaces,
                liveIDs: liveIDs,
                paneCWD: (sessions[deviceID]?.panes ?? []).reduce(into: [String: String]()) { result, pane in
                    if result[pane.workspaceID] == nil, let cwd = optionalNonEmpty(pane.cwd ?? "") {
                        result[pane.workspaceID] = cwd
                    }
                }
            )
            pruneRetainedSpaces(deviceID: deviceID, liveIDs: liveIDs)
            let mergedWorkspaces = RetainedSpaceStore.merging(
                snapshot.workspaces,
                with: retainedSpaces.filter { $0.deviceID == deviceID }
            )
            sessions[deviceID]?.agents = snapshot.agents
            sessions[deviceID]?.workspaces = mergedWorkspaces
            sessions[deviceID]?.tabs = TabReorder.ordered(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes
            let paneIDs = Set((snapshot.panes ?? []).map(\.paneID))
                .union(snapshot.agents.map(\.paneID))
            // Drop kept-alive attaches whose pane is gone (closed). A pane only taken
            // over by another client still exists, so it stays — its Reconnect overlay
            // needs the kept-alive child to rebuild the attach.
            attachSessions.removeAll { $0.device.id == deviceID && !paneIDs.contains($0.ref.paneID) }
            if let selected = selectedPane, selected.deviceID == deviceID,
               !paneIDs.contains(selected.paneID) {
                // Follow sidebar order, not the server's focus or agent activity priority.
                let remaining = Set(visibleAgents.map(\.ref) + visibleTerminals.map(\.ref))
                if let index = previousPaneOrder.firstIndex(of: selected) {
                    let neighbors = Array(previousPaneOrder.dropFirst(index + 1))
                        + previousPaneOrder.prefix(index).reversed()
                    selectedPane = neighbors.first { remaining.contains($0) }
                } else {
                    selectedPane = nil
                }
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !mergedWorkspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedPane == nil, selectedSpace.map(isRetainedSpace) != true {
                if let focusedPaneID = snapshot.focusedPaneID,
                   paneIDs.contains(focusedPaneID),
                   deviceFilter == nil || deviceFilter == deviceID {
                    let focused = PaneRef(deviceID: deviceID, paneID: focusedPaneID)
                    if selectedSpace == nil
                        || selectedAttachedEntry.map({
                            $0.ref == focused && $0.workspaceID == selectedSpace?.workspaceID
                        }) == true {
                        selectedPane = focused
                    }
                }
                if selectedPane == nil {
                    selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
                }
            }
            // A restored selection predates its snapshot, so its attach could not
            // be registered by selectedPane.didSet yet.
            noteSelectedAttachSession()
            return true
        } catch {
            // A snapshot is one request on an otherwise live session. The
            // event/connect loop owns connection health and will mark the
            // device failed if the transport itself is gone.
            return false
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        // Coalesce from the leading edge instead of resetting the timer for
        // every event. A busy pane can emit continuously; a trailing debounce
        // would never fire until output stopped, hiding the working state.
        guard refreshDebounces[deviceID] == nil else {
            refreshDebouncePending.insert(deviceID)
            return
        }
        let token = UUID()
        refreshDebounceTokens[deviceID] = token
        refreshDebounces[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled,
                  self.refreshDebounceTokens[deviceID] == token
            else { return }
            await self.refresh(deviceID)
            if self.refreshDebounceTokens[deviceID] == token {
                let needsTrailing = self.refreshDebouncePending.remove(deviceID) != nil
                self.refreshDebounceTokens[deviceID] = nil
                self.refreshDebounces[deviceID] = nil
                if needsTrailing {
                    self.scheduleRefresh(deviceID)
                }
            }
        }
    }

    private func refreshImmediately(_ deviceID: UUID) async -> Bool {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = nil
        refreshDebounceTokens[deviceID] = nil
        refreshDebouncePending.remove(deviceID)
        return await refresh(deviceID)
    }

    @discardableResult
    private func applyAgentStatusEvent(_ event: HerdrEvent, deviceID: UUID) -> Bool {
        guard let paneID = event.payload["data"]?["pane_id"]?.stringValue,
              let statusRaw = event.payload["data"]?["agent_status"]?.stringValue,
              let device = device(deviceID),
              var state = sessions[deviceID],
              let index = state.agents.firstIndex(where: { $0.paneID == paneID })
        else { return false }

        let status = AgentStatus(wire: statusRaw)
        guard state.agents[index].status != status else { return true }
        let previous = previousStatuses[deviceID] ?? [:]
        state.agents[index] = state.agents[index].updatingStatus(status)
        unreadAgents = AgentUnread.applying(
            previous: previous,
            agents: state.agents,
            unread: unreadAgents,
            deviceID: deviceID
        )
        notifyTransitions(
            device: device,
            from: previous,
            to: state.agents,
            workspaces: state.workspaces,
            tabs: state.tabs
        )
        var nextStatuses = previous
        nextStatuses[paneID] = status
        previousStatuses[deviceID] = nextStatuses
        statusGenerations[deviceID, default: 0] &+= 1
        sessions[deviceID] = state
        return true
    }

    private func statusSubscriptionPaneIDs(_ deviceID: UUID) -> [String] {
        Array(Set(
            session(deviceID).agents.map(\.paneID)
                + session(deviceID).panes.map(\.paneID)
        )).sorted()
    }

    private static let paneTopologyEventKinds: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.moved",
        "pane.agent_detected",
    ]

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            let tabLabel = tabs.first { $0.tabID == agent.tabID }?.customLabel
            NotificationManager.shared.post(
                agent: agent,
                title: agent.title(tabLabel: tabLabel),
                status: agent.status,
                deviceID: device.id,
                deviceName: device.name,
                spaceName: workspaces.first { $0.workspaceID == agent.workspaceID }?.label ?? agent.workspaceID
            )
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and persists it.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(
                target: target,
                credentialID: device.id
            ) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
                self.store.save(self.devices)
            }
        }
    }

    private static func isSSHAuthenticationFailure(_ error: Error) -> Bool {
        guard let herdrError = error as? HerdrError,
              case .tunnelFailed(let reason) = herdrError
        else { return false }
        return [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "no supported authentication methods",
        ].contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// An action fired while the device session is down surfaces the bare
    /// "connection failed: not connected", which points at nothing. The
    /// reconnect loop already knows why the device is unreachable — say that
    /// instead. (#21)
    func actionErrorMessage(_ error: Error, device: Device) -> String {
        guard let herdrError = error as? HerdrError,
              case .connectionFailed(let reason) = herdrError,
              reason == "not connected"
        else { return error.localizedDescription }
        switch session(device.id).connection {
        case .connecting:
            return String(localized: "Still connecting to \(device.name) — try again in a moment.")
        case .failed(let reason):
            return String(localized: "\(device.name) is unreachable: \(reason)")
        case .idle:
            return String(localized: "\(device.name) isn't connected.")
        case .connected:
            return String(localized: "\(device.name) just reconnected — try again.")
        }
    }

    // MARK: - Closing

    private var paneCloseTask: Task<Void, Never>?
    @Published private(set) var closingPanes: Set<PaneRef> = []

    func requestCloseSpace(_ entry: SpaceEntry) {
        if isRetainedSpace(entry.ref) {
            closeRequest = CloseRequest(
                title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
                message: String(localized: "This empty space will be removed.")
            ) { [weak self] in
                self?.dismissRetainedSpace(entry.ref)
            }
            return
        }
        closeRequest = CloseRequest(
            title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
            message: String(localized: "All terminals and agents in this space will be closed.")
        ) { [weak self] in
            guard let self else { return }
            self.markSpaceDismissed(entry.ref)
            Task {
                do {
                    try await self.service(for: entry.device)
                        .closeWorkspace(workspaceID: entry.workspace.workspaceID)
                    if self.selectedSpace == entry.ref { self.selectedSpace = nil }
                    await self.refresh(entry.device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: entry.device)
                }
            }
        }
    }

    /// Close a pane. Idle/done agents and plain terminals close immediately;
    /// working/blocked agents still ask for confirmation.
    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
        let agent = session(ref.deviceID).agents.first { $0.paneID == ref.paneID }
        let needsConfirm: Bool = {
            guard let agent else { return false }
            switch agent.status {
            case .working, .blocked:
                return true
            case .idle, .done, .unknown:
                return false
            }
        }()

        if needsConfirm {
            closeRequest = CloseRequest(
                title: String(localized: "Close \"\(name)\"?"),
                message: String(localized: "This agent is still running and will be terminated.")
            ) { [weak self] in
                self?.performClosePane(ref, device: device)
            }
        } else {
            performClosePane(ref, device: device)
        }
    }

    private func performClosePane(_ ref: PaneRef, device: Device) {
        let previous = paneCloseTask
        paneCloseTask = Task {
            // Serialize rapid closes so each decision uses the remaining live panes.
            await previous?.value
            closingPanes.insert(ref)
            defer { closingPanes.remove(ref) }
            do {
                let service = service(for: device)
                let snapshot = try await service.snapshot()
                let workspaceID = snapshot.panes?.first { $0.paneID == ref.paneID }?.workspaceID
                    ?? snapshot.agents.first { $0.paneID == ref.paneID }?.workspaceID
                guard let workspaceID else { return }
                let workspace = snapshot.workspaces.first { $0.workspaceID == workspaceID }
                let sortIndex = session(device.id).workspaces.firstIndex { $0.workspaceID == workspaceID }
                    ?? snapshot.workspaces.firstIndex { $0.workspaceID == workspaceID } ?? 0
                let cwd = workspace?.cwd
                    ?? snapshot.panes?.first { $0.paneID == ref.paneID }?.cwd
                    ?? snapshot.agents.first { $0.paneID == ref.paneID }?.cwd
                try await service.closePane(paneID: ref.paneID)
                if workspace?.paneCount == 1 {
                    rememberClosedSpace(
                        deviceID: device.id,
                        workspaceID: workspaceID,
                        label: workspace?.label,
                        cwd: cwd,
                        sortIndex: sortIndex
                    )
                }
                await refresh(device.id)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    // MARK: - Actions

    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        if isRetainedSpace(entry.ref) {
            renameRetainedSpace(entry.ref, label: label)
            return
        }
        Task {
            do {
                try await service(for: entry.device).renameWorkspace(
                    workspaceID: entry.workspace.workspaceID,
                    label: label
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    func renameAgent(_ entry: AgentEntry, name: String) {
        renameTabLabel(device: entry.device, tabID: entry.agent.tabID, current: entry.title, name: name)
    }

    func renameTerminal(_ entry: TerminalEntry, name: String) {
        guard let tabID = entry.tabID else { return }
        renameTabLabel(device: entry.device, tabID: tabID, current: entry.title, name: name)
    }

    private func renameTabLabel(device: Device, tabID: String, current: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return }
        Task {
            do {
                try await service(for: device).renameTab(tabID: tabID, label: name)
                await refresh(device.id)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Reorders a Space by dropping it on another Space of the same device.
    /// Cross-device drops are ignored; herdr remains the source of truth after refresh.
    func moveSpace(_ source: SpaceEntry, onto target: SpaceEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id else { return }
        let orderedIDs = session(source.device.id).workspaces.map(\.workspaceID)
        guard let plan = WorkspaceReorder.plan(
            moving: source.workspace.workspaceID,
            onto: target.workspace.workspaceID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.workspaces {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[source.device.id]?.workspaces = WorkspaceReorder.applying(
                    current,
                    id: \.workspaceID,
                    plan: plan
                )
            }
        }

        Task {
            do {
                try await service(for: source.device).moveWorkspaceBlock(
                    workspaceIDs: plan.workspaceIDs,
                    beforeWorkspaceID: plan.beforeWorkspaceID
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    /// Reorders an agent tab by dropping it on another agent in the same space.
    /// Cross-space and cross-device drops are ignored (`tab.move` is in-workspace).
    func moveAgent(_ source: AgentEntry, onto target: AgentEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.agent.workspaceID == target.agent.workspaceID
        else { return }
        moveTab(
            device: source.device,
            workspaceID: source.agent.workspaceID,
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter
        )
    }

    /// Same `tab.move` path as agents. Cross-space / cross-device drops are ignored.
    func moveTerminal(_ source: TerminalEntry, onto target: TerminalEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.pane.workspaceID == target.pane.workspaceID,
              let moving = source.tabID,
              let onto = target.tabID
        else { return }
        moveTab(
            device: source.device,
            workspaceID: source.pane.workspaceID,
            moving: moving,
            onto: onto,
            placeAfter: placeAfter
        )
    }

    private func moveTab(
        device: Device,
        workspaceID: String,
        moving: String,
        onto: String,
        placeAfter: Bool
    ) {
        let orderedIDs = orderedTabIDs(deviceID: device.id, workspaceID: workspaceID)
        guard let insertIndex = TabReorder.insertIndex(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }
        guard let plan = WorkspaceReorder.plan(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[device.id]?.tabs {
            let scoped = current.filter { $0.workspaceID == workspaceID }
            let reordered = WorkspaceReorder.applying(scoped, id: \.tabID, plan: plan)
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[device.id]?.tabs = Self.replacingTabs(
                    current,
                    workspaceID: workspaceID,
                    with: reordered
                )
            }
        }

        Task {
            do {
                try await service(for: device).moveTab(tabID: moving, insertIndex: insertIndex)
                await refresh(device.id)
            } catch {
                await refresh(device.id)
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    private static func replacingTabs(
        _ tabs: [TabInfo],
        workspaceID: String,
        with reordered: [TabInfo]
    ) -> [TabInfo] {
        var result: [TabInfo] = []
        var inserted = false
        for tab in tabs {
            if tab.workspaceID == workspaceID {
                if !inserted {
                    result.append(contentsOf: reordered)
                    inserted = true
                }
            } else {
                result.append(tab)
            }
        }
        if !inserted { result.append(contentsOf: reordered) }
        return result
    }

    /// Creates a workspace rooted at the given directory ("~" expands to the device's
    /// home, local or remote), then selects the shell created with the workspace.
    func createNewSpace(device: Device, directory: String, label: String?) {
        Task {
            do {
                let service = service(for: device)
                var path = directory.trimmingCharacters(in: .whitespaces)
                // The browser leaves paths slash-terminated; herdr wants them bare.
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if path.isEmpty { path = "~" }
                path = try await service.absolutePath(path)
                let trimmedLabel = label?.trimmingCharacters(in: .whitespaces)
                let created = try await service.createWorkspace(
                    label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
                    cwd: path
                )
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
                selectedPane = created.rootPaneID.map { PaneRef(deviceID: device.id, paneID: $0) }
                    ?? firstVisiblePaneRef
                selectedShellID = nil
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Creates a persistent shell tab on the selected Herdr device. Local and
    /// remote terminals use the same server-owned lifecycle and can be detached
    /// and reattached without killing the shell process.
    /// Create a terminal in the current space (or a standalone shell if none).
    func quickNewTerminal() {
        if let shell = selectedShell, !isFilteredOut(shell.device.id) {
            newShellSession(on: shell.device)
            return
        }
        if let space = selectedSpace, !isFilteredOut(space.deviceID), let device = device(space.deviceID) {
            startNewTerminal(device: device, workspaceID: space.workspaceID)
            return
        }
        if let attached = selectedAttachedEntry, !isFilteredOut(attached.device.id) {
            startNewTerminal(device: attached.device, workspaceID: attached.workspaceID)
            return
        }
        let device = deviceFilter.flatMap { self.device($0) } ?? devices.first ?? .local
        newShellSession(on: device)
    }

    /// Explicit per-kind commands start an agent without a picker.
    func quickNewAgent(kind: String) {
        let device: Device
        let workspaceID: String?
        if let space = selectedSpace, !isFilteredOut(space.deviceID), let d = self.device(space.deviceID) {
            device = d
            workspaceID = space.workspaceID
        } else if let attached = selectedAttachedEntry, !isFilteredOut(attached.device.id) {
            device = attached.device
            workspaceID = attached.workspaceID
        } else {
            return
        }
        let bypass = UserDefaults.standard.object(forKey: "agent.bypassDefault") as? Bool ?? true
        startNewAgent(
            device: device,
            kind: kind,
            workspaceID: workspaceID,
            bypass: bypass && (HerdrService.bypassFlags(for: kind) != nil)
        )
    }

    func startNewTerminal(device: Device, workspaceID: String) {
        let ref = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
        if isRetainedSpace(ref) {
            reviveRetainedSpace(ref)
            return
        }
        Task {
            do {
                let paneID = try await service(for: device).createTab(
                    workspaceID: workspaceID,
                    cwd: nil,
                    label: nil
                )
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
                selectedShellID = nil
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// New Agent: a fresh tab in the space plus agent.start. Agent names are
    /// session-global in herdr, so collisions retry with a unique suffix.
    /// `bypass` appends the kind's skip-permissions flag when one is known.
    func startNewAgent(
        device: Device,
        kind: String,
        workspaceID: String?,
        bypass: Bool
    ) {
        let args = bypass ? (HerdrService.bypassFlags(for: kind) ?? []) : []
        Task {
            let service = service(for: device)
            var createdPane: String?
            do {
                var workspaceID = workspaceID
                var reusePane: String?
                if let current = workspaceID,
                   let revived = try await reviveRetainedWorkspace(
                    device: device,
                    workspaceID: current
                   ) {
                    workspaceID = revived.workspaceID
                    reusePane = revived.rootPaneID
                }
                let pane: String
                if let reusePane {
                    pane = reusePane
                } else {
                    pane = try await service.createTab(
                        workspaceID: workspaceID,
                        cwd: nil,
                        label: kind
                    )
                }
                createdPane = pane
                do {
                    try await service.startAgent(
                        name: kind,
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await service.startAgent(
                        name: "\(kind)-\(suffix)",
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                }
                await refresh(device.id)
                isFileManagerActive = false
                if let workspaceID {
                    selectedSpace = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
                }
                selectedPane = PaneRef(deviceID: device.id, paneID: pane)
            } catch {
                if let createdPane {
                    try? await service.closePane(paneID: createdPane)
                }
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    // MARK: - Retained empty spaces

    func rememberClosedSpace(
        deviceID: UUID,
        workspaceID: String,
        label: String?,
        cwd: String?,
        sortIndex: Int
    ) {
        let key = spaceKey(deviceID: deviceID, workspaceID: workspaceID)
        guard !dismissedSpaceKeys.contains(key) else { return }
        if retainedSpaces.contains(where: { $0.deviceID == deviceID && $0.workspaceID == workspaceID }) {
            return
        }
        let space = RetainedSpace(
            deviceID: deviceID,
            workspaceID: workspaceID,
            label: optionalNonEmpty(label ?? "") ?? workspaceID,
            cwd: optionalNonEmpty(cwd ?? ""),
            sortIndex: sortIndex
        )
        retainedSpaces.append(space)
        RetainedSpaceStore.save(retainedSpaces)
        if sessions[deviceID]?.workspaces.contains(where: { $0.workspaceID == workspaceID }) != true {
            let index = min(max(sortIndex, 0), sessions[deviceID]?.workspaces.count ?? 0)
            sessions[deviceID]?.workspaces.insert(space.workspaceInfo, at: index)
        }
    }

    func dismissRetainedSpace(_ ref: SpaceRef) {
        markSpaceDismissed(ref)
        retainedSpaces.removeAll { $0.deviceID == ref.deviceID && $0.workspaceID == ref.workspaceID }
        RetainedSpaceStore.save(retainedSpaces)
        sessions[ref.deviceID]?.workspaces.removeAll { $0.workspaceID == ref.workspaceID }
        if selectedSpace == ref { selectedSpace = nil }
    }

    func markSpaceDismissed(_ ref: SpaceRef) {
        dismissedSpaceKeys.insert(spaceKey(deviceID: ref.deviceID, workspaceID: ref.workspaceID))
    }

    func reviveRetainedSpace(_ ref: SpaceRef) {
        let previous = spaceReviveTask
        spaceReviveTask = Task {
            await previous?.value
            guard let device = device(ref.deviceID) else { return }
            do {
                guard let created = try await reviveRetainedWorkspace(
                    device: device,
                    workspaceID: ref.workspaceID
                ) else { return }
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
                selectedPane = created.rootPaneID.map { PaneRef(deviceID: device.id, paneID: $0) }
                selectedShellID = nil
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    private func reviveRetainedWorkspace(
        device: Device,
        workspaceID: String
    ) async throws -> (workspaceID: String, rootPaneID: String?)? {
        let ref = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
        guard !revivingSpaces.contains(ref), let retained = retainedSpaces.first(
            where: { $0.deviceID == device.id && $0.workspaceID == workspaceID }
        ) else { return nil }
        // Keep the gray row visible until creation and server-side ordering both finish.
        revivingSpaces.insert(ref)
        defer {
            revivingSpaces.remove(ref)
            statusGenerations[device.id, default: 0] &+= 1
            scheduleRefresh(device.id)
        }
        let ordered = session(device.id).workspaces
        let index = ordered.firstIndex { $0.workspaceID == workspaceID } ?? retained.sortIndex
        let before = ordered.dropFirst(max(index + 1, 0)).first {
            !isRetainedSpace(SpaceRef(deviceID: device.id, workspaceID: $0.workspaceID))
        }?.workspaceID
        let service = service(for: device)
        let created = try await service.createWorkspace(label: retained.label, cwd: retained.cwd)
        do {
            try await service.moveWorkspaceBlock(
                workspaceIDs: [created.workspaceID], beforeWorkspaceID: before
            )
        } catch {
            // A failed reorder must leave the original gray space available for retry.
            markSpaceDismissed(SpaceRef(deviceID: device.id, workspaceID: created.workspaceID))
            do {
                try await service.closeWorkspace(workspaceID: created.workspaceID)
            } catch {
                // Cleanup failed: keep the live terminal discoverable; never hide it.
                dismissedSpaceKeys.remove(spaceKey(deviceID: device.id, workspaceID: created.workspaceID))
                throw error
            }
            throw error
        }
        markSpaceDismissed(ref)
        retainedSpaces.removeAll { $0.ref == ref }
        RetainedSpaceStore.save(retainedSpaces)
        if let slot = sessions[device.id]?.workspaces.firstIndex(where: { $0.workspaceID == workspaceID }) {
            sessions[device.id]?.workspaces[slot] = WorkspaceInfo(
                workspaceID: created.workspaceID,
                number: slot,
                label: retained.label,
                paneCount: 1,
                tabCount: 1,
                cwd: retained.cwd
            )
        }
        // Remap the filter before the next snapshot; the old ID would briefly
        // select All Spaces and expose unrelated sessions during restoration.
        if selectedSpace == ref {
            selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
        }
        return created
    }

    private func retainDisappearedSpaces(
        deviceID: UUID,
        previous: [WorkspaceInfo],
        liveIDs: Set<String>,
        paneCWD: [String: String]
    ) {
        for (index, workspace) in previous.enumerated() {
            let key = spaceKey(deviceID: deviceID, workspaceID: workspace.workspaceID)
            if liveIDs.contains(workspace.workspaceID) { continue }
            if dismissedSpaceKeys.contains(key) { continue }
            rememberClosedSpace(
                deviceID: deviceID,
                workspaceID: workspace.workspaceID,
                label: workspace.label,
                cwd: workspace.cwd ?? paneCWD[workspace.workspaceID],
                sortIndex: index
            )
        }
    }

    private func pruneRetainedSpaces(deviceID: UUID, liveIDs: Set<String>) {
        let before = retainedSpaces.count
        retainedSpaces.removeAll { $0.deviceID == deviceID && liveIDs.contains($0.workspaceID) }
        if retainedSpaces.count != before {
            RetainedSpaceStore.save(retainedSpaces)
        }
    }

    private func removeRetainedSpaces(deviceID: UUID) {
        let before = retainedSpaces.count
        retainedSpaces.removeAll { $0.deviceID == deviceID }
        if retainedSpaces.count != before {
            RetainedSpaceStore.save(retainedSpaces)
        }
    }

    private func renameRetainedSpace(_ ref: SpaceRef, label: String) {
        guard let index = retainedSpaces.firstIndex(
            where: { $0.deviceID == ref.deviceID && $0.workspaceID == ref.workspaceID }
        ) else { return }
        retainedSpaces[index].label = label
        RetainedSpaceStore.save(retainedSpaces)
        if let workspaceIndex = sessions[ref.deviceID]?.workspaces.firstIndex(
            where: { $0.workspaceID == ref.workspaceID }
        ), let workspace = sessions[ref.deviceID]?.workspaces[workspaceIndex] {
            sessions[ref.deviceID]?.workspaces[workspaceIndex] = WorkspaceInfo(
                workspaceID: workspace.workspaceID,
                number: workspace.number,
                label: label,
                focused: workspace.focused,
                paneCount: workspace.paneCount,
                tabCount: workspace.tabCount,
                activeTabID: workspace.activeTabID,
                agentStatusRaw: workspace.agentStatusRaw,
                cwd: workspace.cwd
            )
        }
    }

    private func spaceKey(deviceID: UUID, workspaceID: String) -> String {
        "\(deviceID.uuidString)-\(workspaceID)"
    }
}
