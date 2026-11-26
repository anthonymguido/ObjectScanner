import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.boostEnabled) private var boostEnabled = true
    @AppStorage(AppSettings.Key.photoRate) private var photoRate = AppSettings.defaultPhotoRate
    @AppStorage(AppSettings.Key.buildQuality) private var quality = BuildQuality.fast

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Extra photos", isOn: $boostEnabled)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Photo rate")
                            Spacer()
                            Button("Reset") { photoRate = AppSettings.defaultPhotoRate }
                                .font(.footnote)
                                .buttonStyle(.borderless)
                        }
                        HStack {
                            Text("Fewer").font(.caption)
                            Slider(value: $photoRate, in: 0...1)
                            Text("More").font(.caption)
                        }
                        Text(AppSettings.rateDescription(photoRate))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .disabled(!boostEnabled)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Extra photos are taken as you walk around, on top of Apple's automatic ones. More photos can give a more complete model, but each scan has a photo limit, so very high rates can use it up before you finish. You can also change this on the capture screen.")
                }

                Section {
                    Picker("Default quality", selection: $quality) {
                        ForEach(BuildQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Text(quality.summary)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Building models")
                } footer: {
                    Text("You can also pick the quality on each scan's page before building. For the most detail, use Export scan data on a scan's page and build it on a computer.")
                }

                Section("Tracking") {
                    NavigationLink {
                        TrackingTipsView()
                    } label: {
                        Label("Tracking tips", systemImage: "scope")
                    }
                }

                ScanMatSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
