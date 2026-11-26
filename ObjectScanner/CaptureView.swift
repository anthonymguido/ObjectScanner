import SwiftUI
import RealityKit
import ARKit
import CoreMotion

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

    // Extra photos on top of Apple's automatic ones.
    @Published var boostEnabled = AppSettings.boostEnabled {
        didSet { AppSettings.boostEnabled = boostEnabled }
    }
    /// 0…1, how often extra photos are taken. Saved between scans.
    @Published var photoRate = AppSettings.photoRate {
        didSet { AppSettings.photoRate = photoRate }
    }
    @Published private(set) var extraShots = 0
    @Published private(set) var canShoot = false
    @Published private(set) var degreesSinceShot: Double = 0
    /// Camera tracking as text: "normal", "insufficientFeatures", "excessiveMotion", "relocalizing", ...
    @Published private(set) var tracking = "normal"
    /// The session's tracking value exactly as it describes itself, for the debug panel.
    @Published private(set) var trackingRaw = ""

    var trackingNormal: Bool { tracking == "normal" }
    /// True when the photo count is close to Apple's per-scan limit.
    var nearPhotoLimit: Bool { maxShots > 0 && Double(shots) >= Double(maxShots) * photoLimitWarning }

    private var timer: Timer?
    private var hintChangedAt = Date.distantPast
    private var ignorePassUntil = Date.distantPast
    private var autoDetectAt: Date?
    private var lastExtraShot = Date.distantPast
    private let motion = CMMotionManager()
    private var lastMotionTimestamp: TimeInterval?

    /// Minimum time a hint stays on screen, so it doesn't flicker.
    private let hintHold: TimeInterval = 1.5
    /// Boost tuning comes from the photo rate: turn at least this far, and wait at least this long, between extra photos.
    private var boostMinDegrees: Double { AppSettings.boostDegrees(rate: photoRate) }
    private var boostMinInterval: TimeInterval { AppSettings.boostInterval(rate: photoRate) }
    /// Stop boosting at this share of the photo limit, leaving room for Apple's own shots.
    private let boostCeiling = 0.9
    /// Warn at this share of the photo limit.
    private let photoLimitWarning = 0.8
    /// Don't add photos while one of these warnings is showing.
    private let boostBlockers: Set<String> = ["movingTooFast", "outOfFieldOfView", "objectNotDetected", "environmentTooDark"]

    func start(imagesDirectory: URL, checkpointDirectory: URL) {
        guard session == nil else { return }
        let s = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        s.start(imagesDirectory: imagesDirectory, configuration: configuration)
        session = s
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        startMotion()
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
        motion.stopDeviceMotionUpdates()
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

    /// Manual shutter.
    func takePhoto() {
        guard canShoot else { return }
        shoot()
    }

    private func startNextPass() {
        passNumber += 1
        passCompleted = false
        ignorePassUntil = Date().addingTimeInterval(1)
        hint = nil
    }

    private func shoot() {
        session?.requestImageCapture()
        extraShots += 1
        lastExtraShot = Date()
        degreesSinceShot = 0
    }

    // MARK: Motion (how far the phone has turned since the last extra photo)

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        lastMotionTimestamp = nil
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated { self?.accumulate(data) }
        }
    }

    private func accumulate(_ data: CMDeviceMotion) {
        defer { lastMotionTimestamp = data.timestamp }
        guard let last = lastMotionTimestamp else { return }
        let dt = data.timestamp - last
        guard dt > 0, dt < 0.5 else { return }
        let r = data.rotationRate
        let radiansPerSecond = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        degreesSinceShot += radiansPerSecond * dt * 180 / .pi
        // Checked here too (30 times a second), so the 0.2 s poll doesn't cap high photo rates.
        boostIfUseful()
    }

    // MARK: Polling

    private func poll() {
        guard let s = session else { return }

        let newPhase = Self.phase(for: s.state)
        if newPhase != phase {
            // Entering "ready" (at the start and after a flip): look for the object by itself.
            if newPhase == .ready { autoDetectAt = Date().addingTimeInterval(0.6) }
            phase = newPhase
        }
        if phase == .ready, let at = autoDetectAt, Date() >= at {
            autoDetectAt = nil
            continueToDetecting()
        }

        if s.numberOfShotsTaken != shots { shots = s.numberOfShotsTaken }
        if s.maximumNumberOfInputImages != maxShots { maxShots = s.maximumNumberOfInputImages }
        if s.canRequestImageCapture != canShoot { canShoot = s.canRequestImageCapture }

        if Date() >= ignorePassUntil {
            let done = s.userCompletedScanPass
            if done && !passCompleted { completedPasses += 1 }
            if done != passCompleted { passCompleted = done }
        }

        let names = s.feedback.map { String(describing: $0) }.sorted()
        if names != feedbackNames { feedbackNames = names }
        let raw = String(describing: s.cameraTracking)
        if raw != trackingRaw { trackingRaw = raw }
        let t = Self.trackingName(s.cameraTracking)
        if t != tracking { tracking = t }
        updateHint()
        boostIfUseful()
    }

    private func boostIfUseful() {
        guard boostEnabled, phase == .capturing, !passCompleted, trackingNormal else { return }
        // Read live: the polled copy can be up to 0.2 s old.
        guard let s = session, s.canRequestImageCapture else { return }
        guard degreesSinceShot >= boostMinDegrees,
              Date().timeIntervalSince(lastExtraShot) >= boostMinInterval else { return }
        guard maxShots == 0 || Double(shots) < Double(maxShots) * boostCeiling else { return }
        guard !feedbackNames.contains(where: { boostBlockers.contains($0) }) else { return }
        shoot()
    }

    private func updateHint() {
        let capturing = phase == .capturing && !passCompleted
        let desired = GuidanceText.topHint(for: feedbackNames,
                                           tracking: phase == .initializing ? "normal" : tracking,
                                           nearPhotoLimit: capturing && nearPhotoLimit)
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

    /// Read as text, like the feedback, so the exact case names on each iOS version don't matter.
    private static func trackingName(_ state: ObjectCaptureSession.Tracking) -> String {
        let text = String(describing: state)
        for name in ["insufficientFeatures", "excessiveMotion", "relocalizing", "initializing", "notAvailable"]
        where text.localizedCaseInsensitiveContains(name) {
            return name
        }
        if text.localizedCaseInsensitiveContains("normal") { return "normal" }
        return "limited"
    }
}

