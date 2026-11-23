import SwiftUI
import RealityKit

/// Turns a scan's photos into a textured model.usdz on the phone. One build runs at a time.
@MainActor
final class Reconstructor: ObservableObject {
    @Published private(set) var activeScanID: UUID?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var secondsRemaining: TimeInterval?
    @Published private(set) var stage = ""

    var isRunning: Bool { activeScanID != nil }

    private var session: PhotogrammetrySession?
    private var task: Task<Void, Never>?

    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    func build(_ scanID: UUID, store: ScanStore) {
        guard !isRunning else { return }
        guard Self.isSupported else {
            store.mutate(scanID) {
                $0.status = .failed
                $0.errorMessage = "This device can't build 3D models."
            }
            return
        }
        let images = store.imagesURL(for: scanID)
        guard !store.imageFiles(for: scanID).isEmpty else {
            store.mutate(scanID) {
                $0.status = .failed
                $0.errorMessage = "This scan has no photos to build from."
            }
            return
        }

        let model = store.modelURL(for: scanID)
        let checkpoint = store.checkpointURL(for: scanID)
        try? FileManager.default.removeItem(at: model)
        try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

        activeScanID = scanID
        fraction = 0
        secondsRemaining = nil
        stage = "Preparing photos…"
        store.mutate(scanID) {
            $0.status = .processing
            $0.errorMessage = nil
        }
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task { [weak self] in
            var failure: String?
            var cancelled = false
            do {
                var configuration = PhotogrammetrySession.Configuration()
                configuration.checkpointDirectory = checkpoint
                configuration.isObjectMaskingEnabled = true
                let session = try PhotogrammetrySession(input: images, configuration: configuration)
                self?.session = session
                try session.process(requests: [.modelFile(url: model, detail: .reduced)]  // iOS builds "reduced" detail)

                for try await output in session.outputs {
                    guard let self else { break }
                    switch output {
                    case .requestProgress(_, let fractionComplete):
                        self.fraction = fractionComplete
                    case .requestProgressInfo(_, let info):
                        self.secondsRemaining = info.estimatedRemainingTime
                    case .inputComplete:
                        self.stage = "Building the 3D model…"
                    case .requestError(_, let error):
                        failure = error.localizedDescription
                    case .processingCancelled:
                        cancelled = true
                    case .processingComplete:
                        self.stage = "Finishing…"
                    default:
                        break
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            self?.finished(scanID, store: store, failure: failure, cancelled: cancelled)
        }
    }

    func cancel() {
        session?.cancel()
    }

    private func finished(_ scanID: UUID, store: ScanStore, failure: String?, cancelled: Bool) {
        let ok = store.hasModel(scanID) && failure == nil && !cancelled
        store.mutate(scanID) {
            if ok {
                $0.status = .ready
                $0.errorMessage = nil
            } else {
                $0.status = store.imageFiles(for: scanID).isEmpty ? .failed : .captured
                $0.errorMessage = cancelled ? "Model build was cancelled." : "Model build failed: \(failure ?? "no model was produced.")"
            }
        }
        session = nil
        task = nil
        activeScanID = nil
        stage = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
