import Foundation

nonisolated public enum CleanupRisk: String, Sendable {
    case low
    case review

    public var label: String {
        switch self {
        case .low: return "safe cache"
        case .review: return "review"
        }
    }
}

nonisolated public struct CleanupCandidate: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let reason: String
    public let path: String
    public let bytes: UInt64
    public let itemCount: Int
    public let risk: CleanupRisk
    public let deleteContents: Bool

    public init(title: String, category: String, reason: String, path: String,
                bytes: UInt64, itemCount: Int, risk: CleanupRisk = .low,
                deleteContents: Bool) {
        self.id = path
        self.title = title
        self.category = category
        self.reason = reason
        self.path = path
        self.bytes = bytes
        self.itemCount = itemCount
        self.risk = risk
        self.deleteContents = deleteContents
    }
}

nonisolated public struct CleanupScan: Sendable {
    public let scannedAt: Date
    public let candidates: [CleanupCandidate]
    public let skipped: [String]

    public init(scannedAt: Date = Date(), candidates: [CleanupCandidate] = [],
                skipped: [String] = []) {
        self.scannedAt = scannedAt
        self.candidates = candidates
        self.skipped = skipped
    }

    public var totalBytes: UInt64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }

    public var itemCount: Int {
        candidates.reduce(0) { $0 + $1.itemCount }
    }
}

nonisolated public struct CleanupResult: Sendable {
    public let cleanedBytes: UInt64
    public let cleanedItems: Int
    public let failed: [String]

    public init(cleanedBytes: UInt64 = 0, cleanedItems: Int = 0,
                failed: [String] = []) {
        self.cleanedBytes = cleanedBytes
        self.cleanedItems = cleanedItems
        self.failed = failed
    }
}

nonisolated public final class CleanupScout: @unchecked Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func scan() -> CleanupScan {
        var candidates: [CleanupCandidate] = []
        var skipped: [String] = []

        for spec in Self.safeSpecs {
            let url = expand(spec.relativePath)
            guard isCleanablePath(url) else {
                skipped.append(url.path)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            switch spec.mode {
            case .contents:
                if let measured = measure(url), measured.bytes > 0 {
                    candidates.append(CleanupCandidate(
                        title: spec.title,
                        category: spec.category,
                        reason: spec.reason,
                        path: url.path,
                        bytes: measured.bytes,
                        itemCount: measured.items,
                        deleteContents: true))
                }
            case .children:
                for child in children(of: url, olderThan: spec.minimumAge) {
                    guard isCleanablePath(child) else {
                        skipped.append(child.path)
                        continue
                    }
                    if let measured = measure(child), measured.bytes > 0 {
                        candidates.append(CleanupCandidate(
                            title: spec.childTitle(for: child),
                            category: spec.category,
                            reason: spec.reason,
                            path: child.path,
                            bytes: measured.bytes,
                            itemCount: measured.items,
                            deleteContents: false))
                    }
                }
            }
        }

        return CleanupScan(candidates: candidates.sorted {
            if $0.bytes == $1.bytes { return $0.title < $1.title }
            return $0.bytes > $1.bytes
        }, skipped: skipped)
    }

    public func clean(_ candidates: [CleanupCandidate]) -> CleanupResult {
        var cleanedBytes: UInt64 = 0
        var cleanedItems = 0
        var failed: [String] = []

        for candidate in candidates where candidate.risk == .low {
            let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
            guard isCleanablePath(url), FileManager.default.fileExists(atPath: url.path) else {
                failed.append(candidate.path)
                continue
            }

            do {
                if candidate.deleteContents {
                    for child in children(of: url, includeHidden: true) {
                        guard isCleanablePath(child) else { continue }
                        try FileManager.default.removeItem(at: child)
                    }
                } else {
                    try FileManager.default.removeItem(at: url)
                }
                cleanedBytes += candidate.bytes
                cleanedItems += candidate.itemCount
            } catch {
                failed.append(candidate.path)
            }
        }

        return CleanupResult(cleanedBytes: cleanedBytes,
                             cleanedItems: cleanedItems,
                             failed: failed)
    }

    public func report(for scan: CleanupScan) -> String {
        var lines = [
            "Hertz Cleanup Scout",
            "Scanned: \(scan.scannedAt)",
            "Reclaimable: \(formatBytes(scan.totalBytes)) across \(scan.candidates.count) safe groups",
            ""
        ]

        for candidate in scan.candidates {
            lines.append("- \(candidate.title): \(formatBytes(candidate.bytes))")
            lines.append("  \(candidate.reason)")
            lines.append("  \(candidate.path)")
        }

        if !scan.skipped.isEmpty {
            lines.append("")
            lines.append("Skipped protected paths:")
            for path in scan.skipped {
                lines.append("- \(path)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func expand(_ relativePath: String) -> URL {
        let trimmed = relativePath.hasPrefix("~/")
            ? String(relativePath.dropFirst(2))
            : relativePath
        return homeDirectory.appendingPathComponent(trimmed).standardizedFileURL
    }

    private func isCleanablePath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = homeDirectory.path
        guard path.hasPrefix(home + "/") else { return false }
        guard !path.contains("/../"), !path.contains("/./") else { return false }
        guard !Self.protectedSuffixes.contains(where: { path == home + "/" + $0 }) else {
            return false
        }
        guard !Self.protectedPrefixes.contains(where: { path.hasPrefix(home + "/" + $0) }) else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return true
        }
        guard !isSymbolicLink(url) else { return false }
        return true
    }

    private func children(of url: URL, olderThan age: TimeInterval? = nil,
                          includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey,
                                         .isSymbolicLinkKey],
            options: options)
        else { return [] }

        let cutoff = age.map { Date().addingTimeInterval(-$0) }
        return urls.filter { child in
            guard !isSymbolicLink(child) else { return false }
            guard let cutoff else { return true }
            let modified = (try? child.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified < cutoff
        }
    }

    private func measure(_ url: URL) -> (bytes: UInt64, items: Int)? {
        guard !isSymbolicLink(url) else { return nil }

        if !isDirectory(url) {
            return (fileSize(url), 1)
        }

        var bytes: UInt64 = 0
        var items = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { return nil }

        for case let child as URL in enumerator {
            if isSymbolicLink(child) {
                enumerator.skipDescendants()
                continue
            }
            items += 1
            bytes += fileSize(child)
        }
        return (bytes, items)
    }

    private func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) == true
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                       .fileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize
                      ?? values?.fileAllocatedSize
                      ?? 0)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1_048_576 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

