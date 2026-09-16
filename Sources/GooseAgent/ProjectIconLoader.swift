import Darwin
import Foundation
import ImageIO

/// Local files only. Actor isolation keeps discovery and decoding off the UI executor.
actor ProjectIconLoader {
    static let shared = ProjectIconLoader()

    private struct CachedIcon {
        let image: CGImage?
        let date: Date
    }
    private var cache: [String: CachedIcon] = [:]
    private let extensions = ["png", "webp", "icns", "ico"]
    private let stems = [
        "favicon", "public/favicon", "app/favicon", "app/icon", "src/favicon",
        "src/app/icon", "assets/favicon", "assets/icon", "static/favicon",
        "logo", "public/logo", "public/icon", "src-tauri/icons/icon", "app-icon", "icon",
        "AppIcon", "Resources/AppIcon", "Resources/icon",
    ]
    private let iconDirectories = [
        "Resources/AppIcon", "Assets.xcassets/AppIcon.appiconset",
        "Resources/Assets.xcassets/AppIcon.appiconset",
        "Assets/AppIcon.appiconset", "AppIcon.appiconset",
    ]

    func image(for path: String) -> CGImage? {
        guard !Task.isCancelled,
              path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return nil }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        let root = projectRoot(directory)
        // ponytail: refresh on the next appearance after 60s; add file watching for live logo edits.
        if let cached = cache[root.path], Date().timeIntervalSince(cached.date) < 60 {
            return cached.image
        }
        let image = findIcon(in: root)
        guard !Task.isCancelled else { return nil }
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[root.path] = CachedIcon(image: image, date: Date())
        return image
    }

    private func projectRoot(_ directory: URL) -> URL {
        var current = directory
        while current.path != "/" {
            // A worktree's .git is a file, not a directory.
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return directory
    }

    private func findIcon(in root: URL) -> CGImage? {
        for stem in stems {
            for ext in extensions {
                guard !Task.isCancelled else { return nil }
                if let icon = thumbnail(at: root.appendingPathComponent("\(stem).\(ext)"), in: root) {
                    return icon
                }
            }
        }
        // Only designated icon folders, never a recursive search through project files.
        for relative in iconDirectories {
            let directory = root.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard isInside(directory, root: root),
                  let entries = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                  ) else { continue }
            let candidates = entries.prefix(64).compactMap { $0 as? URL }
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                if let icon = thumbnail(at: candidate, in: root) { return icon }
            }
        }
        return nil
    }

    private func isInside(_ file: URL, root: URL) -> Bool {
        file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    private func thumbnail(at candidate: URL, in root: URL) -> CGImage? {
        let file = candidate.resolvingSymlinksInPath()
        guard isInside(file, root: root) else { return nil }
        // Verify the opened descriptor too: a project may contain symlinks or special files.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        var openedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let maxBytes = 4 * 1024 * 1024
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maxBytes,
              fcntl(descriptor, F_GETPATH, &openedPath) == 0,
              isInside(URL(fileURLWithPath: String(cString: openedPath)).resolvingSymlinksInPath(), root: root),
              let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "org.webmproject.webp", "com.apple.icns", "com.microsoft.ico"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
