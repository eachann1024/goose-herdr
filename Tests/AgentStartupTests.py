#!/usr/bin/env python3
"""Run the real startup retry loop: python3 Tests/AgentStartupTests.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift").read_text()
start = source.index("    public func startAgent(")
end = source.index("    private func paneTerminalID(", start)
method = source[start:end].replace("public func", "func")
harness = r'''
import Foundation
indirect enum JSONValue { case string(String), array([JSONValue]), object([String: JSONValue]) }
enum HerdrError: Error { case rpc(String, String) }
@MainActor final class Service {
    var attempts = 0
    var probes = 0
    var failures = 2
    var replacement = false
    var code = "agent_pane_busy"
    func client() throws -> Service { self }
    func request(method: String, params: JSONValue) async throws {
        // No process inspection: a shell startup child may own the foreground.
        assert(method == "agent.start")
        attempts += 1
        if attempts <= failures { throw HerdrError.rpc(code, "original") }
    }
    func paneTerminalID(_ pane: String) async throws -> String? {
        probes += 1
        return replacement && probes > 1 ? "replacement" : "original"
    }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async throws {
        let ready = Service()
        try await ready.startAgent(name: "pi", kind: "pi", paneID: "new", waitForShell: true)
        assert(ready.attempts == 3, "startup foreground children must not abort readiness retries")
        for scenario in ["replacement", "no-wait", "other-error", "timeout"] {
            let service = Service()
            service.replacement = scenario == "replacement"
            if scenario == "other-error" { service.code = "agent_name_taken" }
            if scenario == "timeout" { service.failures = Int.max }
            let start = ContinuousClock.now
            do {
                try await service.startAgent(name: "pi", kind: "pi", paneID: "new", waitForShell: scenario != "no-wait")
                assertionFailure("expected original error")
            } catch HerdrError.rpc(let code, let message) {
                assert(code == service.code && message == "original")
            }
            if scenario == "timeout" {
                assert(service.attempts > 1 && start.duration(to: .now) < .seconds(3))
            } else {
                assert(service.attempts == 1, "do not retry replacement terminals or unrelated errors")
            }
        }
        print("PASS: bounded shell readiness retries preserve identity and server errors")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="agent-startup-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
