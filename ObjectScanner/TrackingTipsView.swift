import SwiftUI

/// How to give the camera something to track: the printable scan mat and tape marks.
struct TrackingTipsView: View {
    var body: some View {
        List {
            Section {
                Text("The scanner keeps track of where the phone is by watching the things around the object. A plain table or floor gives it almost nothing to follow, so it can lose its place. Give it marks to follow, around the object (not on it).")
                    .font(.subheadline)
            }

            ScanMatSection()

            Section("Or use tape") {
                tip("scissors", "Stick 6–10 strips of masking or painter's tape on the surface around the object, pointing in different directions.")
                tip("pencil", "Draw on each strip with a thick marker: arrows, numbers, letters or scribbles. Make each strip different.")
                tip("circle.dashed", "Leave a little gap between the tape and the object so the tape doesn't get stuck to the model.")
                tip("sun.max", "Use matte tape. Shiny tape reflects light and confuses the camera.")
            }

            Section("While scanning") {
                tip("lock", "Don't move the mat or tape during a scan. To capture the bottom, flip the object and leave the mat where it is.")
                tip("tortoise", "Move slowly. If the hint says tracking was lost, point back at a spot you already scanned and hold still for a moment.")
                tip("lightbulb", "Bright, even light helps tracking as much as it helps the model.")
            }

            Section {
                Text("The marks only help tracking. The app cuts the object out of its surroundings when building the model, so the mat and tape don't end up in it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tracking tips")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

/// Makes the printable scan mat and opens the share sheet (Print, AirDrop, Save to Files).
struct ScanMatSection: View {
    @AppStorage(AppSettings.Key.matPaper) private var paper = ScanMat.Paper.letter.rawValue
    @AppStorage(AppSettings.Key.matPages) private var tiled = false
    @State private var shareItems: [Any] = []
    @State private var sharing = false
    @State private var error: String?

    var body: some View {
        Section {
            Picker("Paper", selection: $paper) {
                ForEach(ScanMat.Paper.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Size", selection: $tiled) {
                Text("1 page").tag(false)
                Text("4 pages (bigger objects)").tag(true)
            }
            Button {
                make()
            } label: {
                Label("Make scan mat (PDF)", systemImage: "printer")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Printable scan mat")
        } footer: {
            Text("Print it at 100% size, put it flat under the object, and place the object in the dashed circle. For 4 pages, tape them together edge to edge. Print, AirDrop or save it from the share sheet.")
        }
        .sheet(isPresented: $sharing) { ShareSheet(items: shareItems) }
    }

    private func make() {
        do {
            let url = try ScanMat.makePDF(paper: ScanMat.Paper(rawValue: paper) ?? .letter, tiled: tiled)
            error = nil
            shareItems = [url]
            sharing = true
        } catch {
            self.error = "Couldn't make the PDF: \(error.localizedDescription)"
        }
    }
}
