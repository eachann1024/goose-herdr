import HerdrKit
import SwiftUI

/// Row bounds align the terminal-edge ink with the new session without covering the sidebar.
struct PiLaunchOriginKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

enum PiLaunchMotion {
    static let cover = 0.35
    static let fade = 0.15
    static let reducedFade = 0.15

    static func radius(size: CGSize, origin: CGPoint) -> CGFloat {
        hypot(max(origin.x, size.width - origin.x), max(origin.y, size.height - origin.y))
    }
}

struct PiLoadingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.piLaunch?.failed == true {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                Text("Pi is taking longer to load")
                Button("Check again") {
                    guard let launch = model.piLaunch, let pane = launch.pane,
                          let device = model.device(launch.deviceID) else { return }
                    model.piLaunch?.failed = false
                    Task {
                        let ready = await model.service(for: device).waitForStartedAgent(kind: "pi", paneID: pane.paneID)
                        guard model.piLaunch?.id == launch.id else { return }
                        model.piLaunch?.ready = ready
                        model.piLaunch?.failed = !ready
                    }
                }
                Button("Show Terminal") {
                    if let launch = model.piLaunch { model.finishPiLaunch(launch.id) }
                }
            } else {
                Color.clear
            }
        }
        .font(.body)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }
}

struct PiLaunchInkView: View {
    @ObservedObject var model: AppModel
    let launchID: UUID
    let origin: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var visible = false
    @State private var opacity = 1.0
    @State private var ink = Theme.randomPiLaunchInk()

    var body: some View {
        GeometryReader { geometry in
            if visible {
                if let origin, !reduceMotion {
                    let diameter = PiLaunchMotion.radius(size: geometry.size, origin: origin) * 2
                    Circle()
                        .fill(ink)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(expanded ? 1 : 0.005)
                        .position(origin)
                        .opacity(opacity)
                } else {
                    ink.opacity(opacity)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: model.piLaunch?.failed) {
            visible = false
            expanded = false
            opacity = 1
            guard model.piLaunch?.failed == false else { return }
            do {
                // Keep the destination blank until ready; never park a completed ink
                // animation over a terminal that is still starting.
                while model.piLaunch?.ready != true {
                    try await Task.sleep(for: .milliseconds(50))
                }
                // ponytail: Ghostty exposes no presented-frame event. Use its attached
                // surface plus delivered output until that event is available.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !terminalHasContent {
                    guard ContinuousClock.now < deadline else {
                        model.piLaunch?.ready = false
                        model.piLaunch?.failed = true
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                guard model.piLaunch?.id == launchID else { return }
                visible = true
                // Commit the small circle before animating its transform.
                try await Task.sleep(for: .milliseconds(16))
                let minimal = reduceMotion || origin == nil
                if !minimal {
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: PiLaunchMotion.cover)) {
                        expanded = true
                    }
                    try await Task.sleep(for: .seconds(PiLaunchMotion.cover))
                }
                model.piLaunch?.revealed = true
                let fade = minimal ? PiLaunchMotion.reducedFade : PiLaunchMotion.fade
                withAnimation(.easeIn(duration: fade)) { opacity = 0 }
                try await Task.sleep(for: .seconds(fade))
                model.finishPiLaunch(launchID)
            } catch {
                // SwiftUI cancels on selection changes: no delayed reveal or focus steal.
            }
        }
    }

    private var terminalHasContent: Bool {
        guard let view = model.splitAgentView else { return false }
        return view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
            && view.attachedSurface != nil && view.processHost?.hasReceivedOutput == true
    }
}
