import SwiftUI
import RealityKit

/// Owns the ObjectCaptureSession and mirrors its state for the guidance overlay.
/// The session is read on a short timer, which works the same on every iOS 17+ version.
@MainActor
final class CaptureModel: ObservableObject {
    enum Phase: Equatable {
        case initializing, ready, detecting, capturing, finishing, completed
        case failed(String)

        var debugName: String {
            switch self {
            case .initializing: return "initializing"
            case .ready: return "ready"
            case .detecting: return "detecting"
            case .capturing: return "capturing"
            case .finishing: return "finishing"
            case .completed: return "completed"
            case .failed(let m): return "failed(\(m))"
            }
        }
    }

    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var phase: Phase = .initializing
    @Published private(set) var feedbackNames: [String] = []
    @Published private(set) var hint: GuidanceText.Hint?
    @Published private(set) var shots = 0
    @Published private(set) var maxShots = 0
    @Published private(set) var passCompleted = false
    @Published private(set) var completedPasses = 0
    @Published private(set) var passNumber = 1
    @Published private(set) var flipped = false

    private var timer: Timer?
    private var hintChangedAt = Date.distantPast
    private var ignorePassUntil = Date.distantPast

    /// Minimum time a hint stays on screen, so it doesn't flicker.
    private let hintHold: TimeInterval = 1.5

    func start(imagesDirectory: URL, checkpointDirectory: URL) {
        guard session == nil else { return }
        let s = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        do {
            try s.start(imagesDirectory: imagesDirectory, configuration: configuration)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        session = s
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
        session = nil   // releases the camera and memory before reconstruction
    }

    // MARK: Actions

    func continueToDetecting() { _ = session?.startDetecting() }
    func resetBox() { session?.resetDetection() }
    func startCapturing() { session?.startCapturing() }
    func finish() { session?.finish() }
    func cancel() { session?.cancel() }

    func anotherPass() {
        session?.beginNewScanPass()
        startNextPass()
    }

    func flipAndScan() {
        session?.beginNewScanPassAfterFlip()
        flipped = true
        startNextPass()
    }

    private func startNextPass() {
        passNumber += 1
        passCompleted = false
        ignorePassUntil = Date().addingTimeInterval(1)
        hint = nil
    }

    // MARK: Polling

    private func poll() {
        guard let s = session else { return }

        let newPhase = Self.phase(for: s.state)
        if newPhase != phase { phase = newPhase }

        if s.numberOfShotsTaken != shots { shots = s.numberOfShotsTaken }
        if s.maximumNumberOfInputImages != maxShots { maxShots = s.maximumNumberOfInputImages }

        if Date() >= ignorePassUntil {
            let done = s.userCompletedScanPass
            if done && !passCompleted { completedPasses += 1 }
            if done != passCompleted { passCompleted = done }
        }

        let names = s.feedback.map { String(describing: $0) }.sorted()
        if names != feedbackNames { feedbackNames = names }
        updateHint()
    }

    private func updateHint() {
        let desired = GuidanceText.topHint(for: feedbackNames)
        guard desired != hint else { return }
        // A new warning replaces "all good" right away; otherwise hold the current hint a moment.
        if hint == nil || Date().timeIntervalSince(hintChangedAt) >= hintHold {
            withAnimation(.easeInOut(duration: 0.2)) { hint = desired }
            hintChangedAt = Date()
        }
    }

    private static func phase(for state: ObjectCaptureSession.CaptureState) -> Phase {
        switch state {
        case .initializing: return .initializing
        case .ready: return .ready
        case .detecting: return .detecting
        case .capturing: return .capturing
        case .finishing: return .finishing
        case .completed: return .completed
        case .failed(let error): return .failed(error.localizedDescription)
        @unknown default: return .initializing
        }
    }
}

/// Full-screen capture: Apple's camera view plus our step banner, live hints, progress and controls.
struct CaptureView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss

    let scanID: UUID
    var onComplete: (UUID) -> Void

    @StateObject private var model = CaptureModel()
    @State private var showDebug = false
    @State private var confirmCancel = false
    @State private var closing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = model.session {
                if model.passCompleted {
                    ObjectCapturePointCloudView(session: session)
                        .ignoresSafeArea()
                } else {
                    ObjectCaptureView(session: session)
                        .ignoresSafeArea()
                }
            } else if case .failed = model.phase {
                EmptyView()
            } else {
                ProgressView().tint(.white)
            }

