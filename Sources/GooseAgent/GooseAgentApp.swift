import AppKit
import Darwin
import HerdrKit
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

/// Holds app termination open long enough to tear the SSH tunnels down: without
/// `.terminateLater` the process dies before the teardown task gets to run, and the
/// `ssh` children survive with PPID 1 along with their sockets.
///
/// The delegate owns the model rather than borrowing it from the window: closing the
/// last window (⌘W) would otherwise drop the only strong reference, and the quit that
/// follows would find nothing left to tear down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Global AppKit focus-ring kill for chrome controls (see FocusRing.swift).
        HerdrFocusRing.install()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.hasKeepAliveWork
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

private struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

/// Commands do not observe AppModel changes through its reference. Publish a
/// value separately so split menu availability follows the displayed group.
private struct TerminalSplitTreeFocusedValueKey: FocusedValueKey {
    typealias Value = TerminalSplitTree
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }

    var terminalSplitTree: TerminalSplitTree? {
        get { self[TerminalSplitTreeFocusedValueKey.self] }
        set { self[TerminalSplitTreeFocusedValueKey.self] = newValue }
    }
}

/// Routes ⌘W to Settings/panels. Settings becomes `mainWindow` when focused,
/// so comparing against main is not enough to tell it apart from the console.
enum CloseCommandRouting {
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "settings"
            || window.title == String(localized: "Settings")
    }

    static func shouldDismissKeyWindow(_ key: NSWindow?, main: NSWindow?) -> Bool {
        guard let key else { return false }
        if isSettingsWindow(key) { return true }
        return key !== main
    }
}

