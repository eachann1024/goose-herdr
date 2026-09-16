import AppKit
import ObjectiveC
import SwiftUI

// MARK: - Strategy
//
// Blue system focus rings leak through custom chrome because SwiftUI's
// `.focusEffectDisabled()` is incomplete for AppKit-backed controls
// (NSButton, segmented pickers, toggles, sheet Cancel/Open, etc.).
//
// Chosen approach (layered):
// 1. SwiftUI: `View.herdrmHideFocusRing()` → `.focusEffectDisabled()`, applied on
//    RootView, each sheet root, Settings, and key card buttons so descendant
//    SwiftUI focus effects stay off where that API works.
// 2. AppKit: on launch, swizzle `NSView.viewDidMoveToWindow` so newly attached
//    views get `focusRingType = .none` (and their cell). Also strip existing
//    trees when any window becomes key (sheets / Settings appear late).
// 3. Editing is preserved: disabling the decorative focus ring does not disable
//    first-responder focus, caret interaction, or keyboard equivalents.

/// Disables SwiftUI focus-effect chrome without affecting key equivalents.
extension View {
    @ViewBuilder
    func herdrmHideFocusRing() -> some View {
        self.focusEffectDisabled()
    }
}

/// Global AppKit policy: kill the blue outline ring on chrome controls.
enum HerdrFocusRing {
    private static var didInstall = false
    private static var keyWindowObserver: NSObjectProtocol?

    /// Call once from `AppDelegate.applicationDidFinishLaunching`.
    static func install() {
        guard !didInstall else { return }
        didInstall = true

        NSView.herdrmSwizzleViewDidMoveToWindowIfNeeded()

        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            strip(in: window)
        }

        for window in NSApp.windows {
            strip(in: window)
        }
    }

    static func strip(in window: NSWindow) {
        if let content = window.contentView {
            strip(in: content)
        }
        if let toolbar = window.toolbar {
            // Toolbar items host their own views; walk attached item views when present.
            for item in toolbar.items {
                if let view = item.view {
                    strip(in: view)
                }
            }
        }
    }

    static func strip(in root: NSView) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stripIfNeeded(view)
            stack.append(contentsOf: view.subviews)
        }
    }

    static func stripIfNeeded(_ view: NSView) {
        if view.focusRingType != .none {
            view.focusRingType = .none
        }
        if let control = view as? NSControl, let cell = control.cell, cell.focusRingType != .none {
            control.cell?.focusRingType = .none
        }
    }

}

// MARK: - NSView swizzle

private var herdrmDidSwizzleViewDidMoveToWindow = false

extension NSView {
    fileprivate static func herdrmSwizzleViewDidMoveToWindowIfNeeded() {
        guard !herdrmDidSwizzleViewDidMoveToWindow else { return }
        herdrmDidSwizzleViewDidMoveToWindow = true

        let original = #selector(NSView.viewDidMoveToWindow)
        let swizzled = #selector(NSView.herdrm_viewDidMoveToWindow)
        guard
            let originalMethod = class_getInstanceMethod(NSView.self, original),
            let swizzledMethod = class_getInstanceMethod(NSView.self, swizzled)
        else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc fileprivate func herdrm_viewDidMoveToWindow() {
        // After exchange this calls the real implementation.
        herdrm_viewDidMoveToWindow()
        // Only act once we are actually in a window (not on detach).
        guard window != nil else { return }
        HerdrFocusRing.stripIfNeeded(self)
    }
}
