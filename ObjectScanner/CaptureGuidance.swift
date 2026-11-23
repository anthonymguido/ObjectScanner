import SwiftUI

/// Every on-screen guidance string in one place, so the wording is easy to change.
enum GuidanceText {

    // MARK: Step banner (what to do now)

    static let starting = "Starting the camera…"
    static let ready = "Put the object on a plain table with space to walk around it. Point the camera at it, then tap Continue."
    static let readyAfterFlip = "Object flipped. Point the camera at it again, then tap Continue."
    static let detecting = "A box appears around the object. Drag its edges so it fits snugly, then tap Start capture."
    static let finishing = "Saving photos… keep the app open."
    static let completed = "Capture complete."

    static func capturing(pass: Int) -> String {
        switch pass {
        case 1: return "Walk slowly all the way around the object, keeping it in the middle of the screen."
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
    let pass: Int
    let completedPasses: Int
    let flipped: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(maxShots > 0 ? "\(shots) / \(maxShots) photos" : "\(shots) photos", systemImage: "camera")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("state: \(phase)")
            Text("feedback: \(feedback.isEmpty ? "none" : feedback.joined(separator: ", "))")
            Text("shots: \(shots)/\(maxShots)  pass: \(pass)  done passes: \(completedPasses)")
            Text("passComplete: \(passCompleted ? "yes" : "no")  flipped: \(flipped ? "yes" : "no")")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}