@main
struct GooseAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.terminalSplitTree) private var focusedSplitTree
    private var focusedHasTerminalSplits: Bool? { focusedSplitTree.map { $0.leaves.count > 1 } }

    init() {
        if ProcessInfo.processInfo.environment[SSHCredentialStore.askPassModeEnvironmentKey] == "1" {
            Self.runSSHAskPass()
        }
        AppLanguage.synchronize()
        SSHCredentialStore.purgeAuthorizations()
        TerminalDefaults.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
                .onAppear { Self.applyTheme(themePreference) }
                .onChange(of: themePreference) { _, newValue in
                    Self.applyTheme(newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // herdrm is a single-window console: a second window would duplicate the
            // whole device tree, so New Window gives up ⌘N to New Space.
            CommandGroup(replacing: .newItem) {
                let _ = shortcutsRevision
                Button("New") { focusedModel?.showNewItem = true }
                    .keyboardShortcut(AppShortcuts.chord(for: .newItem).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .newItem).modifiers)
                    .disabled(focusedModel == nil)
                Button("New Terminal") { focusedModel?.quickNewTerminal() }
                    .keyboardShortcut(AppShortcuts.chord(for: .quickNewTerminal).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .quickNewTerminal).modifiers)
                    .disabled(focusedModel == nil)
                Button("New Space") { focusedModel?.showNewSpace = true }
                    .keyboardShortcut(AppShortcuts.chord(for: .newSpace).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .newSpace).modifiers)
                    .disabled(focusedModel == nil)
            }

            CommandMenu(String(localized: "Agent")) {
                let _ = shortcutsRevision
                AgentKindCommandItems(model: appDelegate.model, focusedModel: focusedModel)
            }

            CommandMenu("Terminal") {
                let _ = shortcutsRevision
                Button("Split Vertically") { focusedModel?.splitFocusedTerminal(.vertical) }
                    .keyboardShortcut(AppShortcuts.chord(for: .splitVertical).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .splitVertical).modifiers)
                    .disabled(focusedHasTerminalSplits == nil)
                Button("Split Horizontally") { focusedModel?.splitFocusedTerminal(.horizontal) }
                    .keyboardShortcut(AppShortcuts.chord(for: .splitHorizontal).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .splitHorizontal).modifiers)
                    .disabled(focusedHasTerminalSplits == nil)
                Divider()
                Button("Focus Left Pane") { focusedModel?.focusSplit(.left) }
                    .keyboardShortcut(AppShortcuts.chord(for: .focusLeft).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .focusLeft).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.left) == nil)
                Button("Focus Right Pane") { focusedModel?.focusSplit(.right) }
                    .keyboardShortcut(AppShortcuts.chord(for: .focusRight).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .focusRight).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.right) == nil)
                Button("Focus Top Pane") { focusedModel?.focusSplit(.up) }
                    .keyboardShortcut(AppShortcuts.chord(for: .focusUp).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .focusUp).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.up) == nil)
                Button("Focus Bottom Pane") { focusedModel?.focusSplit(.down) }
                    .keyboardShortcut(AppShortcuts.chord(for: .focusDown).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .focusDown).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.down) == nil)
                Divider()
                Button("Swap with Left Pane") { focusedModel?.swapSplit(.left) }
                    .keyboardShortcut(AppShortcuts.chord(for: .swapLeft).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .swapLeft).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.left) == nil)
                Button("Swap with Right Pane") { focusedModel?.swapSplit(.right) }
                    .keyboardShortcut(AppShortcuts.chord(for: .swapRight).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .swapRight).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.right) == nil)
                Button("Swap with Top Pane") { focusedModel?.swapSplit(.up) }
                    .keyboardShortcut(AppShortcuts.chord(for: .swapUp).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .swapUp).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.up) == nil)
                Button("Swap with Bottom Pane") { focusedModel?.swapSplit(.down) }
                    .keyboardShortcut(AppShortcuts.chord(for: .swapDown).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .swapDown).modifiers)
                    .disabled(focusedSplitTree?.neighbor(.down) == nil)
                Divider()
                Button("Widen Active Pane") { focusedModel?.resizeSplit(along: .vertical, grow: true) }
                    .keyboardShortcut(AppShortcuts.chord(for: .widenPane).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .widenPane).modifiers)
                    .disabled(focusedHasTerminalSplits != true)
                Button("Narrow Active Pane") { focusedModel?.resizeSplit(along: .vertical, grow: false) }
                    .keyboardShortcut(AppShortcuts.chord(for: .narrowPane).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .narrowPane).modifiers)
                    .disabled(focusedHasTerminalSplits != true)
                Button("Grow Active Pane") { focusedModel?.resizeSplit(along: .horizontal, grow: true) }
                    .keyboardShortcut(AppShortcuts.chord(for: .growPane).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .growPane).modifiers)
                    .disabled(focusedHasTerminalSplits != true)
                Button("Shrink Active Pane") { focusedModel?.resizeSplit(along: .horizontal, grow: false) }
                    .keyboardShortcut(AppShortcuts.chord(for: .shrinkPane).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .shrinkPane).modifiers)
                    .disabled(focusedHasTerminalSplits != true)
                Divider()
                Button("Equalize Splits") { focusedModel?.equalizeSplits() }
                    .keyboardShortcut(AppShortcuts.chord(for: .equalizeSplits).keyEquivalent,
                                      modifiers: AppShortcuts.chord(for: .equalizeSplits).modifiers)
                    .disabled(focusedHasTerminalSplits != true)

            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W peels the onion: secondary window → split → standalone
                // terminal → leave Files → pane → empty space. The window is
                // last, and only when no session or space remains.
                let _ = shortcutsRevision
                Button(closeButtonTitle) {
                    performCloseCommand()
                }
                .keyboardShortcut(AppShortcuts.chord(for: .close).keyEquivalent,
                                  modifiers: AppShortcuts.chord(for: .close).modifiers)
            }

            CommandGroup(after: .sidebar) {
                // ⌘1…8 → nth session in sidebar order (mixed sessions → local shells).
                // ⌘9 → last session (browser-style). Scoped by selected space when any.
                Button("Go to Session 1") {
                    focusedModel?.selectSwitchableSession(number: 1)
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 2") {
                    focusedModel?.selectSwitchableSession(number: 2)
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 3") {
                    focusedModel?.selectSwitchableSession(number: 3)
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 4") {
                    focusedModel?.selectSwitchableSession(number: 4)
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 5") {
                    focusedModel?.selectSwitchableSession(number: 5)
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 6") {
                    focusedModel?.selectSwitchableSession(number: 6)
                }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 7") {
                    focusedModel?.selectSwitchableSession(number: 7)
                }
                .keyboardShortcut("7", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 8") {
                    focusedModel?.selectSwitchableSession(number: 8)
                }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(focusedModel == nil)
                Button("Go to Session 9") {
                    focusedModel?.selectSwitchableSession(number: 9)
                }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(focusedModel == nil)
                Divider()
                // ⌃1 is All Spaces; ⌃2…9,0 follow sidebar space order.
                // 0 is the 10th item (keyboard row), not last.
                Button("Go to Space 1") {
                    focusedModel?.selectSwitchableSpace(number: 1)
                }
                .keyboardShortcut("1", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 2") {
                    focusedModel?.selectSwitchableSpace(number: 2)
                }
                .keyboardShortcut("2", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 3") {
                    focusedModel?.selectSwitchableSpace(number: 3)
                }
                .keyboardShortcut("3", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 4") {
                    focusedModel?.selectSwitchableSpace(number: 4)
                }
                .keyboardShortcut("4", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 5") {
                    focusedModel?.selectSwitchableSpace(number: 5)
                }
                .keyboardShortcut("5", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 6") {
                    focusedModel?.selectSwitchableSpace(number: 6)
                }
                .keyboardShortcut("6", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 7") {
                    focusedModel?.selectSwitchableSpace(number: 7)
                }
                .keyboardShortcut("7", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 8") {
                    focusedModel?.selectSwitchableSpace(number: 8)
                }
                .keyboardShortcut("8", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 9") {
                    focusedModel?.selectSwitchableSpace(number: 9)
                }
                .keyboardShortcut("9", modifiers: .control)
                .disabled(focusedModel == nil)
                Button("Go to Space 0") {
                    focusedModel?.selectSwitchableSpace(number: 0)
                }
                .keyboardShortcut("0", modifiers: .control)
                .disabled(focusedModel == nil)
            }
        }

        // Settings has its own full-height sidebar and native window controls.
        Window(String(localized: "Settings"), id: "settings") {
            SettingsView(model: appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: SettingsLayout.width, height: SettingsLayout.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsWindowButton()
            }
        }
    }

    private var closeTargetModel: AppModel {
        focusedModel ?? appDelegate.model
    }

    private var closeButtonTitle: String {
        if isSecondaryKeyWindow { return String(localized: "Close") }
        let model = closeTargetModel
        if model.closeCommandAction() == .closeSplit { return String(localized: "Close Split") }
        if model.selectedShell != nil { return String(localized: "Close Terminal") }
        if model.isFileManagerActive { return String(localized: "Close Files") }
        if let attached = model.selectedAttachedEntry {
            return attached.isAgent
                ? String(localized: "Close Agent")
                : String(localized: "Close Terminal")
        }
        if model.selectedSpace != nil { return String(localized: "Close Space") }
        return String(localized: "Close")
    }

    /// Settings / panels that aren't the main console — ⌘W should just dismiss them.
    private var isSecondaryKeyWindow: Bool {
        CloseCommandRouting.shouldDismissKeyWindow(NSApp.keyWindow, main: NSApp.mainWindow)
    }

    private func performCloseCommand() {
        if isSecondaryKeyWindow {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        if closeTargetModel.performCloseCommand() == .closeWindow {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    static func applyTheme(_ preference: String) {
        switch preference {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Split commands



    private static func runSSHAskPass() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[SSHCredentialStore.authorizationIDEnvironmentKey],
              let authorizationID = UUID(uuidString: rawID),
              let password = try? SSHCredentialStore.consumePassword(authorizationID: authorizationID)
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(Data("\(password)\n".utf8))
        Darwin.exit(EXIT_SUCCESS)
    }
}


/// Opens the custom Settings window (⌘, / menu / sidebar gear).
private struct OpenSettingsWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0

    var body: some View {
        let _ = shortcutsRevision  // the menu key equivalent follows a remap
        return Button(String(localized: "Settings…")) {
            openWindow(id: "settings")
            // Bring to front if already open.
            DispatchQueue.main.async {
                for window in NSApp.windows where CloseCommandRouting.isSettingsWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .keyboardShortcut(AppShortcuts.chord(for: .settings).keyEquivalent,
                          modifiers: AppShortcuts.chord(for: .settings).modifiers)
    }
}


/// Display name for an agent kind; an unknown kind falls back to its own name.
enum AgentKindLabel {
    static func display(_ kind: String) -> String {
        switch kind {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini"
        case "grok": return "Grok"
        case "hermes": return "Hermes"
        case "kimi": return "Kimi"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "omp": return "Oh My Pi"
        case "copilot": return "Copilot"
        default: return kind.capitalized
        }
    }
}

/// Menu rows for per-kind agent shortcuts (only bound kinds get a key equivalent).
private struct AgentKindCommandItems: View {
    @ObservedObject var model: AppModel
    var focusedModel: AppModel?
    @AppStorage(AgentKindDisabled.revisionKey) private var disabledRevision = 0

    private var kinds: [String] {
        _ = disabledRevision
        return AgentKindOrder.visibleSorted(model.session(Device.local.id).agentCatalog.kinds)
    }

    var body: some View {
        if kinds.isEmpty {
            Button(String(localized: "No agents detected")) {}
                .disabled(true)
        } else {
            ForEach(kinds, id: \.self) { kind in
                if let chord = AgentKindShortcuts.chord(for: kind) {
                    Button(AgentKindLabel.display(kind)) {
                        focusedModel?.quickNewAgent(kind: kind)
                    }
                    .keyboardShortcut(chord.keyEquivalent, modifiers: chord.modifiers)
                    .disabled(focusedModel == nil)
                } else {
                    Button(AgentKindLabel.display(kind)) {
                        focusedModel?.quickNewAgent(kind: kind)
                    }
                    .disabled(focusedModel == nil)
                }
            }
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case appearance, terminal, agents, shortcuts, notifications, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .shortcuts: return "Shortcuts"
        case .notifications: return "Notifications"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .terminal: return "terminal.fill"
        case .agents: return "sparkles"
        case .shortcuts: return "keyboard.fill"
        case .notifications: return "bell.fill"
        case .about: return "info.circle.fill"
        }
    }
}

/// Reference image is 2x: 1620 × 1320 pixels, excluding the black surround.
private enum SettingsLayout {
    static let width: CGFloat = 810
    static let height: CGFloat = 660
    static let sidebarWidth: CGFloat = 220
    static let agentRowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 52
    static let navigationHeight: CGFloat = 40
    static let rowHeight: CGFloat = 36
    static let inset: CGFloat = 20
    static let sectionSpacing: CGFloat = 32
    static let cornerRadius: CGFloat = 12
    static let iconRadius: CGFloat = 6
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 11)
    static let headingFont = Font.system(size: 15, weight: .semibold)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pane: SettingsPane = .appearance
    @FocusState private var focusedPane: SettingsPane?

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: SettingsLayout.sidebarWidth)
                .background(Theme.settingsSidebar)
            VStack(spacing: 0) {
                Text(pane.title)
                    .font(SettingsLayout.headingFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsLayout.inset)
                    .frame(height: SettingsLayout.headerHeight)
                    .windowTitlebarInteraction()
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                settingsDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.settingsBackground)
        }
        .font(SettingsLayout.bodyFont)
        .foregroundStyle(Theme.text)
        .tint(Theme.settingsAccent)
        .buttonStyle(SettingsButtonStyle())
        .frame(minWidth: SettingsLayout.width, idealWidth: SettingsLayout.width,
               minHeight: SettingsLayout.height, idealHeight: SettingsLayout.height)
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowChrome())
        .herdrmHideFocusRing()
        .onReceive(NotificationCenter.default.publisher(for: .openAgentSettings)) { _ in
            pane = .agents
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: SettingsLayout.headerHeight)
                .windowTitlebarInteraction()
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goose Agent").font(.system(size: 14, weight: .semibold))
                    Text("Settings")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                ForEach(SettingsPane.allCases.filter { $0 != .about }) { item in
                    navigationButton(item)
                }
            }
            Spacer(minLength: 16)
            navigationButton(.about)
                .padding(.bottom, 8)
        }
    }

    private func navigationButton(_ item: SettingsPane) -> some View {
        Button {
            pane = item
            focusedPane = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.settingsIconForeground)
                    .frame(width: 24, height: 24)
                    .background(item.iconColor.gradient,
                                in: RoundedRectangle(cornerRadius: SettingsLayout.iconRadius))
                    .accessibilityHidden(true)
                Text(item.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsLayout.rowHeight)
            .background(pane == item ? Theme.settingsSelection : (focusedPane == item ? Theme.itemWash : .clear),
                        in: RoundedRectangle(cornerRadius: SettingsLayout.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedPane, equals: item)
        .accessibilityAddTraits(pane == item ? .isSelected : [])
        .frame(height: SettingsLayout.navigationHeight)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        if pane == .agents {
            AgentsSettingsView(model: model)
        } else {
            ScrollView {
                Group {
                    switch pane {
                    case .appearance: AppearanceSettingsView()
                    case .terminal: TerminalSettingsView()
                    case .notifications: NotificationSettingsView()
                    case .about: AboutSettingsView()
                    case .shortcuts: ShortcutsSettingsView(model: model)
                    case .agents: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsLayout.inset)
            }
            .id(pane)
        }
    }
}

private extension SettingsPane {
    var iconColor: Color {
        switch self {
        case .appearance: return Color(nsColor: .systemGray)
        case .terminal: return Theme.textSecondary
        case .agents: return Color(nsColor: .systemGreen)
        case .shortcuts: return Color(nsColor: .systemGray)
        case .notifications: return Color(nsColor: .systemRed)
        case .about: return Color(nsColor: .systemGray)
        }
    }
}

/// Only touches this settings window; console title-bar metrics stay unchanged.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("settings")
            window?.titlebarAppearsTransparent = true
            window?.titlebarSeparatorStyle = .none
            DispatchQueue.main.async { [weak self] in self?.positionButtons() }
        }

        override func layout() {
            super.layout()
            positionButtons()
        }

        private func positionButtons() {
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window?.standardWindowButton(kind), let parent = button.superview else { continue }
                // ponytail: native button sizes; add a toolbar accessory only if macOS changes its title-bar host.
                let y = parent.isFlipped ? (SettingsLayout.headerHeight - button.frame.height) / 2
                    : parent.bounds.height - (SettingsLayout.headerHeight + button.frame.height) / 2
                button.setFrameOrigin(NSPoint(x: 18 + CGFloat(index) * 23, y: y))
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    var expanded: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey, expanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.expanded = expanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded?.wrappedValue ?? true {
                VStack(spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.settingsGroup,
                                in: RoundedRectangle(cornerRadius: SettingsLayout.cornerRadius))
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let expanded {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(expanded.wrappedValue ? "Expanded" : "Collapsed"))
        } else {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    var divided = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if divided { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            HStack(spacing: 12, content: content)
                .frame(minHeight: SettingsLayout.rowHeight - 8)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 10)
    }
}