/// Full-screen capture. First our "find object" step (border tracing + LiDAR), then Apple's
/// Object Capture with our step banner, live hints, progress and controls on top.
struct CaptureView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss

    let scanID: UUID
    var onComplete: (UUID) -> Void

    private enum Stage { case finding, handoff, capture }

    @StateObject private var model = CaptureModel()
    @StateObject private var finder = ObjectFinder()
    @State private var stage: Stage = .finding
    @State private var showDebug = false
    @State private var confirmCancel = false
    @State private var closing = false
    @State private var showTips = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch stage {
            case .finding:
                finderLayer
            case .handoff:
                ProgressView().tint(.white)
            case .capture:
                captureLayer
            }

            VStack(spacing: 10) {
                topBar
                StepBanner(text: bannerText)
                if stage == .finding, finder.objectFound {
                    FinderReadout(distance: finder.distance, sizeCM: finder.sizeCM)
                }
                if stage == .capture, let hint = visibleHint {
                    if hint.showsTips {
                        Button { showTips = true } label: { HintPill(hint: hint) }
                            .buttonStyle(.plain)
                    } else {
                        HintPill(hint: hint)
                    }
                }
                if showDebug { debugPanel }
                Spacer()
                if stage == .capture, model.phase == .capturing, !model.passCompleted {
                    PhotoRateControl(enabled: $model.boostEnabled, rate: $model.photoRate)
                }
                if stage == .capture, showsProgress {
                    CaptureProgressLine(shots: model.shots, maxShots: model.maxShots, extra: model.extraShots,
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
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                finder.start()
            } else {
                beginCapture(after: 0)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            finder.stop()
            model.tearDown()
        }
        .onChange(of: finder.isReady) { _, ready in
            if ready && stage == .finding { beginCapture(after: 0.8) }
        }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .completed: complete()
            case .failed(let message): recordFailure(message)
            default: break
            }
        }
        .sheet(isPresented: $showTips) {
            NavigationStack {
                TrackingTipsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showTips = false } }
                    }
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive) { discard() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The photos taken so far will be deleted.")
        }
    }

    // MARK: Layers

    /// Camera feed with the traced border. Tap an object to pick it.
    private var finderLayer: some View {
        GeometryReader { geo in
            ZStack {
                FinderCameraView(session: finder.session)
                FinderOutline(outline: finder.outline, ready: finder.isReady)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        if let p = imagePoint(for: point, in: geo.size) { finder.select(at: p) }
                    }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var captureLayer: some View {
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
    }

    /// Converts a tap on the full-screen camera view to normalized image coordinates,
    /// undoing the aspect-fill crop the camera feed uses.
    private func imagePoint(for point: CGPoint, in size: CGSize) -> CGPoint? {
        let image = finder.imageSize
        guard image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / image.width, size.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let u = (point.x - origin.x) / shown.width
        let v = (point.y - origin.y) / shown.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
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
            Button { showTips = true } label: {
                Image(systemName: "questionmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Tracking tips")
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

    private var debugPanel: some View {
        VStack(spacing: 6) {
            switch stage {
            case .finding, .handoff:
                CaptureDebugPanel(phase: "finding", feedback: [], shots: 0, maxShots: 0, pass: 1,
                                  completedPasses: 0, passCompleted: false, flipped: false,
                                  extraLines: finderDebugLines)
            case .capture:
                CaptureDebugPanel(phase: model.phase.debugName, feedback: model.feedbackNames,
                                  shots: model.shots, maxShots: model.maxShots,
                                  pass: model.passNumber, completedPasses: model.completedPasses,
                                  passCompleted: model.passCompleted, flipped: model.flipped,
                                  extraLines: [
                                    "boost: \(model.boostEnabled ? "on" : "off")  extra: \(model.extraShots)  canShoot: \(model.canShoot ? "yes" : "no")",
                                    String(format: "turned since last extra: %.1f°  rate: %.2f", model.degreesSinceShot, model.photoRate),
                                    AppSettings.rateDescription(model.photoRate),
                                    "tracking: \(model.tracking)  raw: \(model.trackingRaw)",
                                  ])
            }
        }
    }

    private var finderDebugLines: [String] {
        [
            "instances: \(finder.instanceCount)  found: \(finder.objectFound ? "yes" : "no")  centered: \(finder.isCentered ? "yes" : "no")",
            "distance: \(finder.distance.map { String(format: "%.2f m", $0) } ?? "–")  size: \(finder.sizeCM.map { String(format: "%.0f×%.0f cm", $0.width, $0.height) } ?? "–")",
            "tracking: \(finder.trackingNormal ? "normal" : "limited")  ready: \(finder.isReady ? "yes" : "no")",
        ]
    }

    private var bannerText: String {
        switch stage {
        case .finding:
            return GuidanceText.finder(found: finder.objectFound, instances: finder.instanceCount,
                                       centered: finder.isCentered, tracking: finder.trackingNormal,
                                       distance: finder.distance, sizeCM: finder.sizeCM, ready: finder.isReady)
        case .handoff:
            return GuidanceText.handoff
        case .capture:
            break
        }
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
        switch stage {
        case .finding:
            secondary("Skip, let the scanner find it", systemImage: "forward") { beginCapture(after: 0) }
        case .handoff:
            EmptyView()
        case .capture:
            captureControls
        }
    }

    @ViewBuilder
    private var captureControls: some View {
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
                HStack {
                    secondary("Finish now", systemImage: "stop.circle") { model.finish() }
                        .disabled(model.shots == 0)
                    Button { model.takePhoto() } label: {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .disabled(!model.canShoot)
                    .opacity(model.canShoot ? 1 : 0.4)
                    .accessibilityLabel("Take a photo")
                }
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

    /// Hands the camera from the finder to Object Capture. Only one AR session can run at a time.
    private func beginCapture(after delay: TimeInterval) {
        guard stage == .finding else { return }
        stage = .handoff
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            finder.stop()
            // Give ARKit a moment to release the camera before Object Capture opens it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !closing else { return }
                stage = .capture
                model.start(imagesDirectory: store.imagesURL(for: scanID),
                            checkpointDirectory: store.checkpointURL(for: scanID))
            }
        }
    }

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
        finder.stop()
        model.cancel()
        model.tearDown()
        store.delete(id: scanID)
        dismiss()
    }
}
