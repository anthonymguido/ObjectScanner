import SwiftUI
import UIKit

/// Saves the scan list as JSON, plus one folder per scan in the app's Documents folder:
///   Scans/<id>/Images/       photos taken by Object Capture
///   Scans/<id>/Checkpoint/   intermediate data that speeds up a rebuild
///   Scans/<id>/model.usdz    the finished 3D model
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [Scan] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("scans.json") }
    private let fm = FileManager.default

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Scans", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        recoverInterrupted()
    }

    func scan(_ id: UUID) -> Scan? {
        scans.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> Scan {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let scan = Scan(name: trimmed.isEmpty ? "Untitled scan" : trimmed)
        try? fm.createDirectory(at: imagesURL(for: scan.id), withIntermediateDirectories: true)
        try? fm.createDirectory(at: checkpointURL(for: scan.id), withIntermediateDirectories: true)
        scans.insert(scan, at: 0)
        save()
        return scan
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { try? fm.removeItem(at: folder(for: scans[i].id)) }
        scans.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        try? fm.removeItem(at: folder(for: id))
        scans.removeAll { $0.id == id }
        save()
    }

    func mutate(_ id: UUID, _ change: (inout Scan) -> Void) {
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return }
        change(&scans[i])
        save()
    }

    // MARK: - Files

    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func imagesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Images", isDirectory: true) }
    func checkpointURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Checkpoint", isDirectory: true) }
    func modelURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("model.usdz") }
    func pointCloudURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("pointcloud.ply") }
    func posesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("poses.json") }
    func tilesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("Tiles", isDirectory: true) }
    func printURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("print.stl") }

    /// True when the point cloud and poses for an export already exist.
    func hasExportData(_ id: UUID) -> Bool {
        fm.fileExists(atPath: pointCloudURL(for: id).path) && fm.fileExists(atPath: posesURL(for: id).path)
    }

    func hasModel(_ id: UUID) -> Bool { fm.fileExists(atPath: modelURL(for: id).path) }

    func imageFiles(for id: UUID) -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: imagesURL(for: id), includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func firstImageURL(for id: UUID) -> URL? { imageFiles(for: id).first }

    /// Removes the source photos and checkpoint to free space. The model is kept, but can't be rebuilt.
    func deletePhotos(for id: UUID) {
        try? fm.removeItem(at: imagesURL(for: id))
        try? fm.removeItem(at: checkpointURL(for: id))
        try? fm.createDirectory(at: imagesURL(for: id), withIntermediateDirectories: true)
        // The point cloud and poses are kept: they're small and still useful in an export.
        mutate(id) { $0.imageCount = 0 }
    }

    /// Total size of everything in a scan's folder, in bytes.
    func diskSize(for id: UUID) -> Int64 {
        guard let e = fm.enumerator(at: folder(for: id), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// A copy of the model named after the scan, for sharing.
    func shareableModelURL(for id: UUID) -> URL? {
        guard let scan = scan(id), hasModel(id) else { return nil }
        let safe = scan.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let dir = fm.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(safe.isEmpty ? "model" : safe).usdz")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: modelURL(for: id), to: dest)
            return dest
        } catch {
            print("Failed to prepare model for sharing: \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scans = (try? decoder.decode([Scan].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(scans).write(to: indexURL, options: .atomic)
        } catch {
            print("Failed to save scans: \(error)")
        }
    }

    /// If the app was closed during a capture or a build, put the scan back in a state the user can act on.
    private func recoverInterrupted() {
        var changed = false
        for i in scans.indices {
            let id = scans[i].id
            if hasModel(id), scans[i].status != .ready {
                scans[i].status = .ready
                scans[i].errorMessage = nil
                changed = true
                continue
            }
            let old = scans[i].status
            switch old {
            case .capturing, .processing:
                let count = imageFiles(for: id).count
                scans[i].imageCount = count
                scans[i].status = count > 0 ? .captured : .failed
                if old == .processing {
                    scans[i].errorMessage = "The app was closed while building the model. Tap Build 3D model to try again."
                } else if count > 0 {
                    scans[i].errorMessage = "The capture was interrupted, but its photos were kept."
                } else {
                    scans[i].errorMessage = "The capture was interrupted before any photos were taken."
                }
                changed = true
            default:
                break
            }
        }
        if changed { save() }
    }
}