private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
        }
    }
}

private struct SettingsMenu<Content: View>: View {
    let title: LocalizedStringKey
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 12) {
                Text(verbatim: value).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .background(Theme.settingsControl, in: Circle())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.text)
            .frame(minHeight: 28)
        }
        .menuStyle(.button)
        .pickerStyle(.inline)
        .buttonStyle(.plain)
        .tint(Theme.text)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsLayout.bodyFont)
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .background(configuration.isPressed || isFocused ? Theme.settingsSelection : Theme.settingsControl,
                        in: RoundedRectangle(cornerRadius: SettingsLayout.iconRadius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppShortcuts.revisionKey) private var revision = 0
    @AppStorage(AgentKindDisabled.revisionKey) private var disabledRevision = 0
    @State private var recordingGeneral: AppShortcutID?
    @State private var recordingAgent: String?
    @State private var monitor: Any?
    @State private var conflictText: String?
    @State private var advancedExpanded = false

    private var localKinds: [String] {
        _ = disabledRevision
        return AgentKindOrder.visibleSorted(model.session(Device.local.id).agentCatalog.kinds)
    }

    private var localPaths: [String: String] {
        if case .loaded(_, let paths) = model.session(Device.local.id).agentCatalog {
            return paths
        }
        return [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsSection(title: "General") {
                ForEach(AppShortcutID.primaryCases) { id in
                    generalRow(id, first: AppShortcutID.primaryCases.first)
                }
            }
            SettingsSection(title: "Advanced", expanded: $advancedExpanded) {
                ForEach(AppShortcutID.advancedCases) { id in
                    generalRow(id, first: AppShortcutID.advancedCases.first)
                }
            }
            SettingsSection(title: "Agent") {
                if localKinds.isEmpty {
                    SettingsRow {
                        Text("No locally detected agents")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ForEach(localKinds, id: \.self) { kind in
                        agentRow(kind)
                    }
                }
            }
            if let conflictText {
                Text(conflictText)
                    .font(SettingsLayout.captionFont)
                    .foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Reset All") {
                    AppShortcuts.resetAll()
                    AgentKindShortcuts.resetAll()
                    conflictText = nil
                }
            }
        }
        .onAppear { model.reloadAgentCatalog(deviceID: Device.local.id) }
        .onDisappear { endRecording() }
    }

    private func generalRow(_ id: AppShortcutID, first: AppShortcutID?) -> some View {
        SettingsRow(divided: id != first) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                    .font(SettingsLayout.bodyFont)
                Text(id.detail)
                    .font(SettingsLayout.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            chordButton(
                label: recordingGeneral == id
                    ? String(localized: "Press keys…")
                    : AppShortcuts.display(for: id),
                active: recordingGeneral == id,
                assigned: true
            ) {
                beginRecordingGeneral(id)
            }
            Button(String(localized: "Reset")) {
                if let taken = AppShortcuts.isChordTaken(id.defaultChord, excludingGeneral: id) {
                    conflictText = String(format: String(localized: "Conflicts with %@. Choose another."), taken)
                    return
                }
                AppShortcuts.reset(id)
                conflictText = nil
            }
            .controlSize(.small)
            .disabled(AppShortcuts.chord(for: id) == id.defaultChord)
        }
        .padding(.vertical, 4)
    }

    private func agentRow(_ kind: String) -> some View {
        let path = localPaths[kind]
        return SettingsRow(divided: kind != localKinds.first) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentKindDisplay.name(for: kind))
                    .font(SettingsLayout.bodyFont)
                Text(shortPath(path) ?? kind)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            chordButton(
                label: recordingAgent == kind
                    ? String(localized: "Press keys…")
                    : (AgentKindShortcuts.chord(for: kind) == nil
                        ? String(localized: "Record shortcut")
                        : AgentKindShortcuts.display(for: kind)),
                active: recordingAgent == kind,
                assigned: AgentKindShortcuts.chord(for: kind) != nil
            ) {
                beginRecordingAgent(kind)
            }
            Button(String(localized: "Reset")) {
                if let chord = AgentKindShortcuts.defaultChord(for: kind),
                   let taken = AppShortcuts.isChordTaken(chord, excludingAgentKind: kind) {
                    conflictText = String(format: String(localized: "Conflicts with %@. Choose another."), taken)
                    return
                }
                AgentKindShortcuts.set(nil, for: kind)
                conflictText = nil
            }
            .controlSize(.small)
            .disabled(AgentKindShortcuts.chord(for: kind) == AgentKindShortcuts.defaultChord(for: kind))
        }
        .padding(.vertical, 4)
    }

    private func chordButton(label: String, active: Bool, assigned: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(assigned && !active ? SettingsLayout.bodyFont.monospaced() : SettingsLayout.bodyFont)
                .foregroundStyle(assigned || active ? Theme.text : Theme.textSecondary)
                .frame(width: 156, height: 28)
                .background(active ? Theme.settingsSelection : (assigned ? Theme.settingsBackground : Theme.settingsControl),
                            in: RoundedRectangle(cornerRadius: SettingsLayout.iconRadius))
                .shadow(color: assigned && !active ? Theme.settingsControlShadow : .clear, radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func beginRecordingGeneral(_ id: AppShortcutID) {
        endRecording()
        recordingGeneral = id
        conflictText = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                endRecording()
                return nil
            }
            guard let chord = KeyChord.from(event: event) else { return event }
            if let taken = AppShortcuts.isChordTaken(chord, excludingGeneral: id) {
                conflictText = String(format: String(localized: "Conflicts with %@. Choose another."), taken)
            } else {
                conflictText = nil
                AppShortcuts.set(chord, for: id)
            }
            endRecording()
            return nil
        }
    }

    private func beginRecordingAgent(_ kind: String) {
        endRecording()
        recordingAgent = kind
        conflictText = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                endRecording()
                return nil
            }
            guard let chord = KeyChord.from(event: event) else { return event }
            if let taken = AppShortcuts.isChordTaken(chord, excludingAgentKind: kind) {
                conflictText = String(format: String(localized: "Conflicts with %@. Choose another."), taken)
            } else {
                conflictText = nil
                AgentKindShortcuts.set(chord, for: kind)
            }
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingGeneral = nil
        recordingAgent = nil
    }

    private func shortPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

}

