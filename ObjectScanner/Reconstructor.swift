import SwiftUI
import RealityKit

/// Turns a scan's photos into a textured model.usdz on the phone. One build runs at a time.
/// Each build also saves the reconstruction's point cloud (pointcloud.ply) and camera
/// positions (poses.json) for the export.
@MainActor
final class Reconstructor: ObservableObject {
    @Published private(set) var activeScanID: UUID?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var secondsRemaining: TimeInterval?
    @Published private(set) var stage = ""
    /// True while making only the point cloud and poses for an export (no model).
    @Published private(set) var exportDataOnly = false

    var isRunning: Bool { activeScanID != nil }

    private var session: PhotogrammetrySession?
    private var task: Task<Void, Never>?
    private var userCancelled = false

    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    private enum Job {
        case model(BuildQuality)
        case exportData
    }

    private struct RunResult {
        var modelFailure: String?
        var cancelled = false
        var pointCloudSaved = false
        var posesSaved = false
    }

    // MARK: Public

    func build(_ scanID: UUID, store: ScanStore, quality: BuildQuality = AppSettings.buildQuality) {
        guard prepare(scanID, store: store) else { return }
        try? FileManager.default.removeItem(at: store.modelURL(for: scanID))
        start(scanID, store: store, job: .model(quality), stageText: "Preparing photos…")
        store.mutate(scanID) {
            $0.status = .processing
            $0.errorMessage = nil
        }
    }

    /// Makes only pointcloud.ply and poses.json (for scans built before the app saved them).
    /// Calls `completion` with whether the user cancelled it.
    func makeExportData(_ scanID: UUID, store: ScanStore, completion: @escaping (_ cancelled: Bool) -> Void) {
        guard prepare(scanID, store: store) else { completion(false); return }
        exportCompletion = completion
        start(scanID, store: store, job: .exportData, stageText: "Making the point cloud…")
    }

    func cancel() {
        userCancelled = true
        session?.cancel()
    }

    // MARK: Tiled build test

    /// Experiment: does building the object in 8 cropped pieces give more triangles per area than
    /// one reduced build? Builds Tiles/tile_N.usdz and writes the triangle counts to the scan's note.
    /// The normal model is not touched.
    func tiledTest(_ scanID: UUID, store: ScanStore) {
        guard prepare(scanID, store: store) else { return }
        activeScanID = scanID
        fraction = 0
        secondsRemaining = nil
        stage = "Tiled test: measuring the object…"
        userCancelled = false
        exportDataOnly = false
        UIApplication.shared.isIdleTimerDisabled = true

        let images = store.imagesURL(for: scanID)
        let checkpoint = store.checkpointURL(for: scanID)
        let tilesDir = store.tilesURL(for: scanID)
        let modelURL = store.modelURL(for: scanID)
        try? FileManager.default.removeItem(at: tilesDir)
        try? FileManager.default.createDirectory(at: tilesDir, withIntermediateDirectories: true)

        task = Task { [weak self] in
            guard let self else { return }
            let note = await self.runTiledTest(images: images, checkpoint: checkpoint, tilesDir: tilesDir, modelURL: modelURL)
            store.mutate(scanID) { $0.buildNote = note }
            self.reset()
        }
    }