nonisolated private enum CleanupMode: Sendable {
    case contents
    case children
}

nonisolated private struct CleanupSpec: Sendable {
    let category: String
    let title: String
    let relativePath: String
    let reason: String
    let mode: CleanupMode
    let minimumAge: TimeInterval?

    func childTitle(for url: URL) -> String {
        "\(title): \(url.lastPathComponent)"
    }
}

private extension CleanupScout {
    nonisolated static let protectedSuffixes = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Library/Application Support",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Keychains",
        "Library/Mail",
        "Library/Messages",
        "Library/Mobile Documents",
        "Library/Preferences",
        "Movies",
        "Music",
        "Pictures",
        ".ssh",
        ".gnupg"
    ]

    nonisolated static let protectedPrefixes = [
        "Library/Application Support/",
        "Library/Containers/",
        "Library/Group Containers/",
        "Library/Keychains/",
        "Library/Mail/",
        "Library/Messages/",
        "Library/Mobile Documents/",
        "Library/Preferences/",
        ".ssh/",
        ".gnupg/"
    ]

    nonisolated static let safeSpecs: [CleanupSpec] = [
        CleanupSpec(category: "Xcode",
                    title: "DerivedData",
                    relativePath: "~/Library/Developer/Xcode/DerivedData",
                    reason: "Xcode build outputs; projects rebuild them when needed.",
                    mode: .children,
                    minimumAge: 12 * 60 * 60),
        CleanupSpec(category: "Xcode",
                    title: "Xcode cache",
                    relativePath: "~/Library/Caches/com.apple.dt.Xcode",
                    reason: "Xcode cache files; preserved folder, cleaned contents only.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Swift",
                    title: "SwiftPM cache",
                    relativePath: "~/Library/Caches/org.swift.swiftpm",
                    reason: "Swift package cache; packages download again when required.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Homebrew",
                    title: "Homebrew downloads",
                    relativePath: "~/Library/Caches/Homebrew/downloads",
                    reason: "Downloaded bottles and archives; Homebrew can fetch them again.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Node",
                    title: "npm package cache",
                    relativePath: "~/.npm/_cacache",
                    reason: "npm content-addressed cache; packages download again when needed.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Node",
                    title: "npm npx cache",
                    relativePath: "~/.npm/_npx",
                    reason: "Temporary npx package installs; regenerated per command.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Node",
                    title: "npm logs",
                    relativePath: "~/.npm/_logs",
                    reason: "npm log files; useful for recent debugging but safe to remove.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Node",
                    title: "Yarn cache",
                    relativePath: "~/Library/Caches/Yarn",
                    reason: "Yarn v1 cache; dependencies download again when needed.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Python",
                    title: "pip cache",
                    relativePath: "~/Library/Caches/pip",
                    reason: "pip wheel/download cache; packages download again when needed.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Python",
                    title: "pip cache",
                    relativePath: "~/.cache/pip",
                    reason: "pip wheel/download cache; packages download again when needed.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Python",
                    title: "uv cache",
                    relativePath: "~/.cache/uv",
                    reason: "uv package cache; packages download again when required.",
                    mode: .contents,
                    minimumAge: nil),
        CleanupSpec(category: "Python",
                    title: "Ruff cache",
                    relativePath: "~/.cache/ruff",
                    reason: "Ruff analysis cache; rebuilt automatically.",
                    mode: .contents,
                    minimumAge: nil)
    ]
}