struct AgentsSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [String: String] = AgentBinaryOverrides.load()
    @State private var disabled: Set<String> = AgentKindDisabled.load()
    @State private var orderedRows: [KindRow] = []
    @State private var expandedKind: String?
    @State private var hoveredKind: String?
    @FocusState private var focusedControl: String?
    @State private var draggedKind: String?
    @State private var dropKind: String?
    @State private var dropAfter = false
    @State private var pathError = false
    @State private var checking = false
    private static let dragType = "dev.eachann.goose-herdr.settings-agent-kind"


    private struct KindRow: Identifiable, Equatable {
        let kind: String
        let label: String
        let hint: String
        let detectedPath: String?
        var id: String { kind }
    }

    private static let knownKinds: [(kind: String, label: String, hint: String)] = [
        ("claude", "Claude", "claude"),
        ("codex", "Codex", "codex"),
        ("cursor", "Cursor", "cursor-agent"),
        ("gemini", "Gemini", "gemini"),
        ("grok", "Grok", "grok"),
        ("hermes", "Hermes", "hermes"),
        ("kimi", "Kimi", "kimi"),
        ("opencode", "OpenCode", "opencode"),
        ("pi", "Pi", "pi"),
        ("omp", "Oh My Pi", "omp"),
        ("copilot", "Copilot", "copilot"),
    ]

    private static func displayLabel(for kind: String) -> String {
        knownKinds.first(where: { $0.kind == kind })?.label ?? AgentKindDisplay.name(for: kind)
    }

    private static func hint(for kind: String) -> String {
        knownKinds.first(where: { $0.kind == kind })?.hint ?? kind
    }

    private var localCatalogKinds: [String] {
        model.session(Device.local.id).agentCatalog.kinds
    }

    private var localCatalogPaths: [String: String] {
        if case .loaded(_, let paths) = model.session(Device.local.id).agentCatalog {
            return paths
        }
        return [:]
    }

    private var catalogSignature: String {
        let paths = localCatalogPaths
        return localCatalogKinds.map { "\($0)=\(paths[$0] ?? "")" }.joined(separator: "|")
    }

    private func discoveredRows() -> [KindRow] {
        let paths = localCatalogPaths
        let kinds = Self.knownKinds.map(\.kind) + localCatalogKinds.filter { kind in
            !Self.knownKinds.contains(where: { $0.kind == kind })
        }
        return kinds.map { kind in
            KindRow(
                kind: kind,
                label: Self.displayLabel(for: kind),
                hint: Self.hint(for: kind),
                detectedPath: paths[kind]
            )
        }
    }

    private func syncOrderedRows() {
        // Reloading sets catalog to `.loading` (kinds == []). Don't wipe the list
        // or persist an empty order while that flash is in flight.
        switch model.session(Device.local.id).agentCatalog {
        case .loading, .failed:
            if !orderedRows.isEmpty { return }
        case .loaded:
            break
        }

        let discovered = discoveredRows()
        let byKind = Dictionary(uniqueKeysWithValues: discovered.map { ($0.kind, $0) })
        let ordered = AgentKindOrder.sorted(discovered.map(\.kind))
        orderedRows = ordered.compactMap { byKind[$0] }
        if let expandedKind, !orderedRows.contains(where: { $0.kind == expandedKind }) {
            self.expandedKind = nil
        }
        // Catalog refresh never persists an order or closes a still-valid expanded row.

    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent Applications").font(SettingsLayout.bodyFont.weight(.semibold))
                        Text("Only enabled Agents appear in shortcuts.")
                            .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check command") { checkCommands() }.disabled(checking)
                }
                VStack(spacing: 0) {
                    ForEach(orderedRows) { row in
                        VStack(spacing: 0) {
                            catalogRow(row)
                            if expandedKind == row.kind {
                                rowDetails(row)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 16)
                            }
                            if row.kind != orderedRows.last?.kind {
                                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                }
                .background(Theme.settingsGroup,
                            in: RoundedRectangle(cornerRadius: SettingsLayout.cornerRadius))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refresh policy").font(SettingsLayout.bodyFont.weight(.semibold))
                    Text("Usage refreshes every 5 minutes for enabled Agents. Cursor also requires read-only authorization.")
                }
                .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
            }
            .padding(SettingsLayout.inset)
        }
        .onAppear {
            drafts = AgentBinaryOverrides.load()
            disabled = AgentKindDisabled.load()
            syncOrderedRows()
            checkCommands()
        }
        .onChange(of: catalogSignature) { _, _ in syncOrderedRows() }
        .onChange(of: expandedKind) { _, _ in pathError = false }
    }

    private func checkCommands() {
        guard !checking else { return }
        checking = true
        let task = model.reloadAgentCatalog(deviceID: Device.local.id)
        Task { @MainActor in
            await task?.value
            syncOrderedRows()
            checking = false
        }
    }

    private func catalogRow(_ row: KindRow) -> some View {
        let showTools = hoveredKind == row.kind || focusedControl?.hasPrefix(row.kind + ".") == true
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(SettingsLayout.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: SettingsLayout.agentRowHeight)
                .contentShape(Rectangle())
                .onDrag {
                    draggedKind = row.kind
                    return NSItemProvider(item: row.kind as NSString, typeIdentifier: Self.dragType)
                }
                .opacity(showTools ? 1 : 0)
                .help("Drag to reorder Agents.")
                .accessibilityHidden(true)
            Button {
                expandedKind = expandedKind == row.kind ? nil : row.kind
            } label: {
                HStack(spacing: 8) {
                    BrandIcon(resource: BrandIconLoader.agentIcon(for: row.kind) ?? row.kind, size: 16)
                        .accessibilityHidden(true)
                    Text(verbatim: row.label).font(SettingsLayout.bodyFont).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(checking ? "Checking command…" : row.detectedPath == nil ? "Command not found" : "Command available")
                        .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    Image(systemName: expandedKind == row.kind ? "chevron.down" : "chevron.right")
                        .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: SettingsLayout.agentRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: row.kind + ".details")
            .accessibilityValue(Text(expandedKind == row.kind ? "Agent details expanded" : "Agent details collapsed"))
            Toggle("Enable \(row.label)", isOn: enabledBinding(row.kind))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .focused($focusedControl, equals: row.kind + ".enabled")
        }
        .padding(.horizontal, 8)
        .background(focusedControl?.hasPrefix(row.kind + ".") == true ? Theme.itemWash : .clear,
                    in: RoundedRectangle(cornerRadius: SettingsLayout.iconRadius))
        .onHover { hoveredKind = $0 ? row.kind : nil }
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if dropKind == row.kind { Rectangle().fill(Theme.settingsAccent).frame(height: 1) }
        }
        .onDrop(of: [Self.dragType], delegate: AgentSettingsDropDelegate(
            kind: row.kind, rowHeight: SettingsLayout.agentRowHeight,
            dragged: $draggedKind, target: $dropKind, after: $dropAfter,
            move: reorder))
        .contextMenu {
            Button("Move Agent up") { move(row.kind, by: -1) }
                .disabled(orderedRows.first?.kind == row.kind)
            Button("Move Agent down") { move(row.kind, by: 1) }
                .disabled(orderedRows.last?.kind == row.kind)
        }
    }

    private func rowDetails(_ row: KindRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CLI command").font(SettingsLayout.bodyFont.weight(.semibold))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Command or executable path").font(SettingsLayout.captionFont)
                    TextField("", text: binding(row.kind), prompt: Text(verbatim: row.hint))
                        .font(SettingsLayout.bodyFont.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("Agent binary path"))
                        .onSubmit { commit(row.kind) }
                    Text("Leave empty for automatic detection. Apply or press Return to save.")
                        .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    HStack {
                        Button("Apply path") { commit(row.kind) }.disabled(checking)
                        Button("Check command") { checkCommands() }
                            .disabled(checking)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    if pathError {
                        Text("Enter a command name or absolute path, without arguments or line breaks.")
                            .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    }
                    Text(checking ? "Checking command…" : row.detectedPath == nil ? "Command not found" : "Command available")
                        .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    if !checking, case .failed = model.session(Device.local.id).agentCatalog {
                        Text("Command check failed. Showing the last detection.")
                            .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                    }
                    if let path = shortPath(row.detectedPath) {
                        Text(verbatim: path).font(SettingsLayout.captionFont.monospaced())
                            .foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                Text("Usage account").font(SettingsLayout.bodyFont.weight(.semibold))
                VStack(alignment: .leading, spacing: 12) {
                    if row.kind == "cursor" {
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") == nil ? "Cursor app not detected" : "Cursor app detected")
                            .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
                        CursorUsageAccountView(usage: model.usage, enabled: !disabled.contains(row.kind))
                    } else if UsagePanelModel.availableProviders.contains(row.kind) {
                        Text("Usage follows this Agent’s existing local sign-in. Check the usage menu for current results.")
                    } else {
                        Text("Usage is not supported for this Agent. Its command can still be used independently.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if disabled.contains(row.kind) {
                Text("Agent disabled · no shortcuts or background usage queries.")
                    .font(SettingsLayout.captionFont).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func move(_ kind: String, by delta: Int) {
        guard let index = orderedRows.firstIndex(where: { $0.kind == kind }),
              orderedRows.indices.contains(index + delta) else { return }
        moveRows(from: IndexSet(integer: index), to: delta > 0 ? index + 2 : index - 1)
    }

    private func reorder(_ source: String, _ target: String, _ after: Bool) {
        guard source != target,
              let from = orderedRows.firstIndex(where: { $0.kind == source }),
              let to = orderedRows.firstIndex(where: { $0.kind == target }) else { return }
        moveRows(from: IndexSet(integer: from), to: to + (after ? 1 : 0))
    }

    private func shortPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        orderedRows.move(fromOffsets: source, toOffset: destination)
        AgentKindOrder.save(orderedRows.map(\.kind))
    }

    private func commit(_ kind: String) {
        let path = (drafts[kind] ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.contains(where: { $0.isNewline }),
              path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~/") || !path.contains(where: { $0.isWhitespace }) else {
            pathError = true
            return
        }
        pathError = false
        drafts[kind] = path
        var saved = AgentBinaryOverrides.load()
        saved[kind] = path
        AgentBinaryOverrides.save(saved)
        checkCommands()
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding(
            get: { drafts[kind] ?? "" },
            set: { drafts[kind] = $0 }
        )
    }

    private func enabledBinding(_ kind: String) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(kind) },
            set: { isOn in
                if isOn {
                    disabled.remove(kind)
                } else {
                    disabled.insert(kind)
                }
                AgentKindDisabled.save(disabled)
                model.usage.configure()
            }
        )
    }
}