            VStack(spacing: 10) {
                topBar
                StepBanner(text: bannerText)
                if let hint = visibleHint { HintPill(hint: hint) }
                if showDebug {
                    CaptureDebugPanel(phase: model.phase.debugName, feedback: model.feedbackNames,
                                      shots: model.shots, maxShots: model.maxShots,
                                      pass: model.passNumber, completedPasses: model.completedPasses,
                                      passCompleted: model.passCompleted, flipped: model.flipped)
                }
                Spacer()
                if showsProgress {
                    CaptureProgressLine(shots: model.shots, maxShots: model.maxShots,
                                        pass: model.passNumber, completedPasses: model.completedPasses,
                                        flipped: model.flipped)
                }
                controls
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .statusBarHidden()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start(imagesDirectory: store.imagesURL(for: scanID),
                        checkpointDirectory: store.checkpointURL(for: scanID))
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.tearDown()
        }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .completed: complete()
            case .failed(let message): recordFailure(message)
            default: break
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive) { discard() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The photos taken so far will be deleted.")
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Button {
                if model.shots == 0 { discard() } else { confirmCancel = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Cancel scan")
            Spacer()
            Button { showDebug.toggle() } label: {
                Image(systemName: showDebug ? "ladybug.fill" : "ladybug")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Show debug info")
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    private var bannerText: String {
        switch model.phase {
        case .initializing:
            return GuidanceText.starting
        case .ready:
            return model.flipped && model.passNumber > 1 ? GuidanceText.readyAfterFlip : GuidanceText.ready
        case .detecting:
            return GuidanceText.detecting
        case .capturing:
            return model.passCompleted
                ? GuidanceText.passDone(model.completedPasses, flipped: model.flipped)
                : GuidanceText.capturing(pass: model.passNumber)
        case .finishing:
            return GuidanceText.finishing
        case .completed:
            return GuidanceText.completed
        case .failed(let message):
            return GuidanceText.failed(message)
        }
    }

    /// Warnings show while aiming and capturing; "looking good" only while capturing.
    private var visibleHint: GuidanceText.Hint? {
        guard !model.passCompleted else { return nil }
        switch model.phase {
        case .ready, .detecting: return model.hint
        case .capturing: return model.hint ?? GuidanceText.lookingGood
        default: return nil
        }
    }

    private var showsProgress: Bool {
        switch model.phase {
        case .capturing, .finishing: return true
        case .ready, .detecting: return model.passNumber > 1
        default: return false
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .initializing:
            EmptyView()
        case .ready:
            primary("Continue", systemImage: "viewfinder") { model.continueToDetecting() }
        case .detecting:
            HStack {
                secondary("Reset box", systemImage: "arrow.counterclockwise") { model.resetBox() }
                primary("Start capture", systemImage: "record.circle") { model.startCapturing() }
            }
        case .capturing:
            if model.passCompleted {
                VStack(spacing: 8) {
                    HStack {
                        secondary("Another pass", systemImage: "arrow.triangle.2.circlepath") { model.anotherPass() }
                        secondary("Flip object", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.flipAndScan() }
                    }
                    primary("Done", systemImage: "checkmark") { model.finish() }
                }
            } else {
                secondary("Finish now", systemImage: "stop.circle") { model.finish() }
                    .disabled(model.shots == 0)
            }
        case .finishing, .completed:
            ProgressView().tint(.white).padding()
        case .failed:
            primary("Close", systemImage: "xmark") { dismiss() }
        }
    }

    private func primary(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func secondary(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .controlSize(.large)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Outcomes

    private func complete() {
        guard !closing else { return }
        closing = true
        let count = store.imageFiles(for: scanID).count
        let passes = max(model.completedPasses, 1)
        let flipped = model.flipped
        store.mutate(scanID) {
            $0.status = count > 0 ? .captured : .failed
            $0.imageCount = count
            $0.passes = passes
            $0.flipped = flipped
            $0.errorMessage = count > 0 ? nil : "No photos were saved."
        }
        model.tearDown()
        dismiss()
        if count > 0 { onComplete(scanID) }
    }

    private func recordFailure(_ message: String) {
        guard !closing else { return }
        let count = store.imageFiles(for: scanID).count
        store.mutate(scanID) {
            $0.imageCount = count
            $0.status = count > 0 ? .captured : .failed
            $0.errorMessage = "Capture stopped: \(message)"
        }
    }

    private func discard() {
        closing = true
        model.cancel()
        model.tearDown()
        store.delete(id: scanID)
        dismiss()
    }
}
