import SwiftUI
import RealityKit

@main
struct ObjectScannerApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var reconstructor = Reconstructor()

    var body: some Scene {
        WindowGroup {
            ScanListView()
                .environmentObject(store)
                .environmentObject(reconstructor)
        }
    }
}

enum DeviceSupport {
    /// Object Capture needs iOS 17+ and a LiDAR scanner (iPhone 12 Pro or later Pro models, recent iPad Pro).
    @MainActor static var canCapture: Bool { ObjectCaptureSession.isSupported }
}
