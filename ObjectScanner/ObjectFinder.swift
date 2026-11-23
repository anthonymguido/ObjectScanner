import SwiftUI
import ARKit
import Vision
import CoreImage

/// "Find object" step that runs before Object Capture.
/// Uses the same subject-lifting model as Photos (Vision foreground instance masks) to trace the
/// object's border on the live camera feed, and LiDAR depth to check its distance and size.
/// When the object is centered, close enough and big enough for long enough, `isReady` turns true.
@MainActor
final class ObjectFinder: NSObject, ObservableObject {
    // What the UI shows
    @Published private(set) var outline: CGImage?          // portrait, same aspect as the camera image
    @Published private(set) var imageSize: CGSize = .zero  // size of the image the outline belongs to
    @Published private(set) var objectFound = false
    @Published private(set) var instanceCount = 0
    @Published private(set) var isCentered = false
    @Published private(set) var distance: Float?           // metres
    @Published private(set) var sizeCM: CGSize?            // width x height, centimetres
    @Published private(set) var trackingNormal = false
    @Published private(set) var isReady = false            // held "good" for `holdTime`

    // Tuning
    static let distanceRange: ClosedRange<Float> = 0.3...1.5
    static let minSizeCM: CGFloat = 5
    static let maxSizeCM: CGFloat = 120
    private let holdTime: TimeInterval = 1.0
    private let interval: TimeInterval = 0.2               // about 5 analyses a second

    let session = ARSession()
    private let queue = DispatchQueue(label: "ObjectFinder.vision", qos: .userInitiated)
    private let ciContext = CIContext()
    private var busy = false
    private var lastRun = Date.distantPast
    private var goodSince: Date?
    private var running = false

    /// A tap picks the object under the finger (normalized portrait image coordinates).
    private var tapPoint: CGPoint?
    /// Remembered pick, so the outline sticks to the chosen object between frames.
    private var lastCentroid: CGPoint?