    private func runTiledTest(images: URL, checkpoint: URL, tilesDir: URL, modelURL: URL) async -> String {
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpoint
            configuration.isObjectMaskingEnabled = true
            configuration.sampleOrdering = .sequential

            // 1. The object's bounding box.
            let boundsSession = try PhotogrammetrySession(input: images, configuration: configuration)
            session = boundsSession
            try boundsSession.process(requests: [.bounds])
            var box: BoundingBox?
            var failure: String?
            loop: for try await output in boundsSession.outputs {
                switch output {
                case .requestProgress(_, let f): fraction = f
                case .requestComplete(_, let result):
                    if case .bounds(let b) = result { box = b }
                case .requestError(_, let error): failure = error.localizedDescription
                case .processingCancelled: return "Tiled test cancelled."
                case .processingComplete: break loop
                default: break
                }
            }
            guard let box else { return "Tiled test: couldn't measure the object (\(failure ?? "no bounds"))." }
            if userCancelled { return "Tiled test cancelled." }

            // 2. Eight overlapping pieces, each built at reduced detail.
            let tiles = Self.tileBoxes(box, divisions: 2, overlap: 0.1)
            let urls = tiles.indices.map { tilesDir.appendingPathComponent("tile_\($0 + 1).usdz") }
            let requests: [PhotogrammetrySession.Request] = zip(tiles, urls).map { tile, url in
                .modelFile(url: url, detail: .reduced, geometry: PhotogrammetrySession.Request.Geometry(bounds: tile))
            }
            let tileSession = try PhotogrammetrySession(input: images, configuration: configuration)
            session = tileSession
            try tileSession.process(requests: requests)
            var done = 0
            var errors: [String] = []
            fraction = 0
            stage = "Tiled test: building piece 1 of \(tiles.count)…"
            loop2: for try await output in tileSession.outputs {
                switch output {
                case .requestProgress(_, let f):
                    fraction = (Double(done) + f) / Double(tiles.count)
                case .requestProgressInfo(_, let info):
                    secondsRemaining = info.estimatedRemainingTime
                case .requestComplete(_, _):
                    done += 1
                    stage = "Tiled test: building piece \(min(done + 1, tiles.count)) of \(tiles.count)…"
                case .requestError(_, let error):
                    done += 1
                    errors.append(error.localizedDescription)
                case .processingCancelled: return "Tiled test cancelled."
                case .processingComplete: break loop2
                default: break
                }
            }
            session = nil

            // 3. Compare triangle counts.
            stage = "Tiled test: counting triangles…"
            let counts = urls.map { MeshIO.triangleCount(of: $0) }
            let total = counts.compactMap { $0 }.reduce(0, +)
            let normal = MeshIO.triangleCount(of: modelURL)
            let size = box.max - box.min
            var lines = [String(format: "Tiled test (object %.0f × %.0f × %.0f cm):", size.x * 100, size.y * 100, size.z * 100)]
            lines.append("Normal model: \(normal.map { "\($0.formatted()) triangles" } ?? "not built")")
            lines.append("8 pieces: " + counts.map { $0.map { $0.formatted() } ?? "–" }.joined(separator: ", "))
            lines.append("Pieces total: \(total.formatted()) triangles" +
                         (normal.map { $0 > 0 ? String(format: " (%.1f× the normal model)", Double(total) / Double($0)) : "" } ?? ""))
            if !errors.isEmpty { lines.append("Errors: " + Set(errors).joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        } catch {
            session = nil
            return "Tiled test failed: \(error.localizedDescription)"
        }
    }

    /// Splits a box into divisions³ pieces, each grown by `overlap` (a share of the piece size) on every side.
    private static func tileBoxes(_ box: BoundingBox, divisions: Int, overlap: Float) -> [BoundingBox] {
        let step = (box.max - box.min) / Float(divisions)
        let pad = step * overlap
        var result: [BoundingBox] = []
        for x in 0..<divisions {
            for y in 0..<divisions {
                for z in 0..<divisions {
                    let lo = box.min + step * SIMD3(Float(x), Float(y), Float(z))
                    result.append(BoundingBox(min: lo - pad, max: lo + step + pad))
                }
            }
        }
        return result
    }

    private var exportCompletion: ((Bool) -> Void)?

    // MARK: Running

    private func prepare(_ scanID: UUID, store: ScanStore) -> Bool {
        guard !isRunning else { return false }
        guard Self.isSupported else {
            store.mutate(scanID) { $0.errorMessage = "This device can't build 3D models." }
            return false
        }
        guard !store.imageFiles(for: scanID).isEmpty else {
            store.mutate(scanID) { $0.errorMessage = "This scan has no photos to build from." }
            return false
        }
        try? FileManager.default.createDirectory(at: store.checkpointURL(for: scanID), withIntermediateDirectories: true)
        return true
    }

    private func start(_ scanID: UUID, store: ScanStore, job: Job, stageText: String) {
        activeScanID = scanID
        fraction = 0
        secondsRemaining = nil
        stage = stageText
        userCancelled = false
        if case .exportData = job { exportDataOnly = true } else { exportDataOnly = false }
        UIApplication.shared.isIdleTimerDisabled = true

        let images = store.imagesURL(for: scanID)
        let checkpoint = store.checkpointURL(for: scanID)
        let modelURL = store.modelURL(for: scanID)
        let pointCloudURL = store.pointCloudURL(for: scanID)
        let posesURL = store.posesURL(for: scanID)

        task = Task { [weak self] in
            guard let self else { return }
            switch job {
            case .exportData:
                let result = await self.run(images: images, checkpoint: checkpoint, highSensitivity: false,
                                            model: nil, pointCloudURL: pointCloudURL, posesURL: posesURL)
                self.finishExportData(scanID, store: store, result: result)

            case .model(let quality):
                // iOS only builds reduced detail; higher detail needs a computer (see Export scan data).
                let result = await self.run(images: images, checkpoint: checkpoint,
                                            highSensitivity: quality.highFeatureSensitivity,
                                            model: (url: modelURL, detail: PhotogrammetrySession.Request.Detail.reduced),
                                            pointCloudURL: pointCloudURL, posesURL: posesURL)
                self.finishModel(scanID, store: store, result: result, qualityUsed: quality.title)
            }
        }
    }

    /// Runs one photogrammetry session. `model` nil means point cloud and poses only.
    private func run(images: URL, checkpoint: URL, highSensitivity: Bool,
                     model: (url: URL, detail: PhotogrammetrySession.Request.Detail)?,
                     pointCloudURL: URL, posesURL: URL) async -> RunResult {
        var result = RunResult()
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpoint
            configuration.isObjectMaskingEnabled = true
            configuration.featureSensitivity = highSensitivity ? .high : .normal
            // Object Capture takes photos in order around the object; this speeds up matching.
            configuration.sampleOrdering = .sequential
            let session = try PhotogrammetrySession(input: images, configuration: configuration)
            self.session = session

            var requests: [PhotogrammetrySession.Request] = [.pointCloud, .poses]
            if let model { requests.insert(.modelFile(url: model.url, detail: model.detail), at: 0) }
            do {
                try session.process(requests: requests)
            } catch {
                // Some phones may refuse the extra requests. Fall back to just the model.
                guard let model else { throw error }
                print("Point cloud / poses refused (\(error)); building the model only")
                try session.process(requests: [.modelFile(url: model.url, detail: model.detail)])
            }

            // The outputs stream does not end by itself after processing finishes,
            // so leave the loop on .processingComplete / .processingCancelled.
            outputLoop: for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fractionComplete):
                    fraction = fractionComplete
                case .requestProgressInfo(_, let info):
                    secondsRemaining = info.estimatedRemainingTime
                case .inputComplete:
                    stage = model == nil ? "Making the point cloud…" : "Building the 3D model…"
                case .requestComplete(let request, let requestResult):
                    switch requestResult {
                    case .pointCloud(let cloud):
                        result.pointCloudSaved = ScanDataWriter.writePLY(cloud, to: pointCloudURL)
                    case .poses(let poses):
                        result.posesSaved = ScanDataWriter.writePoses(poses, to: posesURL)
                    default:
                        if case .modelFile = request {
                            fraction = 1
                            stage = "Saving model…"
                        }
                    }
                case .requestError(let request, let error):
                    if case .modelFile = request {
                        result.modelFailure = error.localizedDescription
                    } else {
                        print("Optional request failed: \(error)")
                    }
                case .processingCancelled:
                    result.cancelled = true
                    break outputLoop
                case .processingComplete:
                    break outputLoop
                default:
                    break
                }
            }
        } catch {
            result.modelFailure = error.localizedDescription
        }
        session = nil
        if userCancelled { result.cancelled = true }
        return result
    }

    // MARK: Finishing

    private func finishModel(_ scanID: UUID, store: ScanStore, result: RunResult, qualityUsed: String) {
        let ok = store.hasModel(scanID) && !result.cancelled
        store.mutate(scanID) {
            if ok {
                $0.status = .ready
                $0.errorMessage = nil
                $0.builtQuality = qualityUsed
                $0.buildNote = nil
            } else {
                $0.status = store.imageFiles(for: scanID).isEmpty ? .failed : .captured
                $0.errorMessage = result.cancelled
                    ? "Model build was cancelled."
                    : "Model build failed: \(result.modelFailure ?? "no model was produced.")"
            }
        }
        reset()
    }

    private func finishExportData(_ scanID: UUID, store: ScanStore, result: RunResult) {
        let completion = exportCompletion
        exportCompletion = nil
        reset()
        completion?(result.cancelled)
    }

    private func reset() {
        session = nil
        task = nil
        activeScanID = nil
        exportDataOnly = false
        stage = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
