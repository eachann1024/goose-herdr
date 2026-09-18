import AppKit
import HerdrKit
import SwiftUI

struct UsageSnapshot: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Double
        let resetsAt: Double?
    }
    struct Metadata: Decodable { let failureKind: String? }
    struct Credits: Decodable {
        let availableCount: Int
        let totalEarnedCount: Int?
        let nextExpiresAt: Double?
    }
    struct History: Decodable {
        let sessions: Int
        let inputTokens: Int
        let outputTokens: Int
        let estimatedCostUsd: Double?
    }
    struct CursorSummary: Decodable {
        let autoPercent: Double?
        let apiPercent: Double?
        let totalPercent: Double?
        let planSpentUSD: Double?
        let includedSpentUSD: Double?
        let planLimitUSD: Double?
        let cycleStart: Double?
        let cycleEnd: Double?
    }
    let cursor: CursorSummary?
    let history: History?
    let historyError: Bool?
    let provider: String
    let session: Window?
    let weekly: Window?
    let monthly: Window?
    let fableWeekly: Window?
    let rateLimitResetCredits: Credits?
    let planType: String?
    let status: String
    let usageMetadata: Metadata?
}

@MainActor
final class UsagePanelModel: ObservableObject {
    static let availableProviders = ["claude", "codex", "kimi", "grok", "opencode", "cursor"]
    static let cursorAuthorizationKey = "usage.cursor.readOnlyAuthorized"
    @Published private(set) var cursorFailure: String?
    @Published private(set) var cursorUpdatedAt: Date?
    var cursorAuthorized: Bool { UserDefaults.standard.bool(forKey: Self.cursorAuthorizationKey) }

    func connectCursor() {
        guard !AgentKindDisabled.load().contains("cursor") else { return }
        UserDefaults.standard.set(true, forKey: Self.cursorAuthorizationKey)
        configure()
        refreshCursor()
    }

    func disconnectCursor() {
        UserDefaults.standard.set(false, forKey: Self.cursorAuthorizationKey)
        configure()
    }

    func refreshCursor() {
        guard cursorAuthorized, gate.enabled.contains("cursor"), processes["cursor"] == nil else { return }
        launch("cursor", generation: gate.generation)
    }

    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var fetching: Set<String> = []
    private var processes: [String: Process] = [:]
    private var gate = UsageRequestGate()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var catalog: () -> [String] = { [] }
    static let pollingInterval: TimeInterval = 300

    func start(catalog: @escaping () -> [String]) {
        guard timer == nil else { return }
        self.catalog = catalog
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configure() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        configure()
    }

    func configure() {
        if AgentKindDisabled.load().contains("cursor"), cursorAuthorized {
            UserDefaults.standard.set(false, forKey: Self.cursorAuthorizationKey)
        }
        var enabled = Set(AgentKindDisabled.visible(catalog())).intersection(Self.availableProviders)
        if cursorAuthorized && !AgentKindDisabled.load().contains("cursor") {
            // Account usage is independent of whether the CLI command is installed.
            enabled.insert("cursor")
        } else {
            enabled.remove("cursor")
        }
        guard enabled != gate.enabled else { return }
        cancel()
        gate.replace(enabled: enabled)
        refresh()
    }

