import AppKit
import Foundation
import Observation
import HertzCore

@Observable
final class CleanupModel {
    var scan = CleanupScan()
    var isScanning = false
    var isCleaning = false
    var status = "Scan safe caches before cleaning."

    @ObservationIgnored private let scout = CleanupScout()

    var hasCandidates: Bool {
        !scan.candidates.isEmpty
    }

    func scanNow() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        status = "Scanning safe developer caches..."

        let scout = scout
        Task {
            let result = await Task.detached {
                scout.scan()
            }.value
            scan = result
            isScanning = false
            status = result.candidates.isEmpty
                ? "No safe cleanup candidates found."
                : "\(fmtMem(result.totalBytes)) reclaimable in \(result.candidates.count) safe groups."
        }
    }

    func cleanSafeCandidates() {
        guard hasCandidates, !isScanning, !isCleaning else { return }
        isCleaning = true
        status = "Cleaning safe cache groups..."
        let candidates = scan.candidates
        let scout = scout

        Task {
            let result = await Task.detached {
                scout.clean(candidates)
            }.value
            let freshScan = await Task.detached {
                scout.scan()
            }.value
            scan = freshScan
            isCleaning = false
            if result.failed.isEmpty {
                status = "Cleaned \(fmtMem(result.cleanedBytes)) across \(result.cleanedItems) items."
            } else {
                status = "Cleaned \(fmtMem(result.cleanedBytes)); \(result.failed.count) paths failed."
            }
        }
    }

    func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(scout.report(for: scan), forType: .string)
        status = "Cleanup report copied."
    }

    func reveal(_ candidate: CleanupCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: candidate.path)
        ])
    }
}