    func start() {
        guard !running, ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    /// Stops the camera so Object Capture can take it over.
    func stop() {
        guard running else { return }
        session.pause()
        session.delegate = nil
        running = false
        isReady = false
        goodSince = nil
    }

    /// `point` is in normalized portrait image coordinates (0...1, origin top-left).
    func select(at point: CGPoint) {
        tapPoint = point
        lastCentroid = nil
        goodSince = nil
    }

    // MARK: - Frame analysis

    private func consider(_ frame: ARFrame) {
        let tracking: Bool
        if case .normal = frame.camera.trackingState { tracking = true } else { tracking = false }
        if tracking != trackingNormal { trackingNormal = tracking }

        guard running, !busy, Date().timeIntervalSince(lastRun) >= interval else { return }
        busy = true
        lastRun = Date()

        let input = FrameInput(image: frame.capturedImage,
                               depth: frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap,
                               fx: frame.camera.intrinsics.columns.0.x,
                               imageResolution: frame.camera.imageResolution,
                               tap: tapPoint,
                               previous: lastCentroid)
        tapPoint = nil
        let context = ciContext

        queue.async { [weak self] in
            let result = Self.analyze(input, context: context)
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.apply(result) }
            }
        }
    }

    private func apply(_ r: FrameResult) {
        busy = false
        guard running else { return }
        instanceCount = r.instanceCount
        objectFound = r.found
        outline = r.outline
        imageSize = r.imageSize
        lastCentroid = r.centroid
        isCentered = r.centroid.map { abs($0.x - 0.5) < 0.2 && abs($0.y - 0.5) < 0.2 } ?? false
        distance = r.distance
        sizeCM = r.sizeCM

        let good = objectFound && isCentered && trackingNormal
            && (distance.map { Self.distanceRange.contains($0) } ?? false)
            && (sizeCM.map { max($0.width, $0.height) >= Self.minSizeCM && max($0.width, $0.height) <= Self.maxSizeCM } ?? false)
        if good {
            if goodSince == nil { goodSince = Date() }
            let ready = Date().timeIntervalSince(goodSince!) >= holdTime
            if ready != isReady { isReady = ready }
        } else {
            goodSince = nil
            if isReady { isReady = false }
        }
    }

    // MARK: - Background work (no actor state touched here)

    private struct FrameInput {
        let image: CVPixelBuffer
        let depth: CVPixelBuffer?
        let fx: Float
        let imageResolution: CGSize
        let tap: CGPoint?
        let previous: CGPoint?
    }

    private struct FrameResult {
        var instanceCount = 0
        var found = false
        var outline: CGImage?
        var imageSize: CGSize = .zero
        var centroid: CGPoint?
        var distance: Float?
        var sizeCM: CGSize?
    }

    private struct InstanceStats {
        var count = 0
        var sumX = 0.0, sumY = 0.0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    }

    private nonisolated static func analyze(_ input: FrameInput, context: CIContext) -> FrameResult {
        var result = FrameResult()

        // Upright portrait copy of the camera image, scaled down for speed.
        let upright = CIImage(cvPixelBuffer: input.image).oriented(.right)
        let scale = 480 / upright.extent.height
        let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return result }
        result.imageSize = CGSize(width: cg.width, height: cg.height)

        // Subject lifting: one label per foreground object (0 is background).
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return result }
        guard let observation = request.results?.first else { return result }
        result.instanceCount = observation.allInstances.count
        guard !observation.allInstances.isEmpty else { return result }

        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return result }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let labels = base.assumingMemoryBound(to: UInt8.self)
        func label(_ x: Int, _ y: Int) -> UInt8 { labels[y * rowBytes + x] }

        // Per-instance centroid and bounding box.
        var stats = [UInt8: InstanceStats]()
        for y in 0..<h {
            for x in 0..<w {
                let l = label(x, y)
                guard l != 0 else { continue }
                var s = stats[l] ?? InstanceStats()
                s.count += 1
                s.sumX += Double(x); s.sumY += Double(y)
                s.minX = min(s.minX, x); s.maxX = max(s.maxX, x)
                s.minY = min(s.minY, y); s.maxY = max(s.maxY, y)
                stats[l] = s
            }
        }
        guard !stats.isEmpty else { return result }

        func centroid(_ s: InstanceStats) -> CGPoint {
            CGPoint(x: s.sumX / Double(s.count) / Double(w), y: s.sumY / Double(s.count) / Double(h))
        }

        // Pick: tapped object, else the one we followed last frame, else the one nearest the center.
        var chosen: UInt8?
        if let tap = input.tap {
            let tx = min(max(Int(tap.x * CGFloat(w)), 0), w - 1)
            let ty = min(max(Int(tap.y * CGFloat(h)), 0), h - 1)
            let l = label(tx, ty)
            if l != 0 { chosen = l }
        }
        if chosen == nil {
            let target = input.previous ?? CGPoint(x: 0.5, y: 0.5)
            chosen = stats.min { a, b in
                hypot(centroid(a.value).x - target.x, centroid(a.value).y - target.y)
                    < hypot(centroid(b.value).x - target.x, centroid(b.value).y - target.y)
            }?.key
        }
        guard let pick = chosen, let s = stats[pick] else { return result }
        result.found = true
        let c = centroid(s)
        result.centroid = c

        // Outline: edge pixels of the chosen object, thickened a little, plus a faint fill.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in max(s.minY, 0)...min(s.maxY, h - 1) {
            for x in max(s.minX, 0)...min(s.maxX, w - 1) where label(x, y) == pick {
                var edge = false
                outer: for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h || label(nx, ny) != pick { edge = true; break outer }
                    }
                }
                let i = (y * w + x) * 4
                if edge {
                    rgba[i] = 0; rgba[i + 1] = 230; rgba[i + 2] = 255; rgba[i + 3] = 255
                } else {   // premultiplied faint cyan fill
                    rgba[i] = 0; rgba[i + 1] = 35; rgba[i + 2] = 40; rgba[i + 3] = 40
                }
            }
        }
        if let provider = CGDataProvider(data: Data(rgba) as CFData) {
            result.outline = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        // LiDAR: median depth inside the object, then its real size from the pinhole camera model.
        if let depth = input.depth {
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
            if let dBase = CVPixelBufferGetBaseAddress(depth) {
                let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
                let dRow = CVPixelBufferGetBytesPerRow(depth)
                var samples = [Float]()
                let step = max(1, min(s.maxX - s.minX, s.maxY - s.minY) / 20)
                for y in stride(from: s.minY, through: s.maxY, by: step) {
                    for x in stride(from: s.minX, through: s.maxX, by: step) where label(x, y) == pick {
                        // Portrait (u, v) -> landscape sensor (x = v, y = 1 - u).
                        let u = (Double(x) + 0.5) / Double(w), v = (Double(y) + 0.5) / Double(h)
                        let lx = min(max(Int(v * Double(dw)), 0), dw - 1)
                        let ly = min(max(Int((1 - u) * Double(dh)), 0), dh - 1)
                        let d = dBase.advanced(by: ly * dRow).assumingMemoryBound(to: Float32.self)[lx]
                        if d.isFinite && d > 0.05 { samples.append(d) }
                    }
                }
                if !samples.isEmpty {
                    samples.sort()
                    let d = samples[samples.count / 2]
                    result.distance = d
                    if input.fx > 0 {
                        // Portrait width spans the sensor's height, portrait height spans its width.
                        let wFrac = Double(s.maxX - s.minX + 1) / Double(w)
                        let hFrac = Double(s.maxY - s.minY + 1) / Double(h)
                        let widthM = wFrac * Double(input.imageResolution.height) * Double(d) / Double(input.fx)
                        let heightM = hFrac * Double(input.imageResolution.width) * Double(d) / Double(input.fx)
                        result.sizeCM = CGSize(width: widthM * 100, height: heightM * 100)
                    }
                }
            }
        }
        return result
    }
}

extension ObjectFinder: ARSessionDelegate {
    // ARKit calls this on the main queue (no delegateQueue is set).
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.consider(frame) }
    }
}

/// Live camera feed for the finder (no 3D content).
struct FinderCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}