    func refresh() {
        for provider in Self.availableProviders where gate.enabled.contains(provider) && processes[provider] == nil {
            launch(provider, generation: gate.generation)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancel()
    }

    private func cancel() {
        gate.replace(enabled: [])
        for process in processes.values where process.isRunning { process.terminate() }
        // Keep terminating processes registered until exit to prevent overlapping probes.
        snapshots.removeAll()
        cursorFailure = nil
        cursorUpdatedAt = nil
        failures.removeAll()
        fetching.removeAll()
    }

    private func launch(_ provider: String, generation revision: Int) {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("UsageHelper") else { return }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let process = Process()
        process.executableURL = root.appendingPathComponent("runtime/\(arch)/node")
        process.arguments = ["--use-env-proxy", root.appendingPathComponent("main.mjs").path, provider]
        // No NODE_OPTIONS/NODE_PATH injection; never include credentials in arguments or logs.
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        for key in ["KIMI_CODE_HOME", "GROK_HOME", "CODEX_HOME", "OPENCODE_DB", "XDG_DATA_HOME", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        if provider == "cursor" {
            guard cursorAuthorized else { return }
            environment["GOOSE_CURSOR_USAGE_AUTHORIZED"] = "1"
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        fetching.insert(provider)
        processes[provider] = process
        do { try process.run() }
        catch {
            processes.removeValue(forKey: provider)
            fetching.remove(provider)
            failures.insert(provider)
            if provider == "cursor" { cursorFailure = "helper-unavailable" }
            return
        }
        let reader = output.fileHandleForReading
        Task.detached { [weak self] in
            // Drain while the child is running: waiting for exit first can fill the pipe.
            let data = reader.readDataToEndOfFile()
            process.waitUntilExit()
            let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processes.removeValue(forKey: provider)
                guard self.gate.accepts(provider: provider, generation: revision),
                      !AgentKindDisabled.load().contains(provider),
                      provider != "cursor" || self.cursorAuthorized else {
                    if self.timer != nil { self.refresh() }
                    return
                }
                self.fetching.remove(provider)
                if process.terminationStatus == 0, let snapshot, snapshot.provider == provider {
                    self.failures.remove(provider)
                    if provider == "cursor" {
                        self.cursorFailure = snapshot.status == "ok" ? nil : (snapshot.usageMetadata?.failureKind ?? "request-failed")
                        if snapshot.status == "ok" {
                            self.snapshots[provider] = snapshot
                            self.cursorUpdatedAt = Date()
                        }
                    } else {
                        self.snapshots[provider] = snapshot
                    }
                } else {
                    if provider == "cursor" { self.cursorFailure = "helper-unavailable" }
                    self.failures.insert(provider)
                }
            }
        }
    }
}

/// Shares the application-owned cache and request gate; this view never reads credentials.
struct CursorUsageAccountView: View {
    @ObservedObject var usage: UsagePanelModel
    let enabled: Bool
    var compact = false
    @State private var confirming = false

    private var status: LocalizedStringKey {
        if !usage.cursorAuthorized { return "Usage not connected" }
        if usage.fetching.contains("cursor") { return "Verifying Cursor usage…" }
        switch usage.cursorFailure {
        case "no-session": return "No Cursor sign-in found. Sign in to the Cursor app, then retry."
        case "session-expired": return "Cursor sign-in expired. Open Cursor to sign in again, then retry."
        case "authentication-failed": return "Cursor rejected this sign-in. Check your account access and retry."
        case "storage-unavailable": return "Cursor sign-in storage is temporarily unreadable. Open Cursor and retry."
        case "network-failed": return "Could not reach Cursor. Check your network and retry."
        case "unsupported-response": return "Cursor returned no supported usage fields. Values remain unknown."
        case "helper-unavailable": return "Usage helper unavailable. Rebuild or reinstall the app."
        case .some: return "Cursor usage request failed. Please retry."
        case nil: return usage.snapshots["cursor"] == nil ? "Usage not connected" : "Usage connected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).fixedSize(horizontal: false, vertical: true)
            if usage.cursorAuthorized, let summary = usage.snapshots["cursor"]?.cursor {
                if usage.cursorFailure != nil { Text("Cached usage · out of date").foregroundStyle(Theme.textSecondary) }
                summaryView(summary)
                if let date = usage.cursorUpdatedAt {
                    HStack(spacing: 4) {
                        Text("Last verified")
                        Text(date, style: .relative)
                    }.font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if !compact && !usage.cursorAuthorized {
                Text("Cursor App and CLI availability do not connect account usage.")
                    .foregroundStyle(Theme.textSecondary)
                if confirming {
                    Text("Allow read-only access to this Mac’s Cursor sign-in for usage queries? Only the existing Cursor access token is sent to Cursor over HTTPS. No browser cookies, projects or chats are read; no credentials are saved or refreshed.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Allow and verify") { confirming = false; usage.connectCursor() }
                            .disabled(!enabled)
                        Button("Cancel") { confirming = false }
                    }
                } else {
                    Button("Connect usage…") { confirming = true }.disabled(!enabled)
                }
            } else if usage.cursorAuthorized {
                HStack {
                    Button(usage.fetching.contains("cursor") ? "Cancel connection" : "Disconnect usage") {
                        usage.disconnectCursor()
                    }
                    if !usage.fetching.contains("cursor") {
                        Button("Retry usage") { usage.refreshCursor() }.disabled(!enabled)
                    }
                }
            } else {
                Text("Connect Cursor usage in Agent settings.").foregroundStyle(Theme.textSecondary)
            }
            if !compact && usage.cursorFailure != nil {
                Link("Open Cursor sign-in", destination: URL(string: "https://cursor.com/login")!)
                Text("Sign in through Cursor itself. Goose Agent never renews or writes back its sign-in.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .onChange(of: enabled) { _, active in if !active { confirming = false } }
    }

    private func summaryView(_ summary: UsageSnapshot.CursorSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            percentage("Auto usage", summary.autoPercent)
            percentage("API usage", summary.apiPercent)
            percentage("Total usage", summary.totalPercent)
            amount("Plan spend", summary.planSpentUSD)
            amount("Included spend", summary.includedSpentUSD)
            amount("Plan limit", summary.planLimitUSD)
            HStack(alignment: .firstTextBaseline) {
                Text("Billing cycle")
                Spacer(minLength: 4)
                if let start = summary.cycleStart, let end = summary.cycleEnd {
                    Text(verbatim: "\(Date(timeIntervalSince1970: start / 1000).formatted(date: .abbreviated, time: .omitted)) – \(Date(timeIntervalSince1970: end / 1000).formatted(date: .abbreviated, time: .omitted))")
                } else { Text("Unknown") }
            }
        }.font(.caption).monospacedDigit()
    }

    private func percentage(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            if let value { Text(value / 100, format: .percent.precision(.fractionLength(1))) }
            else { Text("Unknown") }
        }
    }

    private func amount(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            if let value { Text(value, format: .currency(code: "USD")) }
            else { Text("Unknown") }
        }
    }
}

struct UsagePanelButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsagePanelModel
    @AppStorage(AgentKindDisabled.revisionKey) private var agentRevision = 0
    @Environment(\.openWindow) private var openWindow
    @State private var presented = false
    @State private var pinned = false
    @State private var triggerHovered = false
    @State private var panelHovered = false
    @State private var closeTask: Task<Void, Never>?

    private var local: Bool { model.filteredDevice?.isLocal == true }
    private var kinds: [String] { model.session(Device.local.id).agentCatalog.kinds }
    private var enabled: [String] { AgentKindDisabled.visible(kinds) }
    private var providers: [String] {
        UsagePanelModel.availableProviders.filter {
            enabled.contains($0) || ($0 == "cursor" && usage.cursorAuthorized && !AgentKindDisabled.load().contains("cursor"))
        }
    }

    var body: some View {
        Button {
            if pinned { close() } else { pinned = true; presented = true }
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Agent usage"))
        .help("Agent usage")
        .onHover { triggerHovered = $0; hoverChanged() }
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            panel
                .onHover { panelHovered = $0; hoverChanged() }
                .onExitCommand { close() }
        }
        .onChange(of: presented) { _, visible in
            if !visible { pinned = false }
        }
        .onDisappear { closeTask?.cancel() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agent usage").font(Theme.sidebarRowTitle.weight(.semibold))
                Text("This Mac").font(Theme.sidebarRowMeta)
                Spacer()
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                    .buttonStyle(.plain)
                    .help("Refresh usage")
                    .accessibilityLabel(Text("Refresh usage"))
                    .disabled(!local)
            }
            if !local {
                Text("Select Local to view usage on this Mac.")
            } else if providers.isEmpty {
                Text("Enable an Agent in the existing Agent settings.")
                Button("Agent settings") { openAgentSettings() }
            } else {
                ForEach(providers, id: \.self) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: ["claude": "Claude", "codex": "Codex", "kimi": "Kimi", "grok": "Grok", "opencode": "OpenCode", "cursor": "Cursor"][provider] ?? provider).font(Theme.sidebarRowTitle.weight(.semibold))
                            Spacer()
                            if usage.fetching.contains(provider) { ProgressView().controlSize(.small) }
                            if let plan = usage.snapshots[provider]?.planType { Text(verbatim: plan).font(.caption) }
                        }
                        if provider == "cursor" {
                            CursorUsageAccountView(usage: usage, enabled: !AgentKindDisabled.load().contains("cursor"), compact: true)
                        } else if let snapshot = usage.snapshots[provider] {
                            if snapshot.status == "ok" {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let window = snapshot.session { metric("Session usage", window: window) }
                                    if let window = snapshot.weekly { metric("Weekly usage", window: window) }
                                    if let window = snapshot.monthly { metric("Monthly usage", window: window) }
                                    if let window = snapshot.fableWeekly { metric("Fable weekly usage", window: window) }
                                }
                                if let credits = snapshot.rateLimitResetCredits {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text("Reset credits: \(credits.availableCount)")
                                            if let earned = credits.totalEarnedCount { Text("Earned: \(earned)") }
                                        }
                                        if let expires = credits.nextExpiresAt {
                                            HStack(spacing: 4) {
                                                Text("Credit expires")
                                                Text(Date(timeIntervalSince1970: expires / 1000), style: .relative)
                                            }
                                        }
                                    }.font(Theme.sidebarRowMeta)
                                }
                            } else if snapshot.usageMetadata?.failureKind == "delegated-refresh-required" {
                                Text("Sign-in expired. Open the Agent CLI to refresh it.")
                            } else if provider == "opencode" {
                                Text("OpenCode Go needs a web session cookie; this host has no existing credential setting.")
                            } else if snapshot.status == "unavailable" {
                                Text("Usage unavailable. Check the Agent sign-in and plan.")
                            } else {
                                Text("Unable to read usage. Retry after checking the Agent.")
                            }
                            if let history = snapshot.history {
                                HStack(spacing: 8) {
                                    compactValue("Sessions", value: history.sessions)
                                    Spacer(minLength: 0)
                                    if let cost = history.estimatedCostUsd {
                                        Text(cost, format: .currency(code: "USD"))
                                            .help("Estimated cost")
                                            .accessibilityLabel(Text("Estimated cost"))
                                            .accessibilityValue(Text(cost, format: .currency(code: "USD")))
                                    }
                                }.font(Theme.sidebarRowMeta)
                                HStack(spacing: 12) {
                                    compactValue("Input", value: history.inputTokens)
                                    compactValue("Output", value: history.outputTokens)
                                }.font(Theme.sidebarRowMeta)
                            } else if snapshot.historyError == true {
                                Text("Local history could not be read.").font(Theme.sidebarRowMeta)
                            }
                        } else if usage.failures.contains(provider) {
                            Text("Usage helper unavailable. Rebuild or reinstall the app.")
                        }
                    }
                    .padding(8)
                    .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .font(Theme.sidebarRowTitle)
        .padding(8)
        .frame(width: SheetLayout.usage)
        .foregroundStyle(Theme.text)
        .background(Theme.tooltipBackground)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ title: LocalizedStringKey, window: UsageSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                Text(window.usedPercent / 100, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if let reset = window.resetsAt {
                    Text("Resets")
                    Text(Date(timeIntervalSince1970: reset / 1000), style: .relative)
                }
            }.font(Theme.sidebarRowMeta)
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .controlSize(.mini)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactValue(_ title: LocalizedStringKey, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value, format: .number.notation(.compactName).precision(.significantDigits(1...3)))
                .monospacedDigit()
        }
        .help(Text(value, format: .number))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value, format: .number))
    }

    private func refresh() { usage.refresh() }
    private func close() { closeTask?.cancel(); presented = false; pinned = false }
    private func hoverChanged() {
        closeTask?.cancel()
        if triggerHovered || panelHovered { presented = true; return }
        guard !pinned else { return }
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !triggerHovered, !panelHovered, !pinned else { return }
            presented = false
        }
    }
    private func openAgentSettings() {
        close()
        openWindow(id: "settings")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openAgentSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let openAgentSettings = Notification.Name("goose.openAgentSettings")
}
