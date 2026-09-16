#!/usr/bin/env python3
"""Run: python3 Tests/NewSpacePresentationTests.py (uses the real presentation method)."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/ContentView.swift").read_text()
root = source.split("/// Titlebar metrics:")[0]
method = root[root.index("    @MainActor\n    private func prepareNewSpace()"):].rsplit("\n}", 1)[0]
assert '.task(id: model.showNewSpace) { await prepareNewSpace() }' in root
assert '.sheet(item: $newSpaceListing' in root
assert 'directoryLoaded' not in source and 'onListingReady' not in source
assert '_deviceID = State(initialValue: listing.device.id)' in source
assert '_entries = State(initialValue: initialEntries ?? [])' in source
assert '_listedRoot = State(initialValue: initialEntries == nil ? "" : "~")' in source

harness = r'''
import Foundation
struct Device {
    let id: UUID
    static let local = Device(id: UUID())
}
struct NewSpaceListing { let device: Device; let entries: [String] }
enum Failure: Error { case unreadable }
@MainActor final class Service {
    var pending: CheckedContinuation<[String], Error>?
    func listDirectories(at path: String) async throws -> [String] {
        assert(path == "~")
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: Result<[String], Error>) {
        let continuation = pending!
        pending = nil
        continuation.resume(with: result)
    }
}
@MainActor final class Model {
    var showNewSpace = true
    var deviceFilter: UUID?
    var devices = [Device.local]
    var actionError: String?
    let listingService = Service()
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    func service(for device: Device) -> Service { listingService }
}
@MainActor final class Presenter {
    let model = Model()
    var newSpaceListing: NewSpaceListing?
''' + method.replace("private func", "func") + r'''
}
@main struct Check {
    @MainActor static func main() async {
        let presenter = Presenter()
        let model = presenter.model
        let service = model.listingService
        let remote = Device(id: UUID())
        model.devices.append(remote)
        model.deviceFilter = remote.id
        let load = Task { await presenter.prepareNewSpace() }
        while service.pending == nil { await Task.yield() }
        assert(presenter.newSpaceListing == nil, "must not open before the reply")
        service.finish(.success(["Projects"]))
        await load.value
        assert(presenter.newSpaceListing?.device.id == remote.id)
        assert(presenter.newSpaceListing?.entries == ["Projects"])

        model.showNewSpace = false
        await presenter.prepareNewSpace()
        assert(presenter.newSpaceListing == nil)
        model.showNewSpace = true
        let empty = Task { await presenter.prepareNewSpace() }
        while service.pending == nil { await Task.yield() }
        service.finish(.success([]))
        await empty.value
        assert(presenter.newSpaceListing?.entries == [], "empty is loaded, not loading")

        model.showNewSpace = false
        await presenter.prepareNewSpace()
        model.showNewSpace = true
        let failure = Task { await presenter.prepareNewSpace() }
        while service.pending == nil { await Task.yield() }
        service.finish(.failure(Failure.unreadable))
        await failure.value
        assert(!model.showNewSpace && model.actionError != nil)
        assert(presenter.newSpaceListing == nil, "failure reports an error without opening")

        model.actionError = nil
        model.showNewSpace = true
        let cancelled = Task { await presenter.prepareNewSpace() }
        while service.pending == nil { await Task.yield() }
        cancelled.cancel()
        service.finish(.success(["stale"]))
        await cancelled.value
        assert(presenter.newSpaceListing == nil, "cancelled reply cannot open the sheet")

        let retry = Task { await presenter.prepareNewSpace() }
        while service.pending == nil { await Task.yield() }
        service.finish(.success(["fresh"]))
        await retry.value
        assert(presenter.newSpaceListing?.entries == ["fresh"])
        print("New Space: pending, success, empty, failure, cancellation and retry passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
