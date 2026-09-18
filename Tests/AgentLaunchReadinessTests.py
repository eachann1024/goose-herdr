#!/usr/bin/env python3
"""Leftover `pi`, readiness, timeout and cancellation: python3 Tests/AgentLaunchReadinessTests.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift").read_text()
start = source.index("    public func waitForStartedAgent(")
end = source.index("    public func closePane(", start)
method = source[start:end].replace("public func", "func").replace("public static func", "static func")
harness = r'''
import Foundation
indirect enum JSONValue { case string(String), array([JSONValue]), object([String: JSONValue]) }
struct AgentInfo {
    var paneID: String
    var agentKindRaw: String?
    var launchPending: Bool?
    var interactiveReady: Bool?
}
@MainActor final class Service {
    var screens: [String]
    var enters = 0
    var reads = 0
    var ready: AgentInfo?
    init(screens: [String], ready: AgentInfo? = nil) {
        self.screens = screens
        self.ready = ready
    }
    func readPane(paneID: String) async throws -> (text: String, revision: Int) {
        reads += 1
        let text = screens.isEmpty ? "" : screens.removeFirst()
        return (text, reads)
    }
    func sendKeys(paneID: String, keys: [String]) async throws {
        assert(keys == ["enter"])
        enters += 1
    }
    func agents() async throws -> [AgentInfo] {
        ready.map { [$0] } ?? []
    }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async {
        let leftover = """
        ~
        ❯
        ❯
        ❯ pi
        """
        assert(Service.looksLikeLeftoverLaunchCommand(leftover, kind: "pi"))
        assert(Service.looksLikeLeftoverLaunchCommand("❯ pi", kind: "pi"))
        assert(Service.looksLikeLeftoverLaunchCommand("$ pi", kind: "pi"))
        let ansi = "\u{1B}[32m❯\u{1B}[0m pi"
        assert(Service.looksLikeLeftoverLaunchCommand(Service.stripANSI(ansi), kind: "pi"))
        assert(!Service.looksLikeLeftoverLaunchCommand("❯", kind: "pi"))
        assert(!Service.looksLikeLeftoverLaunchCommand("Welcome to pi\n>", kind: "pi"))
        assert(Service.looksLikeBareShell("~\n❯\n❯"))
        assert(Service.looksLikeStartedAgent("ctrl+c to exit\nAsk anything", kind: "pi"))
        assert(!Service.looksLikeStartedAgent(leftover, kind: "pi"))

        let retry = Service(screens: [leftover, leftover, "Welcome to pi\nAsk"])
        let retryReady = await retry.waitForStartedAgent(kind: "pi", paneID: "p1")
        assert(retryReady)
        assert(retry.enters == 0, "waiting must not submit extra Enter into Pi")
        assert(retry.reads >= 1)

        let ready = Service(
            screens: ["~\n❯"],
            ready: AgentInfo(paneID: "p1", agentKindRaw: "pi", launchPending: false, interactiveReady: true)
        )
        let alreadyReady = await ready.waitForStartedAgent(kind: "pi", paneID: "p1")
        assert(alreadyReady)
        assert(ready.enters == 0, "an already-ready pane must not receive extra Enter")
        let pending = Service(
            screens: ["Welcome to fish"],
            ready: AgentInfo(paneID: "p1", agentKindRaw: "pi", launchPending: false, interactiveReady: false)
        )
        let pendingReady = await pending.waitForStartedAgent(kind: "pi", paneID: "p1")
        assert(!pendingReady, "timeout must not count as ready")
        assert(pending.reads == 0, "explicit not-ready must not fall through to shell banners")
        let cancelled = Task { await pending.waitForStartedAgent(kind: "pi", paneID: "p1") }
        cancelled.cancel()
        let cancelledReady = await cancelled.value
        assert(!cancelledReady)
        print("PASS: leftover launch command is detected; waiting does not send Enter")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="agent-launch-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
