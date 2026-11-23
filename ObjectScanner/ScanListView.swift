import SwiftUI

struct ScanListView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var reconstructor: Reconstructor

    @State private var path: [UUID] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var capturing: CaptureTarget?

    private struct CaptureTarget: Identifiable { let id: UUID }

    private var canCapture: Bool { DeviceSupport.canCapture }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    List {
                        if !canCapture {
                            Section { unsupportedNote }
                        }
                        ForEach(store.scans) { scan in
                            NavigationLink(value: scan.id) { ScanRow(scan: scan) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Object Scanner")
            .navigationDestination(for: UUID.self) { ScanDetailView(scanID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNaming() } label: { Image(systemName: "plus") }
                        .disabled(!canCapture)
                        .accessibilityLabel("New scan")
                }
            }
            .alert("New scan", isPresented: $naming) {
                TextField("e.g. Coffee mug", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Start") {
                    let scan = store.create(name: newName)
                    capturing = CaptureTarget(id: scan.id)
                }
            } message: {
                Text("Name the object you're about to scan.")
            }
            .fullScreenCover(item: $capturing) { target in
                CaptureView(scanID: target.id) { id in
                    // Open the new scan once the camera screen has gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { path.append(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "cube.transparent")
        } description: {
            Text(canCapture
                 ? "Walk around an object with your phone. The LiDAR scanner and camera capture it, then the app builds a 3D model you can view in AR or share."
                 : "This device can't scan objects. It needs iOS 17 or later and a LiDAR scanner (iPhone 12 Pro or a later Pro model, or a recent iPad Pro).")
        } actions: {
            if canCapture {
                Button("New scan") { startNaming() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var unsupportedNote: some View {
        Label("This device has no LiDAR scanner, so it can't make new scans. You can still view and share existing models.",
              systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func startNaming() {
        newName = ""
        naming = true
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets where store.scans[i].id == reconstructor.activeScanID {
            reconstructor.cancel()
        }
        store.delete(at: offsets)
    }
}

struct ScanRow: View {
    @EnvironmentObject private var store: ScanStore
    let scan: Scan

    var body: some View {
        HStack(spacing: 12) {
            ScanThumbnail(url: store.firstImageURL(for: scan.id))
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(scan.name).font(.headline)
                Label(scan.status.title, systemImage: scan.status.symbol)
                    .font(.subheadline)
                    .foregroundStyle(scan.status.color)
                Text("\(scan.date.formatted(date: .abbreviated, time: .shortened)) · \(scan.imageCount) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small preview made from the scan's first photo.
struct ScanThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "cube.transparent").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160))
            }.value
        }
    }
}
