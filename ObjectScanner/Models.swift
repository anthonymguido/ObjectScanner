import Foundation
import SwiftUI

/// How a scan was made. Phase 2 adds a live LiDAR mesh mode.
enum ScanKind: String, Codable {
    case objectCapture
}

enum ScanStatus: String, Codable {
    case capturing      // the camera is still open (or the app quit mid-capture)
    case captured       // photos saved, no model yet
    case processing     // building the 3D model
    case ready          // model.usdz exists
    case failed

    var title: String {
        switch self {
        case .capturing: return "Capturing"
        case .captured: return "Photos ready"
        case .processing: return "Building model…"
        case .ready: return "Model ready"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .capturing, .processing: return .orange
        case .captured: return .blue
        case .ready: return .green
        case .failed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .capturing: return "camera.viewfinder"
        case .captured: return "photo.stack"
        case .processing: return "gearshape.2"
        case .ready: return "cube.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

struct Scan: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var kind: ScanKind = .objectCapture
    var status: ScanStatus = .capturing
    var imageCount = 0
    var passes = 0
    var flipped = false
    var errorMessage: String?

    init(name: String) {
        self.name = name
    }

    // Tolerant decoding, so fields added later don't wipe older saves.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled scan"
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        kind = (try? c.decodeIfPresent(ScanKind.self, forKey: .kind)) ?? .objectCapture
        status = (try? c.decodeIfPresent(ScanStatus.self, forKey: .status)) ?? .captured
        imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 0
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
