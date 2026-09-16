#!/usr/bin/env python3
"""⌘1…9 slot mapping: python3 Tests/SessionSwitchIndexTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/SessionIndexHints.swift").read_text()
start = source.index("enum SessionSwitchIndex {")
end = source.index("\n    // MARK: - Session index hints")
mapping = source[start:end] + "\n}\n"
assert "milliseconds(150)" in mapping

harness = r'''
import Foundation
''' + mapping + r'''
@main struct Check {
    static func main() {
        precondition(SessionSwitchIndex.holdDuration == .milliseconds(150))

        precondition(SessionSwitchIndex.number(forIndex: 0, count: 0) == nil)
        precondition(SessionSwitchIndex.index(forNumber: 1, count: 0) == nil)

        for index in 0..<4 {
            precondition(SessionSwitchIndex.number(forIndex: index, count: 4) == index + 1)
        }
        precondition(SessionSwitchIndex.number(forIndex: 4, count: 4) == nil)
        precondition(SessionSwitchIndex.index(forNumber: 4, count: 4) == 3)
        precondition(SessionSwitchIndex.index(forNumber: 5, count: 4) == nil)
        precondition(SessionSwitchIndex.index(forNumber: 9, count: 4) == 3)

        for index in 0..<8 {
            precondition(SessionSwitchIndex.number(forIndex: index, count: 8) == index + 1)
        }
        precondition(SessionSwitchIndex.index(forNumber: 9, count: 8) == 7)

        for index in 0..<9 {
            precondition(SessionSwitchIndex.number(forIndex: index, count: 9) == index + 1)
        }

        for index in 0..<8 {
            precondition(SessionSwitchIndex.number(forIndex: index, count: 12) == index + 1)
        }
        precondition(SessionSwitchIndex.number(forIndex: 8, count: 12) == nil)
        precondition(SessionSwitchIndex.number(forIndex: 10, count: 12) == nil)
        precondition(SessionSwitchIndex.number(forIndex: 11, count: 12) == 9)
        precondition(SessionSwitchIndex.index(forNumber: 8, count: 12) == 7)
        precondition(SessionSwitchIndex.index(forNumber: 9, count: 12) == 11)
        precondition(SessionSwitchIndex.index(forNumber: 0, count: 12) == nil)
        precondition(SessionSwitchIndex.index(forNumber: 10, count: 12) == nil)
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "SessionSwitchIndexTests.swift"
    path.write_text(harness)
    subprocess.check_call(["swiftc", "-parse-as-library", str(path), "-o", str(Path(tmp) / "check")])
    subprocess.check_call([str(Path(tmp) / "check")])
print("ok")
