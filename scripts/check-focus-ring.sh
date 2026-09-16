#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/main.swift" <<'SWIFT'
import AppKit

func state(_ view: NSView) -> (Bool, Bool, Bool) {
    let editable: Bool
    let selectable: Bool
    if let field = view as? NSTextField {
        editable = field.isEditable
        selectable = field.isSelectable
    } else if let textView = view as? NSTextView {
        editable = textView.isEditable
        selectable = textView.isSelectable
    } else {
        editable = false
        selectable = false
    }
    return (editable, selectable, view.acceptsFirstResponder)
}

func check(_ view: NSView, _ name: String, _ before: (Bool, Bool, Bool)) {
    HerdrFocusRing.stripIfNeeded(view)
    assert(view.focusRingType == .none, "\(name) view focus ring")
    if let control = view as? NSControl, let cell = control.cell {
        assert(cell.focusRingType == NSFocusRingType.none, "\(name) cell focus ring")
    }
    let after = state(view)
    assert(before.0 == after.0 && before.1 == after.1 && before.2 == after.2,
           "\(name) editing/focus behavior changed")
}

let views: [(NSView, String)] = [
    (NSTextField(), "text field"),
    (NSSecureTextField(), "secure text field"),
    (NSTextView(), "text view"),
    (NSButton(), "button")
]
for (view, name) in views {
    check(view, name, state(view))
}
print("focus-ring policy: OK")
SWIFT

swiftc "$dir/Sources/GooseAgent/FocusRing.swift" "$tmp/main.swift" -o "$tmp/check-focus-ring"
"$tmp/check-focus-ring"
