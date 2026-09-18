import AppKit
import SwiftUI

enum TooltipPlacement {
    static let gap: CGFloat = 6
    static let inset: CGFloat = 6

    /// Center above the control, flipping below only when the top edge needs it.
    static func origin(anchor: CGRect, bubble: CGSize, container: CGSize) -> CGPoint {
        let above = anchor.minY - gap - bubble.height
        let y = above >= inset ? above : anchor.maxY + gap
        return CGPoint(
            x: max(inset, min(anchor.midX - bubble.width / 2, container.width - bubble.width - inset)),
            y: max(inset, min(y, container.height - bubble.height - inset))
        )
    }
}

/// The hovered control publishes its bubble through this preference; `TooltipLayer`
/// draws it once at the window root, so a sidebar `ScrollView` or a pane edge
/// can never clip it.
struct TooltipRequest {
    var title: Text
    var shortcut: String?
    var anchor: Anchor<CGRect>
}

struct TooltipRequestKey: PreferenceKey {
    static let defaultValue: TooltipRequest? = nil
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        value = nextValue() ?? value
    }
}

/// A click hides a visible tooltip; the pointer has to leave and re-enter before
/// it can come back, which is how the system tooltip behaves.
enum TooltipDismissal {
    static let didDismiss = Notification.Name("herdr.tooltip.didDismiss")
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            NotificationCenter.default.post(name: didDismiss, object: nil)
            return event
        }
    }
}

extension View {
    /// `title` is localized; `shortcut` resolves through `AppShortcuts`, so
    /// remapping a key retargets every tooltip that shows it.
    func codexTooltip(_ title: LocalizedStringKey, shortcut: AppShortcutID? = nil) -> some View {
        modifier(TooltipModifier(title: Text(title), shortcut: shortcut))
    }

    /// The same bubble for labels that already are display text (a cwd, an error).
    func codexTooltip(verbatim title: String) -> some View {
        modifier(TooltipModifier(title: Text(verbatim: title), shortcut: nil))
    }
}

private struct TooltipModifier: ViewModifier {
    let title: Text
    let shortcut: AppShortcutID?
    @AppStorage(AppShortcuts.revisionKey) private var revision = 0
    @State private var hovered = false
    @State private var shown = false
    @State private var dismissed = false

    private var shortcutText: String? {
        _ = revision  // remapping a key must re-emit this bubble's pill
        return shortcut.map { AppShortcuts.display(for: $0) }
    }

    func body(content: Content) -> some View {
        content
            .onHover {
                hovered = $0
                if !$0 { dismissed = false }
            }
            .task(id: hovered) {
                // Settle first: sweeping across rows must not flash bubbles.
                guard hovered else {
                    shown = false
                    return
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, !dismissed else { return }
                shown = true
            }
            .onDisappear { shown = false }
            .onReceive(NotificationCenter.default.publisher(for: TooltipDismissal.didDismiss)) { _ in
                dismissed = hovered
                shown = false
            }
            .anchorPreference(key: TooltipRequestKey.self, value: .bounds) { anchor in
                shown ? TooltipRequest(title: title, shortcut: shortcutText, anchor: anchor) : nil
            }
            // macOS has no `accessibilityHelp`; the hint keeps what `.help`
            // used to expose to VoiceOver.
            .accessibilityHint(title)
    }
}

/// Draws the published bubble above the window content and takes no clicks.
struct TooltipLayer: View {
    let request: TooltipRequest
    @State private var bubbleSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let origin = TooltipPlacement.origin(
                anchor: geometry[request.anchor], bubble: bubbleSize, container: geometry.size
            )
            TooltipBubble(
                title: request.title, shortcut: request.shortcut,
                maxWidth: max(0, geometry.size.width - 2 * TooltipPlacement.inset)
            )
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { bubble in
                        Color.clear.onChange(of: bubble.size, initial: true) { _, size in
                            bubbleSize = size
                        }
                    }
                }
                .offset(x: origin.x, y: origin.y)
                .opacity(bubbleSize == .zero ? 0 : 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TooltipBubble: View {
    let title: Text
    let shortcut: String?
    var maxWidth: CGFloat = .infinity

    var body: some View {
        HStack(spacing: 8) {
            title
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tooltipText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.tooltipText)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Theme.tooltipKeycap, in: Capsule())
                    // The bubble repeats the accessibility help, not new content.
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, shortcut == nil ? 12 : 6)
        .frame(height: 30)
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(Theme.tooltipBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.tooltipBorder, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: Theme.tooltipShadow, radius: 9, y: 7)
    }
}