private struct AgentSettingsDropDelegate: DropDelegate {
    let kind: String
    let rowHeight: CGFloat
    @Binding var dragged: String?
    @Binding var target: String?
    @Binding var after: Bool
    let move: (String, String, Bool) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragged != nil, dragged != kind else { target = nil; return nil }
        target = kind
        after = info.location.y > rowHeight / 2
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if target == kind { target = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = dragged else { return false }
        move(source, kind, info.location.y > rowHeight / 2)
        dragged = nil
        target = nil
        return true
    }
}

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true

    private let families = TerminalDefaults.monospacedFamilies()

    private var weightTitle: String {
        if fontWeight == Double(NSFont.Weight.light.rawValue) {
            return String(localized: "font.weight.light", defaultValue: "Light")
        }
        if fontWeight == Double(NSFont.Weight.medium.rawValue) {
            return String(localized: "font.weight.medium", defaultValue: "Medium")
        }
        return String(localized: "font.weight.regular", defaultValue: "Regular")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsSection(title: "Font") {
                SettingsRow {
                    Text("Font")
                    Spacer()
                    SettingsMenu(title: "Font", value: fontName.isEmpty ? String(localized: "System Mono (SF Mono)") : fontName) {
                        Picker("Font", selection: $fontName) {
                            Text("System Mono (SF Mono)").tag("")
                            Divider()
                            ForEach(families, id: \.self) { family in
                                Text(verbatim: family).tag(family)
                            }
                        }
                    }
                }
                SettingsRow(divided: true) {
                    Text("Size")
                    Spacer(minLength: 16)
                    Slider(value: $fontSize, in: 9...22, step: 0.5)
                        .accessibilityLabel(Text("Font size"))
                        .frame(maxWidth: 180)
                    Text(String(format: "%.1f pt", fontSize))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper("Font size", value: $fontSize, in: 9...22, step: 0.5)
                        .labelsHidden()
                }
                SettingsRow(divided: true) {
                    Text("Weight")
                    Spacer(minLength: 16)
                    SettingsMenu(title: "Weight", value: weightTitle) {
                        Picker("Weight", selection: $fontWeight) {
                            Text(String(localized: "font.weight.light", defaultValue: "Light"))
                                .tag(Double(NSFont.Weight.light.rawValue))
                            Text(String(localized: "font.weight.regular", defaultValue: "Regular"))
                                .tag(TerminalDefaults.defaultFontWeight)
                            Text(String(localized: "font.weight.medium", defaultValue: "Medium"))
                                .tag(Double(NSFont.Weight.medium.rawValue))
                        }
                    }
                    .disabled(!fontName.isEmpty)
                    .help("Only the system monospaced font has selectable weights.")
                }
                SettingsRow(divided: true) {
                    Text("Line spacing")
                    Spacer(minLength: 16)
                    Slider(value: $lineSpacing, in: 1.0...1.4, step: 0.05)
                        .accessibilityLabel(Text("Line spacing"))
                        .frame(maxWidth: 180)
                    Text(String(format: "%.0f%%", lineSpacing * 100))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            SettingsSection(title: "Behavior") {
                SettingsRow {
                    Toggle(isOn: $thinStrokes) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thin strokes")
                            Text("Turns off macOS font smoothing, which thickens glyph stems and makes agent output — Claude Code's bold text especially — look heavy and smudged.")
                                .font(SettingsLayout.captionFont)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                SettingsRow(divided: true) {
                    Toggle(isOn: $mouseReporting) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mouse reporting")
                            Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                                .font(SettingsLayout.captionFont)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            SettingsSection(title: "Preview") {
                SettingsRow {
                    Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                        .font(Font(TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Reset to Defaults") {
                fontName = ""
                fontSize = TerminalDefaults.defaultFontSize
                fontWeight = TerminalDefaults.defaultFontWeight
                lineSpacing = TerminalDefaults.defaultLineSpacing
                thinStrokes = true
                mouseReporting = true
            }
        }
        .toggleStyle(SettingsSwitchStyle())
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(SidebarSectionID.spacesHiddenKey) private var spacesHidden = false
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(SidebarActionID.newSpace.hiddenKey) private var newSpaceHidden = false
    @AppStorage(SidebarActionID.files.hiddenKey) private var filesHidden = false
    @AppStorage(SidebarActionID.search.hiddenKey) private var searchHidden = false

    private var themeTitle: String {
        switch themePreference {
        case "light": return String(localized: "theme.light", defaultValue: "Light")
        case "dark": return String(localized: "theme.dark", defaultValue: "Dark")
        default: return String(localized: "theme.system", defaultValue: "System")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsSection(title: "App") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Theme")
                        Text("The terminal follows the app theme.")
                            .font(SettingsLayout.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 16)
                    SettingsMenu(title: "Theme", value: themeTitle) {
                        Picker("Theme", selection: $themePreference) {
                            Text(String(localized: "theme.system", defaultValue: "System")).tag("system")
                            Text(String(localized: "theme.light", defaultValue: "Light")).tag("light")
                            Text(String(localized: "theme.dark", defaultValue: "Dark")).tag("dark")
                        }
                    }
                }
                SettingsRow(divided: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Language")
                            Spacer()
                            SettingsMenu(title: "Language", value: (AppLanguage(rawValue: language) ?? .system).displayName) {
                                Picker("Language", selection: $language) {
                                    ForEach(AppLanguage.allCases) { option in
                                        Text(verbatim: option.displayName).tag(option.rawValue)
                                    }
                                }
                            }
                            .onChange(of: language) { _, newValue in
                                AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
                            }
                        }
                        Text("Changing language takes effect after you quit and reopen Goose Agent.")
                            .font(SettingsLayout.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            SettingsSection(title: "Sidebar Sections") {
                SettingsRow {
                    Toggle("Spaces", isOn: Binding(get: { !spacesHidden }, set: { spacesHidden = !$0 }))
                }
            }
            SettingsSection(title: "Quick Actions") {
                SettingsRow {
                    Toggle("New Space", isOn: Binding(get: { !newSpaceHidden }, set: { newSpaceHidden = !$0 }))
                }
                SettingsRow(divided: true) {
                    Toggle("Files", isOn: Binding(get: { !filesHidden }, set: { filesHidden = !$0 }))
                }
                SettingsRow(divided: true) {
                    Toggle("Search", isOn: Binding(get: { !searchHidden }, set: { searchHidden = !$0 }))
                }
            }
        }
        .toggleStyle(SettingsSwitchStyle())
    }
}

struct NotificationSettingsView: View {
    @AppStorage("notifications.enabled") private var enabled = true
    @AppStorage("notifications.sound") private var sound = true
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsSection(title: "Notifications") {
                SettingsRow {
                    Toggle("Notify when an agent finishes or needs input", isOn: $enabled)
                }
                SettingsRow(divided: true) {
                    Toggle("Play a sound", isOn: $sound)
                }
                SettingsRow(divided: true) {
                    Text("Finished agents only notify while you're not watching them — herdr reports panes you have open as idle, not done.")
                        .font(SettingsLayout.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
            }
            SettingsSection(title: "Permission") {
                SettingsRow {
                    switch authorization {
                    case .denied:
                        Text("Notifications are disabled in System Settings.")
                        Spacer(minLength: 8)
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    case .notDetermined:
                        Text("Notification permission hasn't been granted yet.")
                        Spacer(minLength: 8)
                        Button("Request Permission") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                                refreshAuthorization()
                            }
                        }
                    case .authorized, .provisional:
                        Text("Notification permission granted.")
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .toggleStyle(SettingsSwitchStyle())
        .onAppear { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { authorization = settings.authorizationStatus }
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        SettingsSection(title: "Goose Agent") {
            SettingsRow {
                Text("Goose Agent — a native macOS console for herdr.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(divided: true) {
                Text("Devices are managed from the switcher in the sidebar footer.")
                    .font(SettingsLayout.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
