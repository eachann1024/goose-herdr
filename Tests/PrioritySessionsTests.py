#!/usr/bin/env python3
"""Priority sidebar partitions and routing: python3 Tests/PrioritySessionsTests.py."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()


def extract(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


# Compile production scope builders, partitions, identities, selection and shortcuts.
parts = [
    extract("    var filteredDevice:", "    /// Aggregate connection state"),
    extract("    enum AttachedEntry: Identifiable", "    struct SpaceEntry:"),
    extract("    var visibleAgents:", "    func terminalEntries(for"),
    extract("    var visibleTerminals:", "    func attention(in"),
    extract("    @Published var selectedSpace:", "    /// Live attaches"),
    extract("    func selectAgent(", "    var selectedShell:"),
    extract("    @Published var selectedShellID:", "    /// In-window device panel"),
    extract("    enum SwitchableSession:", "    func closeShellSession("),
    extract("    var selectedShell:", "    /// Every click"),
    extract("    var selectedEntry:", "    private var firstVisiblePaneRef:"),
    extract("    private func isFilteredOut(", "    /// When jumping into a space"),
    extract("    func quickNewAgent(", "    /// Select the new pane. All Spaces"),
    extract("    var asksForNewSessionSpace:", "    /// Space the sheet preselects"),
]
parts = "\n".join(parts).replace("@Published ", "").replace("UserDefaults.standard", "defaults").replace("private ", "")
status_title = sidebar[sidebar.index('    private var priorityStatusTitle:'):sidebar.index('    private func accessibilityLabel(unread:')].replace('private ', '')
attention = (ROOT / "Packages/HerdrKit/Sources/HerdrKit/Attention.swift").read_text().replace("public ", "")
pane = extract("struct PaneRef:", "\n/// A space herdr dropped")
index_source = (ROOT / 'Sources/GooseAgent/SessionIndexHints.swift').read_text()
index_mapping = index_source[index_source.index('enum SessionSwitchIndex {'):index_source.index('\n    // MARK: - Session index hints')] + '\n}\n'
harness = r'''
import Foundation
''' + pane + r'''
enum AgentStatus { case blocked, done, working, idle, unknown }
struct AgentInfo { var paneID: String; var workspaceID = "w1"; var tabID: String?; var status: AgentStatus; var stateChangeSeq: UInt64?; var launchPending: Bool? }
struct Device { let id: UUID }
enum TerminalAttachTarget { case agent(paneID: String), terminal(terminalID: String) }
enum SidebarSectionID { static let spacesHiddenKey = "sidebar.spacesHidden" }
struct AgentEntry {
    let device: Device; var agent: AgentInfo
    var title: String { agent.paneID }
    var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
}
struct TerminalEntry {
    let device: Device; let pane: AgentInfo
    var terminalID: String { pane.paneID }
    var title: String { pane.paneID }
    var tabID: String? { pane.tabID }
    var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }
}
struct ShellSession { let id: UUID }
struct SpaceEntry { let ref: SpaceRef }
enum NewSessionType: Equatable {
    case choose, terminal
    case agent(String)
}
enum HerdrService { static func bypassFlags(for kind: String) -> String? { nil } }
''' + attention + index_mapping + r'''
class Model {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    var devices: [Device] = []
    var deviceFilter: UUID?
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    var input: [AttachedEntry] = []
    struct State { var agents: [AgentInfo] }
    func session(_ id: UUID) -> State {
        State(agents: input.compactMap {
            guard case .agent(let entry) = $0, entry.device.id == id else { return nil }
            return entry.agent
        })
    }
    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry { AgentEntry(device: device, agent: agent) }
    func terminalEntries(for device: Device) -> [TerminalEntry] {
        input.compactMap {
            guard case .terminal(let entry) = $0, entry.device.id == device.id else { return nil }
            return entry
        }
    }
    func workspaceRank(deviceID: UUID, workspaceID: String) -> Int { workspaceID == "w1" ? 0 : 1 }
    func tabRank(deviceID: UUID, tabID: String?) -> Int { Int(tabID ?? "") ?? Int.max }
    var unreadAgents: Set<AgentUnreadKey> = []
    var shellSessions: [ShellSession] = []
    var startingPanes: Set<PaneRef> = []
    var isFileManagerActive = false
    struct PiLaunch { var pane: PaneRef?; var presented = true }
    var piLaunch: PiLaunch?
    func noteSelectedAttachSession() {}
    func selectShell(_ id: UUID) { selectedShellID = id }
    var newSession: NewSessionType?
    var visibleSpaces: [SpaceEntry] { [] }
    func createNewSession(in: SpaceRef?, type: NewSessionType) {}
''' + parts + r'''
}
struct PriorityRow {
    let entry: AgentEntry
    let model: Model
    var showsSpace = true
''' + status_title + r'''
}
let suite = "priority-sessions-check-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let model = Model(defaults)
let local = Device(id: UUID()), remote = Device(id: UUID())
func agent(_ device: Device, _ pane: String, _ status: AgentStatus, _ space: String = "w1", _ tab: String = "0") -> Model.AttachedEntry {
    .agent(AgentEntry(device: device, agent: AgentInfo(paneID: pane, workspaceID: space, tabID: tab, status: status)))
}
let input: [Model.AttachedEntry] = [
    agent(local, "done", .done), agent(local, "working", .working, "w1", "1"),
    agent(remote, "blocked", .blocked), agent(local, "blocked", .blocked, "w2", "0"),
    agent(remote, "done", .done, "w1", "1"), agent(local, "read", .done, "w2", "1"),
    .terminal(TerminalEntry(device: local, pane: AgentInfo(paneID: "terminal", workspaceID: "w2", tabID: "2", status: .idle))),
    agent(local, "idle", .idle, "w2", "3"), agent(local, "unknown", .unknown, "w2", "4")
]
model.devices = [local, remote]
model.input = input
let ordinary = model.visibleSessions.map(\.id)
model.unreadAgents = Set([input[0], input[4]].map { AgentUnreadKey(deviceID: $0.ref.deviceID, paneID: $0.ref.paneID) })
assert(!model.prioritySessionsEnabled, "absent preference defaults off")
assert(model.sidebarSessions.map(\.id) == ordinary)
defaults.set(true, forKey: Model.prioritySessionsKey)
assert(Model(UserDefaults(suiteName: suite)!).prioritySessionsEnabled, "mode survives a new model/store")
let expected = [3, 2, 0, 4, 1, 5, 6, 7, 8].map { input[$0].id }
assert(model.sidebarSessions.map(\.id) == expected, "blocked then unread; stable order within each partition")
assert(Set(expected).count == input.count, "colliding pane IDs across devices remain distinct")
assert(model.sidebarSessions.filter(model.isPrioritySession).count == 4)
func row(_ entry: Model.AttachedEntry) -> PriorityRow {
    guard case .agent(let agent) = entry else { fatalError() }
    return PriorityRow(entry: agent, model: model)
}
assert(row(input[0]).priorityStatusTitle == String(localized: "Done"))
assert(row(input[2]).priorityStatusTitle == String(localized: "Input needed"))
assert(row(input[1]).priorityStatusTitle == nil, "loading keeps only its existing spinner")
var ordinaryRow = row(input[0])
ordinaryRow.showsSpace = false
assert(ordinaryRow.priorityStatusTitle == nil, "new status labels are bell-only")
let shell = ShellSession(id: UUID())
model.shellSessions = [shell]
assert(model.switchableSessions == model.sidebarSessions.map { .agent($0.ref) } + [.shell(shell.id)])
let chosen = input[0].ref
model.selectAgent(chosen)
assert(model.selectedPane == chosen && model.prioritySessionsEnabled)
assert(model.sidebarSessions.first(where: { $0.ref == chosen })?.id == input[0].id, "acknowledging unread preserves identity")
assert(!model.isPrioritySession(input[0]) && model.sidebarSessions.count == input.count)
assert(row(input[0]).priorityStatusTitle == String(localized: "Viewing"), "held read item is viewing, never an unread label")
assert(model.sidebarSessions.map(\.id) == expected, "click keeps the original priority position")
model.selectAgent(chosen)
assert(model.sidebarSessions.map(\.id) == expected, "reselection is not leaving")
assert(model.switchableSessions == model.sidebarSessions.map { .agent($0.ref) } + [.shell(shell.id)], "shortcut order tracks unread clearing")
let numberedTarget = model.sidebarSessions[2].ref
assert(model.sessionSwitchNumber(for: .agent(numberedTarget)) == 3)
model.selectSwitchableSession(number: 3)
assert(model.selectedPane == numberedTarget && model.prioritySessionsEnabled, "numbered shortcut follows displayed order without leaving mode")
model.selectSwitchableSession(number: 9)
assert(model.selectedShellID == shell.id && model.prioritySessionsEnabled)
model.deviceFilter = local.id
let returnSpace = SpaceRef(deviceID: local.id, workspaceID: "empty")
model.selectedSpace = returnSpace
assert(model.visibleSessions.isEmpty)
assert(!model.sidebarSessions.isEmpty, "empty selected space still exposes other spaces")
assert(model.sidebarSessions.allSatisfy { $0.ref.deviceID == local.id }, "device filter is never widened")
assert(model.sidebarSessions.contains { $0.workspaceID == "w2" && !$0.isAgent }, "terminals also span spaces")
model.selectAgent(input[3].ref)
assert(model.selectedSpace == returnSpace && model.prioritySessionsEnabled, "cross-space selection preserves return filter and mode")
defaults.set(false, forKey: Model.prioritySessionsKey)
assert(model.selectedSpace == returnSpace && model.sidebarSessions.isEmpty, "closing restores the empty return space")
model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
let returnOrder = model.visibleSessions.map(\.id)
defaults.set(true, forKey: Model.prioritySessionsKey)
model.selectAgent(input[3].ref)
defaults.set(false, forKey: Model.prioritySessionsKey)
assert(model.sidebarSessions.map(\.id) == returnOrder, "closing restores original filtered tab order")
defaults.set(true, forKey: Model.prioritySessionsKey)
defaults.set(true, forKey: SidebarSectionID.spacesHiddenKey)
assert(!model.prioritySessionsEnabled, "hidden Spaces uses the ordinary shortcut order")
assert(defaults.bool(forKey: Model.prioritySessionsKey), "hiding does not erase the mode preference")
// Isolated lifecycle: no invented initial history, real activity, retention and cleanup.
let lifecycle = Model(defaults)
defaults.set(false, forKey: SidebarSectionID.spacesHiddenKey)
lifecycle.devices = [local, remote]
let a = agent(local, "a", .done), b = agent(local, "b", .done, "w2")
let c = agent(local, "c", .working, "w2", "1")
let d = agent(remote, "a", .working)
lifecycle.input = [a, b, c, d]
func snapshots(_ entries: [Model.AttachedEntry], _ device: Device) -> [AgentInfo] {
    entries.compactMap { if case .agent(let e) = $0, e.device.id == device.id { return e.agent }; return nil }
}
func update(_ entry: Model.AttachedEntry, _ status: AgentStatus, _ seq: UInt64?) {
    let index = lifecycle.input.firstIndex { $0.ref == entry.ref }!
    guard case .agent(var e) = lifecycle.input[index] else { fatalError() }
    e.agent.status = status
    e.agent.stateChangeSeq = seq
    lifecycle.input[index] = .agent(e)
}
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, remote), deviceID: remote.id)
assert(lifecycle.loadingOrder.isEmpty && lifecycle.handledPriority.isEmpty)
assert(lifecycle.sidebarSessions.map(\.ref) == [c.ref, d.ref, a.ref, b.ref], "initial working is loading, not a fabricated recent activity")
lifecycle.unreadAgents = [a, b].reduce(into: []) { $0.insert(AgentUnreadKey(deviceID: $1.ref.deviceID, paneID: $1.ref.paneID)) }
let beforeClick = lifecycle.sidebarSessions.map(\.ref)
lifecycle.selectAgent(a.ref)
assert(lifecycle.sidebarSessions.map(\.ref) == beforeClick)
assert(!lifecycle.isUnread(AgentEntry(device: local, agent: snapshots([a], local)[0])))
lifecycle.selectAgent(b.ref)
assert(lifecycle.handledPriority == [a.ref])
lifecycle.selectShell(shell.id)
assert(lifecycle.handledPriority == [b.ref, a.ref], "shell leaves priority; recently handled first")
assert(lifecycle.sidebarSessions.map(\.ref) == [c.ref, d.ref, b.ref, a.ref])
lifecycle.selectAgent(a.ref)
assert(!lifecycle.isPriorityGroup(a), "returning to handled does not manufacture priority")
update(a, .working, 7)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.sidebarSessions.first?.ref == a.ref)
assert(!lifecycle.handledPriority.contains(a.ref))
let order = lifecycle.loadingOrder
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.loadingOrder == order, "identical snapshots are not sends")
update(d, .working, 1)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, remote), deviceID: remote.id) // establish optional seq
update(d, .working, 2)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, remote), deviceID: remote.id)
assert(lifecycle.sidebarSessions.first?.ref == d.ref, "observed global order, not cross-device server counters")
update(a, .done, 8)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(!lifecycle.isPriorityGroup(lifecycle.input[0]), "viewed completion does not invent unread")
lifecycle.unreadAgents.insert(AgentUnreadKey(deviceID: local.id, paneID: "a"))
lifecycle.selectAgent(a.ref)
assert(lifecycle.isPriorityGroup(lifecycle.input[0]))
update(a, .working, 9)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.priorityHold == nil && lifecycle.sidebarSessions.first?.ref == a.ref, "new working releases hold")
lifecycle.noteLoadingEvent(.done, paneID: "a", deviceID: local.id)
update(a, .done, 10)
lifecycle.noteLoadingEvent(.working, paneID: "a", deviceID: local.id)
update(a, .working, 11)
let eventRank = lifecycle.loadingOrder[a.ref]
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.loadingOrder[a.ref] == eventRank, "event and snapshot count once")
update(a, .working, 1)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.loadingOrder[a.ref] == nil, "server reset establishes a baseline")
lifecycle.startingPanes.insert(b.ref)
lifecycle.noteLoading(b.ref)
let startRank = lifecycle.loadingOrder[b.ref]
update(b, .working, 2)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.loadingOrder[b.ref] == startRank, "startup is not counted twice")
lifecycle.startingPanes.remove(b.ref)
update(a, .blocked, 3)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
lifecycle.selectAgent(a.ref)
lifecycle.selectShell(shell.id)
assert(lifecycle.isPriorityGroup(lifecycle.input[0]) && !lifecycle.handledPriority.contains(a.ref), "blocked never demoted by leaving")
// A pane may become priority while already selected; leaving still acknowledges it.
lifecycle.selectAgent(c.ref)
update(c, .done, 4)
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
lifecycle.unreadAgents.insert(AgentUnreadKey(deviceID: local.id, paneID: "c"))
lifecycle.selectedPane = nil
assert(lifecycle.handledPriority.first == c.ref, "leaving a completion observed while selected is a real handled event")
defaults.set(false, forKey: Model.prioritySessionsKey)
assert(lifecycle.sidebarSessions.first?.ref == c.ref, "ordinary mode puts a newly completed session first")
let recentRanks = lifecycle.loadingOrder
defaults.set(true, forKey: Model.prioritySessionsKey)
assert(lifecycle.loadingOrder == recentRanks, "bell toggle preserves observed recent ordering")
// Creating a session is not activity; its first completion is.
defaults.set(false, forKey: Model.prioritySessionsKey)
let creation = Model(defaults)
creation.devices = [local]
let existing = agent(local, "existing", .done)
let fresh = agent(local, "fresh", .idle, "w1", "1")
creation.input = [existing, fresh]
creation.noteLoadingSnapshot(snapshots(creation.input, local), deviceID: local.id)
creation.startingPanes.insert(fresh.ref)
creation.noteLoadingEvent(.working, paneID: "fresh", deviceID: local.id)
creation.input[1] = agent(local, "fresh", .working, "w1", "1")
creation.noteLoadingSnapshot(snapshots(creation.input, local), deviceID: local.id)
assert(creation.loadingOrder[fresh.ref] == nil, "launch event and snapshot do not manufacture recency")
assert(creation.sidebarSessions.last?.ref == fresh.ref, "new session stays at the bottom")
creation.startingPanes.remove(fresh.ref)
creation.noteLoadingEvent(.done, paneID: "fresh", deviceID: local.id)
creation.input[1] = agent(local, "fresh", .done, "w1", "1")
assert(creation.sidebarSessions.first?.ref == fresh.ref, "real completion moves the new session to the top")
defaults.set(true, forKey: Model.prioritySessionsKey)
// Missing seq in the same snapshot is a tie, never fabricated iteration order.
let ties = Model(defaults)
ties.devices = [local]
ties.input = [a, b]
ties.noteLoadingSnapshot(snapshots(ties.input, local), deviceID: local.id)
let missingSeqWorking = [AgentInfo(paneID: "b", status: .working), AgentInfo(paneID: "a", status: .working)]
ties.noteLoadingSnapshot(missingSeqWorking, deviceID: local.id)
assert(ties.loadingOrder[a.ref] == ties.loadingOrder[b.ref], "same-batch missing sequence ties")
ties.input = [agent(local, "a", .working), agent(local, "b", .working, "w2")]
assert(ties.sidebarSessions.map(\.ref) == ties.visibleSessions.map(\.ref), "equal loading ranks preserve original order")
defaults.set(false, forKey: Model.prioritySessionsKey)
assert(ties.sidebarSessions.map(\.ref) == ties.visibleSessions.map(\.ref), "ordinary equal activity ranks preserve original order")
defaults.set(true, forKey: Model.prioritySessionsKey)
// Hold, handled and prune must isolate identical pane numbers on different hosts.
let isolated = Model(defaults)
isolated.devices = [local, remote]
isolated.input = [agent(local, "same", .done), agent(remote, "same", .done)]
let localSame = isolated.input[0], remoteSame = isolated.input[1]
isolated.unreadAgents = Set(isolated.input.map { AgentUnreadKey(deviceID: $0.ref.deviceID, paneID: $0.ref.paneID) })
isolated.selectAgent(localSame.ref)
assert(isolated.isPriorityGroup(remoteSame) && isolated.isPrioritySession(remoteSame), "remote identity remains unread")
isolated.selectAgent(remoteSame.ref)
assert(isolated.handledPriority == [localSame.ref], "local handled state")
isolated.prunePriorityState(deviceID: local.id, paneIDs: [])
assert(isolated.handledPriority.isEmpty && isolated.isPriorityGroup(remoteSame), "local prune preserves remote hold")
isolated.selectShell(shell.id)
assert(isolated.handledPriority == [remoteSame.ref], "remote handled state")
isolated.prunePriorityState(deviceID: local.id, paneIDs: [])
assert(isolated.handledPriority == [remoteSame.ref], "local reconnect cannot clear remote handled state")
// A held item stays put while Files is shown; Files is not a session selection.
update(c, .done, 4)
lifecycle.unreadAgents.insert(AgentUnreadKey(deviceID: local.id, paneID: "c"))
lifecycle.selectAgent(c.ref)
lifecycle.isFileManagerActive = true
assert(lifecycle.isPriorityGroup(lifecycle.input[2]))
lifecycle.prunePriorityState(deviceID: local.id, paneIDs: [])
assert(lifecycle.loadingOrder.keys.allSatisfy { $0.deviceID == remote.id }, "prune isolates device activity")
assert(lifecycle.loadingBaseline[local.id]?.isEmpty == true && lifecycle.priorityHold == nil)
let ranks = lifecycle.loadingOrder
lifecycle.loadingBaseline[local.id] = nil
lifecycle.noteLoadingSnapshot(snapshots(lifecycle.input, local), deviceID: local.id)
assert(lifecycle.loadingOrder == ranks, "reconnect initial snapshot is not new activity")
defaults.set(false, forKey: Model.prioritySessionsKey)
assert(lifecycle.sidebarSessions.map(\.ref) == [d.ref, a.ref, b.ref, c.ref], "ordinary mode uses observed activity while preserving ties")
defaults.set(true, forKey: Model.prioritySessionsKey)
assert(lifecycle.loadingOrder == ranks, "mode toggle preserves in-memory activity")
// Per-kind Agent shortcuts fix the kind and ask for the space: nothing is
// created from whatever device/space the filter or the focused pane happens to name.
model.deviceFilter = nil
model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w2")
model.selectAgent(input[4].ref) // same pane number as local, but on remote
for bell in [true, false] {
    defaults.set(bell, forKey: Model.prioritySessionsKey)
    model.newSession = nil
    model.quickNewAgent(kind: "pi")
    assert(model.newSession == .agent("pi"), "the shortcut opens the sheet on its own kind")
}
defaults.set(true, forKey: Model.prioritySessionsKey)
defaults.set(true, forKey: SidebarSectionID.spacesHiddenKey)
model.newSession = nil
model.quickNewAgent(kind: "codex")
assert(model.newSession == .agent("codex"), "hidden Spaces still asks through the sheet")
defaults.set(false, forKey: SidebarSectionID.spacesHiddenKey)
model.deviceFilter = local.id
model.newSession = nil
model.quickNewAgent(kind: "pi")
assert(model.newSession == .agent("pi"), "a device filter does not shortcut the space question")
model.deviceFilter = nil
model.selectShell(shell.id)
model.newSession = nil
model.quickNewAgent(kind: "pi")
assert(model.newSession == .agent("pi"), "an active standalone shell does not resolve the space either")
model.selectedShellID = nil
model.newSession = nil
model.quickNewAgent(kind: "pi")
assert(model.newSession == .agent("pi"), "confirm is the only way a per-kind launch starts")
model.input = []
assert(model.sidebarSessions.isEmpty)
assert(AgentUnread.applying(previous: [:], agents: [AgentInfo(paneID: "initial", status: .done)], unread: [], deviceID: local.id).isEmpty)
print("PASS: priority status labels/hold, shell leave, loading observations, lifecycle, cleanup, identity, scope, shortcuts and per-kind sheet routing")
'''

assert 'startingPanes.insert(paneRef)\n                noteLoading(paneRef)' not in source, 'creation itself must not assign an activity rank'

# UI boundaries: one stable ForEach (not separate identity trees per section),
# focus-local Escape rather than an application-wide command/monitor.
assert '@AppStorage(AppModel.prioritySessionsKey) private var prioritySessions = false' in sidebar
assert 'ForEach(sessions)' in sidebar
assert sidebar.index('ForEach(sessions)') < sidebar.index('if let launch = model.piLaunch, launch.pane == nil') < sidebar.index('ForEach(model.shellSessions)'), 'launch placeholder stays at the bottom of attached sessions, matching the new row'
assert '.onKeyPress(.escape)' in sidebar
assert '.focused($bellFocused)' in sidebar
assert '.focusable(showsPrioritySessions)' in sidebar
assert '.onKeyPress(keys: [.return, .space])' in sidebar
assert 'prioritySessions = false' in sidebar
assert 'prioritySessions' not in extract('    func selectAgent(', '    var selectedShell:')
assert 'prioritySessions' not in extract('    func reveal(', '    func toggleFileManager(')
assert 'if spacesExpanded && !showsPrioritySessions' in sidebar
assert 'items: model.visibleSessions' in sidebar, 'drag source remains the original tab order'
assert sidebar.count('showsSpace: showsPrioritySessions') == 2
assert 'if let path, !showsSpace' in sidebar
assert 'if !showsPrioritySessions, sessions.isEmpty' in sidebar
header = sidebar[sidebar.index('    private func sectionHeader'):sidebar.index('    private var allSpacesRow')]
bell_header = header[header.index('if showsPrioritySessions {'):header.index('} else {')]
assert 'Text(title)' in bell_header and 'Button' not in bell_header, 'bell header cannot alter the persisted expansion state'
assert sidebar.count('spacesExpanded.toggle()') == 1
assert 'selectedSpace =' not in extract('    private func agents(in', '    func attention(in')
assert 'selectedSpace =' not in extract('    func selectAgent(', '    var selectedShell:')
assert '.accessibilityAddTraits(prioritySessions ? .isSelected : [])' in sidebar
catalog = json.loads((ROOT / 'Resources/Localizable.xcstrings').read_text())['strings']
for key in ['Priority sessions', 'High priority', 'Other sessions', 'No sessions need attention', 'On', 'Off', 'Input needed', 'Done', 'Viewing', 'Terminal']:
    for language in ['en', 'zh-Hans']:
        assert catalog[key]['localizations'][language]['stringUnit']['value']

assert 'sectionHeader(showsPrioritySessions ? "High priority" : "Spaces")' in sidebar
assert '.foregroundStyle(Theme.accent)' in bell_header
assert 'sessionGroupHeader("High priority"' not in sidebar
assert sidebar.count('sessionGroupHeader("Other sessions")') == 2
empty_priority = sidebar[sidebar.index('                            if showsPrioritySessions, !sessions.contains(where: model.isPriorityGroup) {'):sidebar.index('                            ForEach(sessions)')]
assert sidebar.count('Text("No sessions need attention")') == 1
for style in ['Text("No sessions need attention")', '.font(Theme.sidebarRowMeta)',
              '.foregroundStyle(Theme.textSecondary)', '.padding(8)',
              '.frame(maxWidth: .infinity, alignment: .leading)']:
    assert style in empty_priority
assert 'sessionGroupHeader' not in empty_priority, 'no duplicate header or reserved header height'
group_header = sidebar[sidebar.index('    private func sessionGroupHeader'):sidebar.index('    private var emptySessionsHint')]
assert 'isEmpty' not in group_header and '.accessibilityAddTraits(.isHeader)' in group_header
assert '.font(Theme.sidebarGroupHeader)' in sidebar
assert sidebar.count('.frame(minHeight: showsSpace ? 54 : 51, maxHeight: showsSpace ? nil : 51)') == 2
assert sidebar.count('.layoutPriority(showsSpace ? 1 : 0)') == 2, 'space truncates before the device chip'
assert '.fontWeight(priority ? .semibold : .regular)' in sidebar
assert '.fixedSize(horizontal: true, vertical: false)' in sidebar, 'status labels do not overlap the title'
assert '!showsSpace || agent.status != .blocked' in sidebar, 'real blocked is not hidden by the Pi launch placeholder'
assert catalog['High priority']['localizations']['zh-Hans']['stringUnit']['value'] == '优先处理'
assert catalog['No sessions need attention']['localizations']['zh-Hans']['stringUnit']['value'] == '暂无待处理'

with tempfile.TemporaryDirectory(prefix='priority-sessions-') as tmp:
    swift = Path(tmp) / 'Check.swift'
    swift.write_text(harness)
    subprocess.run(['swift', str(swift)], check=True)

# Restore the production init with no property observers, matching Swift init semantics.
restore = extract("    init() {\n        let loaded = DeviceStore().load()", "    // MARK: - Derived state")
restore = restore.replace("UserDefaults.standard", "defaults")
restore_harness = r"""
import Foundation
""" + pane + r"""
struct Device { let id: UUID }
let local = Device(id: UUID()), remote = Device(id: UUID())
struct DeviceStore { func load() -> [Device] { [local, remote] } }
enum SidebarSectionID { static let spacesHiddenKey = "sidebar.spacesHidden" }
let suite = "priority-restore-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
class Restored {
    static let selectedPaneKey = "session.selectedPane"
    static let selectedSpaceKey = "session.selectedSpace"
    static let deviceFilterKey = "session.deviceFilter"
    var devices: [Device] = []
    var deviceFilter: UUID?
    var selectedPane: PaneRef?
    var selectedSpace: SpaceRef?
""" + restore + r"""
}
for filter in [local.id, remote.id, nil, UUID()] {
    let ref = PaneRef(deviceID: remote.id, paneID: "w1:p1")
    defaults.set(try! JSONEncoder().encode(ref), forKey: Restored.selectedPaneKey)
    defaults.set(filter?.uuidString, forKey: Restored.deviceFilterKey)
    let restored = Restored()
    if filter == local.id {
        assert(restored.selectedPane == nil)
        assert(defaults.data(forKey: Restored.selectedPaneKey) == nil, "clear persisted out-of-scope pane during init")
    } else {
        assert(restored.selectedPane == ref, "matching, absent or removed filter keeps valid pane")
        assert(defaults.data(forKey: Restored.selectedPaneKey) != nil)
    }
}
print("PASS: production init restores only in-scope pane and clears the persisted key")
"""

# Source wiring plus executable production drop callbacks against minimal transport stubs.
# This does not inject GUI drag events or exercise the AppKit registration lifecycle.
drag = (ROOT / "Sources/GooseAgent/SpaceRowDrag.swift").read_text()
assert sidebar.count('allowsDrag: !model.prioritySessionsEnabled,') == 2
for name, end in [('AgentRowDragHost', 'struct TerminalRowDragHost'),
                  ('TerminalRowDragHost', 'final class SidebarRowDragNSView')]:
    wrapper = drag[drag.index('struct ' + name):drag.index(end)]
    for wiring in ['var allowsDrag = true', 'allowsDrag: allowsDrag,',
                   'onClick: onClick,', 'onDoubleClick: onRename,', 'menuItems: [']:
        assert wiring in wrapper
assert 'guard allowsDrag, let down = downEvent, !didDrag else { return }' in drag
assert 'if allowsDrag { view.registerForDraggedTypes([pasteboardType]) }' in drag
assert 'view.unregisterDraggedTypes()' in drag
reset = sidebar[sidebar.index('.onChange(of: showsPrioritySessions)'):sidebar.index('// Only SwiftUI focus')]
for state in ['draggingSpaceID', 'spaceDrop', 'draggingSessionID', 'sessionDrop']:
    assert state + ' = nil' in reset
assert 'model.objectWillChange.send()' in reset
callbacks = drag[drag.index('    override func draggingEntered'):drag.index('    /// Snapshot the SwiftUI row')]
read_id = drag[drag.index('    private func draggedID'):drag.index('\n}\n\n/// NSMenu')]
drag_harness = r"""
struct NSDragOperation: OptionSet {
    let rawValue: Int
    static let move = Self(rawValue: 1)
}
struct Pasteboard { func string(forType: String) -> String? { "device-pane" } }
struct NSDraggingInfo { let draggingPasteboard = Pasteboard() }
class DropHost {
    var allowsDrag = true
    let pasteboardType = "session"
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?
    func placeAfter(_ sender: NSDraggingInfo) -> Bool { true }
""" + callbacks.replace('override ', '') + read_id + r"""
}
let host = DropHost(), sender = NSDraggingInfo()
var hovered = 0, dropped = 0
host.onDropHover = { _ in hovered += 1 }
host.onDrop = { id, _ in assert(id == "device-pane"); dropped += 1 }
assert(host.draggingEntered(sender) == .move)
host.allowsDrag = false // already-entered drag must not keep callbacks after mode switch
assert(host.draggingEntered(sender).isEmpty && host.draggingUpdated(sender).isEmpty)
assert(!host.prepareForDragOperation(sender) && !host.performDragOperation(sender))
assert(hovered == 1 && dropped == 0)
host.allowsDrag = true
assert(host.draggingUpdated(sender) == .move)
assert(host.prepareForDragOperation(sender) && host.performDragOperation(sender))
assert(hovered == 2 && dropped == 1)
print("PASS: disabled entered/updated/prepare/drop callbacks; ordinary-mode drop resumes")
"""
for name, check in [('restore', restore_harness), ('drop', drag_harness)]:
    with tempfile.TemporaryDirectory(prefix='priority-' + name + '-') as tmp:
        swift = Path(tmp) / 'Check.swift'
        swift.write_text(check)
        subprocess.run(['swift', str(swift)], check=True)

# Reuse the production-extraction check for New Session targets and standalone shells.
subprocess.run(['python3', str(ROOT / 'Tests/NewSessionSheetTests.py')], check=True)

# Decode the production wire model, including old servers and status-event copies.
models = (ROOT / "Packages/HerdrKit/Sources/HerdrKit/Models.swift").read_text()
models = models[:models.index("public struct WorkspaceInfo:")]
with tempfile.TemporaryDirectory(prefix="priority-wire-") as tmp:
    swift = Path(tmp) / "Check.swift"
    swift.write_text(models + r'''
let wire = #"{"workspace_id":"w1","tab_id":"t1","pane_id":"p1","agent_status":"working","state_change_seq":18446744073709551615}"#.data(using: .utf8)!
let agent = try JSONDecoder().decode(AgentInfo.self, from: wire)
assert(agent.stateChangeSeq == UInt64.max)
assert(agent.updatingStatus(.done).stateChangeSeq == UInt64.max)
let old = #"{"workspace_id":"w1","tab_id":"t1","pane_id":"p1"}"#.data(using: .utf8)!
let legacy = try JSONDecoder().decode(AgentInfo.self, from: old)
assert(legacy.stateChangeSeq == nil)
print("PASS: state_change_seq UInt64 decoding, optional legacy field and event copy")
''')
    subprocess.run(["swift", str(swift)], check=True)
