import Foundation
import RealityKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the point cloud and camera poses a build produces.
enum ScanDataWriter {
    /// Saves the reconstruction's point cloud as an ASCII PLY (opens in MeshLab, CloudCompare, Blender).
    static func writePLY(_ cloud: PhotogrammetrySession.PointCloud, to url: URL) -> Bool {
        let points = cloud.points
        var out = """
        ply
        format ascii 1.0
        comment Object Scanner point cloud (meters, Y up)
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        out.reserveCapacity(points.count * 40)
        for p in points {
            let c = rgb(p.color)
            out += "\(p.position.x) \(p.position.y) \(p.position.z) \(c.0) \(c.1) \(c.2)\n"
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to save point cloud: \(error)")
            return false
        }
    }

    /// Saves each photo's camera position (meters) and rotation (quaternion x, y, z, w) as JSON.
    static func writePoses(_ poses: PhotogrammetrySession.Poses, to url: URL) -> Bool {
        var cameras: [[String: Any]] = []
        for (sample, pose) in poses.posesBySample.sorted(by: { $0.key < $1.key }) {
            let q = pose.rotation.vector
            var entry: [String: Any] = [
                "sample": sample,
                "position": [pose.translation.x, pose.translation.y, pose.translation.z],
                "rotation_xyzw": [q.x, q.y, q.z, q.w],
            ]
            if let file = poses.urlsBySample[sample] { entry["image"] = file.lastPathComponent }
            cameras.append(entry)
        }
        let json: [String: Any] = [
            "description": "Camera pose for each photo, in the model's coordinate space (meters, Y up). Rotation is a quaternion.",
            "cameras": cameras,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("Failed to save poses: \(error)")
            return false
        }
    }

    // The point color type differs between SDK versions, so accept the likely ones.
    private static func rgb(_ c: SIMD4<UInt8>) -> (UInt8, UInt8, UInt8) { (c.x, c.y, c.z) }
    private static func rgb(_ c: SIMD3<UInt8>) -> (UInt8, UInt8, UInt8) { (c.x, c.y, c.z) }
    private static func rgb(_ c: SIMD4<Float>) -> (UInt8, UInt8, UInt8) { (byte(c.x), byte(c.y), byte(c.z)) }
    private static func rgb(_ c: SIMD3<Float>) -> (UInt8, UInt8, UInt8) { (byte(c.x), byte(c.y), byte(c.z)) }
    private static func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
}

/// Packs everything a computer needs to rebuild the model into one zip:
/// photos, LiDAR depth maps, point cloud, camera poses and the phone's model.
enum ScanExporter {
    struct Input {
        let name: String
        let imageFiles: [URL]
        let pointCloud: URL
        let poses: URL
        let model: URL
    }

    /// Builds the zip on a background thread and returns its URL.
    static func export(_ input: Input) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try makeZip(input)
        }.value
    }

    private static func makeZip(_ input: Input) throws -> URL {
        let fm = FileManager.default
        let safe = input.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let base = (safe.isEmpty ? "Scan" : safe) + " scan data"
        let work = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent(base, isDirectory: true)
        let imagesDir = folder.appendingPathComponent("Images", isDirectory: true)
        let depthDir = folder.appendingPathComponent("Depth", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthDir, withIntermediateDirectories: true)

        // Photos (each HEIC also carries its LiDAR depth map and gravity inside).
        var intrinsics: [String: Any] = [:]
        var depthCount = 0
        for image in input.imageFiles {
            try fm.copyItem(at: image, to: imagesDir.appendingPathComponent(image.lastPathComponent))
            let stem = image.deletingPathExtension().lastPathComponent
            if let depth = depthData(from: image) {
                let png = depthDir.appendingPathComponent(stem + "_depth.png")
                if writeDepthPNG(depth, to: png) {
                    depthCount += 1
                    intrinsics[stem] = calibration(of: depth)
                }
            }
        }
        if !intrinsics.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: intrinsics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: depthDir.appendingPathComponent("intrinsics.json"))
        }

        let hasCloud = fm.fileExists(atPath: input.pointCloud.path)
        let hasPoses = fm.fileExists(atPath: input.poses.path)
        let hasModel = fm.fileExists(atPath: input.model.path)
        if hasCloud { try fm.copyItem(at: input.pointCloud, to: folder.appendingPathComponent("pointcloud.ply")) }
        if hasPoses { try fm.copyItem(at: input.poses, to: folder.appendingPathComponent("poses.json")) }
        if hasModel { try fm.copyItem(at: input.model, to: folder.appendingPathComponent("model.usdz")) }

        let readme = readmeText(photos: input.imageFiles.count, depthMaps: depthCount,
                                cloud: hasCloud, poses: hasPoses, model: hasModel)
        try readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        // Zip the folder with the system's built-in zipper.
        let zip = work.appendingPathComponent(base + ".zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try fm.copyItem(at: zipped, to: zip) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        try? fm.removeItem(at: folder)
        return zip
    }

    // MARK: Depth

    private static func depthData(from image: URL) -> AVDepthData? {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { return nil }
        for type in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity] {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
               let depth = try? AVDepthData(fromDictionaryRepresentation: info) {
                return depth.depthDataType == kCVPixelFormatType_DepthFloat32
                    ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            }
        }
        return nil
    }

    /// 16-bit grayscale PNG, one value per pixel = distance from the camera in millimeters (0 = unknown).
    private static func writeDepthPNG(_ depth: AVDepthData, to url: URL) -> Bool {
        let buffer = depth.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let meters = row[x]
                if meters.isFinite, meters > 0 {
                    pixels[y * width + x] = UInt16(min(65535, (meters * 1000).rounded()))
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func calibration(of depth: AVDepthData) -> [String: Any] {
        let map = depth.depthDataMap
        var entry: [String: Any] = [
            "depth_width": CVPixelBufferGetWidth(map),
            "depth_height": CVPixelBufferGetHeight(map),
        ]
        if let cal = depth.cameraCalibrationData {
            let k = cal.intrinsicMatrix
            entry["intrinsics_fx_fy_cx_cy"] = [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y]
            entry["intrinsics_reference_size"] = [cal.intrinsicMatrixReferenceDimensions.width,
                                                  cal.intrinsicMatrixReferenceDimensions.height]
            entry["pixel_size_mm"] = cal.pixelSize
        }
        return entry
    }

    // MARK: README

    private static func readmeText(photos: Int, depthMaps: Int, cloud: Bool, poses: Bool, model: Bool) -> String {
        var lines = [
            "Object Scanner scan data",
            "========================",
            "",
            "Images/          \(photos) photos (HEIC). Each one also stores the LiDAR depth map and gravity",
            "                 direction inside it, which Apple's Object Capture on a Mac uses automatically.",
        ]
        lines.append(depthMaps > 0
            ? "Depth/           \(depthMaps) LiDAR depth maps, one per photo: 16-bit grayscale PNG, each pixel is the\n                 distance from the camera in millimeters (0 = unknown). intrinsics.json has\n                 the depth camera's focal length and center (fx, fy, cx, cy) for each one,\n                 scaled to intrinsics_reference_size; rescale to depth_width x depth_height."
            : "Depth/           (empty: these photos had no depth map stored)")
        lines.append(cloud
            ? "pointcloud.ply   Colored 3D point cloud from the reconstruction (meters, Y up). Open it in\n                 MeshLab, CloudCompare or Blender."
            : "pointcloud.ply   (not included: this phone couldn't make it)")
        lines.append(poses
            ? "poses.json       Camera position and rotation for each photo, in the same space as the point cloud."
            : "poses.json       (not included: this phone couldn't make it)")
        if model { lines.append("model.usdz       The model the phone built.") }
        lines += [
            "",
            "Building a better model on a computer",
            "-------------------------------------",
            "Mac: use an Object Capture app (for example PhotoCatch, or Apple's Object Capture sample app),",
            "     choose the Images folder and pick Full or Raw detail. It reads the depth and gravity from the photos.",
            "Windows: RealityScan (free, Epic Games) or Meshroom (free, open source) can build from the",
            "     Images folder. Convert HEIC to JPG first if the program can't open HEIC.",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
