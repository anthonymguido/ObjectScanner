import SwiftUI

/// Every on-screen guidance string in one place, so the wording is easy to change.
enum GuidanceText {

    // MARK: Step banner (what to do now)

    static let starting = "Starting the camera…"
    static let ready = "Point the camera at the object. The scan box should appear by itself. If it doesn't, tap Continue."
    static let readyAfterFlip = "Object flipped. Point the camera at it again. The box should appear by itself."
    static let handoff = "Object found ✓ Starting scan…"

    // MARK: Find-object step (border tracing + LiDAR)

    static func finder(found: Bool, instances: Int, centered: Bool, tracking: Bool,
                       distance: Float?, sizeCM: CGSize?, ready: Bool) -> String {
        if ready { return handoff }
        if !tracking { return "Move the phone slowly so it can get its bearings." }
        if !found {
            return instances == 0
                ? "Point the camera at the object. Put it on a plain surface with space around it."
                : "Tap the object you want to scan."
        }
        if let d = distance {
            if d > ObjectFinder.distanceRange.upperBound { return String(format: "Move closer (%.1f m away).", d) }
            if d < ObjectFinder.distanceRange.lowerBound { return String(format: "Step back a little (%.0f cm away).", d * 100) }
        } else {
            return "Measuring distance… keep the object in view."
        }
        if let s = sizeCM {
            let longest = max(s.width, s.height)
            if longest < ObjectFinder.minSizeCM {
                return String(format: "Object looks very small (%.0f cm). Objects under %.0f cm scan poorly. Move closer.", longest, ObjectFinder.minSizeCM)
            }
            if longest > ObjectFinder.maxSizeCM {
                return String(format: "Object looks very large (%.0f cm). Step back or pick something smaller.", longest)
            }
        }
        if !centered { return "Center the object on the screen." }
        return "Hold still…"
    }
    static let detecting = "A box appears around the object. Drag its edges so it fits snugly, then tap Start capture."
    static let finishing = "Saving photos… keep the app open."
    static let completed = "Capture complete."

    static func capturing(pass: Int) -> String {
        switch pass {
        case 1: return "Walk slowly all the way around the object (about one step a second), keeping it in the middle of the screen."
        case 2: return "Pass 2: go around again with the phone lower, looking slightly up at the object."
        default: return "Pass \(pass): go around once more from a different height."
        }
    }

    static func passDone(_ completed: Int, flipped: Bool) -> String {
        if completed >= 3 || (completed >= 2 && flipped) {
            return "Great coverage. Tap Done to save, or do one more pass."
        }
        return "Pass \(completed) done. Go around again from a different height, flip the object to capture its bottom, or tap Done."
    }

    static func failed(_ message: String) -> String {
        "Capture stopped: \(message)"
    }

    // MARK: Live hints (from the session's feedback)

    struct Hint: Equatable {
        let text: String
        let isWarning: Bool
    }

    static let lookingGood = Hint(text: "Looking good. Keep going", isWarning: false)

    /// Feedback names as the session reports them, highest priority first.
    /// Names are matched as text so a feedback type missing on some iOS version can't break the build.
    static let feedbackHints: [(name: String, text: String)] = [
        ("environmentTooDark", "Too dark. Turn on more lights."),
        ("outOfFieldOfView", "Object out of view. Point the camera back at it."),
        ("objectNotDetected", "Can't find the object. Point the camera at it."),
        ("movingTooFast", "Slow down. Move the phone more slowly."),
        ("objectTooClose", "Too close. Step back a little."),
        ("objectTooFar", "Too far. Move closer."),
        ("environmentLowLight", "Light is low. More light gives a better model."),
        ("objectNotFlippable", "This object may not scan well if flipped. Do another pass instead."),
        ("overCapturing", "Enough photos here. Move to a side you haven't covered."),
    ]

    /// The most important hint for the current feedback, or nil if there's nothing to warn about.
    static func topHint(for feedbackNames: [String]) -> Hint? {
        for entry in feedbackHints where feedbackNames.contains(entry.name) {
            return Hint(text: entry.text, isWarning: true)
        }
        return nil
    }
}

// MARK: - Overlay pieces

/// Glowing border around the object the finder picked. Fills the screen the same way the camera feed does.
struct FinderOutline: View {
    let outline: CGImage?
    let ready: Bool

    var body: some View {
        if let outline {
            Image(decorative: outline, scale: 1)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .colorMultiply(ready ? .green : .white)
                .shadow(color: ready ? .green : .cyan, radius: 8)
                .shadow(color: ready ? .green : .cyan, radius: 3)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.15), value: ready)
        }
    }
}

/// Distance and size readout under the banner while finding the object.
struct FinderReadout: View {
    let distance: Float?
    let sizeCM: CGSize?

    var body: some View {
        HStack(spacing: 12) {
            if let distance { Label(String(format: "%.2f m", distance), systemImage: "ruler") }
            if let sizeCM { Label(String(format: "%.0f × %.0f cm", sizeCM.width, sizeCM.height), systemImage: "cube") }
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

/// The "what to do now" instruction across the top of the capture screen.
struct StepBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .animation(.easeInOut(duration: 0.2), value: text)
    }
}

/// A short live hint: amber for a problem, green when everything's fine.
struct HintPill: View {
    let hint: GuidanceText.Hint

    var body: some View {
        Label(hint.text, systemImage: hint.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(hint.isWarning ? .black : .white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hint.isWarning ? Color.yellow : Color.green.opacity(0.85), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .id(hint.text)
    }
}

/// Shot count, pass number and the suggested pass checklist.
struct CaptureProgressLine: View {
    let shots: Int
    let maxShots: Int
    let extra: Int
    let pass: Int
    let completedPasses: Int
    let flipped: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label((maxShots > 0 ? "\(shots) / \(maxShots) photos" : "\(shots) photos") + (extra > 0 ? " (\(extra) extra)" : ""),
                      systemImage: "camera")
                Spacer()
                Text("Pass \(pass) of 3 suggested")
            }
            .font(.footnote.monospacedDigit())

            HStack(spacing: 14) {
                check("Pass 1", done: completedPasses >= 1)
                check("Pass 2", done: completedPasses >= 2)
                check("Flipped", done: flipped)
            }
            .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func check(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? .green : .white.opacity(0.8))
    }
}

/// Raw session state for testing; switched on with the ladybug button.
struct CaptureDebugPanel: View {
    let phase: String
    let feedback: [String]
    let shots: Int
    let maxShots: Int
    let pass: Int
    let completedPasses: Int
    let passCompleted: Bool
    let flipped: Bool
    var extraLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("state: \(phase)")
            Text("feedback: \(feedback.isEmpty ? "none" : feedback.joined(separator: ", "))")
            Text("shots: \(shots)/\(maxShots)  pass: \(pass)  done passes: \(completedPasses)")
            Text("passComplete: \(passCompleted ? "yes" : "no")  flipped: \(flipped ? "yes" : "no")")
            ForEach(extraLines, id: \.self) { Text($0) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}
