#!/usr/bin/env python3
"""Run: python3 Tests/ProjectIconTests.py (real loader, isolated local fixtures)."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()
assert 'ProjectSpaceIcon(path: model.spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID))' in sidebar
assert 'spaceIconPath(device: entry.device, workspaceID: entry.pane.workspaceID)' in sidebar
assert 'spaceIconPath(device: entry.device, workspaceID: agent.workspaceID)' in sidebar
assert 'SpaceIcon(systemName: "square", size: min(size, 12), slot: slot)' in sidebar
assert 'BrandIcon(resource: "all-spaces", size: 14' in sidebar
model = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
assert 'func spaceIconPath(device: Device, workspaceID: String)' in model
search = (ROOT / "Sources/GooseAgent/SearchView.swift").read_text()
assert 'spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID)' in search

harness = r'''
import Darwin
import AppKit
import Foundation
import ImageIO

@main struct Check {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func directory(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func png(_ url: URL, width: Int = 64, height: Int = 64) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, context.makeImage()!, nil)
            assert(CGImageDestinationFinalize(output))
        }
        let loader = ProjectIconLoader()
        let repo = try directory("repo")
        try Data("gitdir: fixture".utf8).write(to: repo.appendingPathComponent(".git"))
        try png(repo.appendingPathComponent("public/favicon.png"), width: 64, height: 32)
        try png(repo.appendingPathComponent("icon.png"))
        let child = try directory("repo/src/nested")
        let first = await loader.image(for: child.path)
        assert(first?.width == 32 && first?.height == 16, "root discovery, precedence, aspect ratio")
        let cached = await loader.image(for: repo.path)
        assert(first === cached, "same canonical project reuses thumbnail")
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: repo)
        let aliased = await loader.image(for: alias.path)
        assert(first === aliased, "canonical cache key")

        let native = try directory("native")
        try png(native.appendingPathComponent("Resources/AppIcon/brand-1024.png"), width: 1024, height: 1024)
        let nativeImage = await loader.image(for: native.path)
        assert(nativeImage?.width == 32, "native AppIcon discovery and downsampling")
        let asset = try directory("asset")
        try png(asset.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Icon.png"))
        let assetImage = await loader.image(for: asset.path)
        assert(assetImage != nil, "asset catalog support")

        let corrupt = try directory("corrupt")
        try Data("not an image".utf8).write(to: corrupt.appendingPathComponent("favicon.png"))
        try png(corrupt.appendingPathComponent("icon.png"))
        let recovered = await loader.image(for: corrupt.path)
        assert(recovered != nil, "bad first candidate must not suppress later valid icon")

        let empty = try directory("empty")
        let missing = await loader.image(for: empty.path)
        assert(missing == nil)
        try png(empty.appendingPathComponent("icon.png"))
        let negativeCached = await loader.image(for: empty.path)
        assert(negativeCached == nil, "negative caching prevents repeated probes")
        let fresh = await ProjectIconLoader().image(for: empty.path)
        assert(fresh != nil)

        let escaped = try directory("escaped")
        try fm.createSymbolicLink(at: escaped.appendingPathComponent("icon.png"),
                                 withDestinationURL: repo.appendingPathComponent("icon.png"))
        let escapedImage = await loader.image(for: escaped.path)
        assert(escapedImage == nil, "outside-project symlink must be refused")
        let escapedFolder = try directory("escaped-folder/Resources")
        try fm.createSymbolicLink(at: escapedFolder.appendingPathComponent("AppIcon"),
                                 withDestinationURL: native.appendingPathComponent("Resources/AppIcon"))
        let escapedDirectoryImage = await loader.image(for: escapedFolder.deletingLastPathComponent().path)
        assert(escapedDirectoryImage == nil, "outside-project icon directory must be refused")

        let large = try directory("large")
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: large.appendingPathComponent("icon.png"))
        let tooLarge = await loader.image(for: large.path)
        assert(tooLarge == nil)
        let huge = try directory("huge")
        try png(huge.appendingPathComponent("icon.png"), width: 4097, height: 1)
        let tooWide = await loader.image(for: huge.path)
        assert(tooWide == nil, "pixel dimensions must be bounded")
        let fifo = try directory("fifo")
        assert(mkfifo(fifo.appendingPathComponent("icon.png").path, 0o600) == 0)
        let special = await loader.image(for: fifo.path)
        assert(special == nil, "special files must not block reads")
        for path in ["relative/path", "ssh://host/project", base.appendingPathComponent("missing").path] {
            let invalid = await loader.image(for: path)
            assert(invalid == nil)
        }
        let stack = NSImage(contentsOfFile: CommandLine.arguments[1] + "/Resources/SpaceIcons/all-spaces.svg")
        assert(stack?.tiffRepresentation != nil, "custom stack must render natively")
        let actual = await loader.image(for: CommandLine.arguments[1])
        assert(actual != nil, "this app's real AppIcon must be discovered")
        print("Project icons: discovery, cache, fallback, bounds and path safety passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    source.write_text(harness)
    subprocess.run(["swiftc", str(ROOT / "Sources/GooseAgent/ProjectIconLoader.swift"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(ROOT)], check=True, timeout=30)
