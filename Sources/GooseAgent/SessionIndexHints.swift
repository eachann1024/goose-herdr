import AppKit
import Combine
import SwiftUI

/// Browser-style ⌘1…9: slots 1–8 stay fixed; 9 is always the last session.
enum SessionSwitchIndex {
    static let holdDuration: Duration = .milliseconds(150)
    static let holdInterval: TimeInterval = 0.15

    static func number(forIndex index: Int, count: Int) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        if index < 8 { return index + 1 }
        if index == count - 1 { return 9 }
        return nil
    }

    static func index(forNumber number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return count - 1 }
        let index = number - 1
        return index < count ? index : nil
    }

    // MARK: - Session index hints

    static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        exclusiveModifier(flags) == .command
    }

    static func isControlOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        exclusiveModifier(flags) == .control
    }

    private static func exclusiveModifier(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .shift, .option, .control])
    }
}

/// Keyboard-row ⌃1…9,0: first 10 sidebar spaces. 0 is the 10th item, not last.
enum SpaceSwitchIndex {
    static func number(forIndex index: Int, count: Int) -> Int? {
        guard count > 0, index >= 0, index < count, index < 10 else { return nil }
        return index == 9 ? 0 : index + 1
    }

    static func index(forNumber number: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let index: Int
        switch number {
        case 0: index = 9
        case 1...9: index = number - 1
        default: return nil
        }
        return index < count ? index : nil
    }
}

@MainActor
final class SessionIndexHintController: ObservableObject {
    @Published private(set) var isShowing = false
    @Published private(set) var isShowingSpaces = false

    private enum HoldKind { case command, control }

    private var monitor: Any?
    private var activateObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var holdStartedAt: Date?
    private var holdKind: HoldKind?

    init() {
        start()
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                self?.sync(flags: flags)
            }
            return event
        }
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sync(flags: NSEvent.modifierFlags)
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reset()
            }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sync(flags: NSEvent.modifierFlags)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        sync(flags: NSEvent.modifierFlags)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let activateObserver {
            NotificationCenter.default.removeObserver(activateObserver)
            self.activateObserver = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        reset()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let activateObserver {
            NotificationCenter.default.removeObserver(activateObserver)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        pollTimer?.invalidate()
    }

    private func sync(flags: NSEvent.ModifierFlags) {
        guard NSApp.isActive else {
            reset()
            return
        }
        let kind: HoldKind?
        if SessionSwitchIndex.isCommandOnly(flags) {
            kind = .command
        } else if SessionSwitchIndex.isControlOnly(flags) {
            kind = .control
        } else {
            kind = nil
        }
        guard let kind else {
            reset()
            return
        }
        if holdKind != kind {
            holdKind = kind
            holdStartedAt = Date()
            if isShowing { isShowing = false }
            if isShowingSpaces { isShowingSpaces = false }
        }
        guard Date().timeIntervalSince(holdStartedAt!) >= SessionSwitchIndex.holdInterval else { return }
        switch kind {
        case .command:
            if !isShowing { isShowing = true }
        case .control:
            if !isShowingSpaces { isShowingSpaces = true }
        }
    }

    private func reset() {
        holdKind = nil
        holdStartedAt = nil
        if isShowing { isShowing = false }
        if isShowingSpaces { isShowingSpaces = false }
    }
}

struct SessionIndexHint: View {
    let number: Int

    var body: some View {
        Text(String(number))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 20, height: 12)
            .minimumScaleFactor(0.8)
            .accessibilityHidden(true)
    }
}

struct SidebarSessionIndexSlot<Status: View>: View {
    var visible: Bool
    let number: Int?
    /// 会话行保留状态点；空间行用位次替换数量。
    var keepsStatus = false
    @ViewBuilder var status: () -> Status

    var body: some View {
        if keepsStatus {
            HStack(spacing: 4) {
                status()
                if let number {
                    SessionIndexHint(number: number)
                        .opacity(visible ? 1 : 0)
                }
            }
        } else {
            status()
                .opacity(visible && number != nil ? 0 : 1)
                .frame(minWidth: 20)
                .overlay {
                    if visible, let number {
                        SessionIndexHint(number: number)
                    }
                }
        }
    }
}
