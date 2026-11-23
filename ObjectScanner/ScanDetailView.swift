import SwiftUI

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var reconstructor: Reconstructor
    let scanID: UUID

    @State private var viewing = false
    @State private var shareItems: [Any] = []
    @State private var sharing = false
    @State private var confirmDeletePhotos = false
    @State private var sizeText = ""

    private var scan: Scan? { store.scan(scanID) }
    private var isBuildingThis: Bool { reconstructor.activeScanID == scanID }

    var body: some View {
        if let scan {
            List {
                Section {
                    HStack(spacing: 14) {
                        ScanThumbnail(url: store.firstImageURL(for: scanID))
                            .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(scan.status.title, systemImage: scan.status.symbol)
                                .font(.headline)
                                .foregroundStyle(scan.status.color)
                            Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Photos", value: "\(scan.imageCount)")
                    LabeledContent("Passes", value: "\(scan.passes)\(scan.flipped ? " (incl. flipped)" : "")")
                    LabeledContent("Storage used", value: sizeText.isEmpty ? "…" : sizeText)
                }

                if let error = scan.errorMessage, !isBuildingThis {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                if isBuildingThis {
                    buildingSection
                }

                modelSection(scan)
                photosSection(scan)
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(scan.status.rawValue)-\(scan.imageCount)") { refreshSize() }
            .fullScreenCover(isPresented: $viewing) {
                ModelViewer(url: store.modelURL(for: scanID), title: scan.name)
            }
            .sheet(isPresented: $sharing) { ShareSheet(items: shareItems) }
            .confirmationDialog("Delete the photos?", isPresented: $confirmDeletePhotos, titleVisibility: .visible) {
                Button("Delete photos", role: .destructive) { store.deletePhotos(for: scanID) }
            } message: {
                Text("This frees up space. The 3D model is kept, but you won't be able to rebuild it.")
            }
        } else {
            ContentUnavailableView("Scan not found", systemImage: "questionmark.folder")
        }
    }

    // MARK: Sections

    private var buildingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(reconstructor.stage).font(.subheadline.weight(.semibold))
                ProgressView(value: reconstructor.fraction)
                HStack {
                    Text("\(Int(reconstructor.fraction * 100))%")
                    Spacer()
                    if let seconds = reconstructor.secondsRemaining, seconds > 0 {
                        Text("About \(formatDuration(seconds)) left")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button("Cancel build", role: .destructive) { reconstructor.cancel() }
        } header: {
            Text("Building 3D model")
        } footer: {
            Text("Keep the app open and the phone unlocked until this finishes. It usually takes a few minutes.")
        }
    }

    @ViewBuilder
    private func modelSection(_ scan: Scan) -> some View {
        let hasModel = store.hasModel(scanID)
        let hasPhotos = scan.imageCount > 0
        Section("3D model") {
            if hasModel {
                Button { viewing = true } label: {
                    Label("View in 3D / AR", systemImage: "arkit")
                }
                Button { share() } label: {
                    Label("Share model (.usdz)", systemImage: "square.and.arrow.up")
                }
            }
            if hasPhotos && !isBuildingThis {
                Button { reconstructor.build(scanID, store: store) } label: {
                    Label(hasModel ? "Rebuild model" : (scan.status == .failed || scan.errorMessage != nil ? "Try building again" : "Build 3D model"),
                          systemImage: "cube.transparent")
                }
                .disabled(reconstructor.isRunning)
                if reconstructor.isRunning {
                    Text("Another scan is being built. Wait for it to finish.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !hasModel && !hasPhotos {
                Text("No photos or model. Delete this scan and try again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func photosSection(_ scan: Scan) -> some View {
        if scan.imageCount > 0 && store.hasModel(scanID) && !isBuildingThis {
            Section {
                Button("Delete photos to free space", role: .destructive) { confirmDeletePhotos = true }
            }
        }
    }

    // MARK: Actions

    private func share() {
        guard let url = store.shareableModelURL(for: scanID) else { return }
        shareItems = [url]
        sharing = true
    }

    private func refreshSize() {
        let bytes = store.diskSize(for: scanID)
        sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "\(Int(seconds)) s"
    }
}
