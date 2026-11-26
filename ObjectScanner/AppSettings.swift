import Foundation

/// How hard the phone works to build a model. Slower settings can give a better model.
enum BuildQuality: String, CaseIterable, Identifiable, Codable {
    case fast, detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .detailed: return "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Quickest build. iPhones build standard detail only; for more, use Export scan data and build on a computer."
        case .detailed:
            return "Looks harder for matching points between photos. Slower, but fewer holes on plain or smooth objects. Still standard phone detail."
        }
    }

    /// Look for more matching points between photos (slower, helps plain objects).
    var highFeatureSensitivity: Bool { self != .fast }
}

/// Settings kept between launches. SwiftUI views use @AppStorage with these same keys.
enum AppSettings {
    enum Key {
        static let photoRate = "photoRate"
        static let boostEnabled = "boostEnabled"
        static let buildQuality = "buildQuality"
        static let matPaper = "matPaper"
        static let matPages = "matPages"
    }

    /// 0 = fewest extra photos, 1 = most. 0.6 matches the app's original timing (about 4° / 0.4 s).
    static let defaultPhotoRate = 0.6

    static var photoRate: Double {
        get { UserDefaults.standard.object(forKey: Key.photoRate) as? Double ?? defaultPhotoRate }
        set { UserDefaults.standard.set(newValue, forKey: Key.photoRate) }
    }

    static var boostEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.boostEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.boostEnabled) }
    }

    static var buildQuality: BuildQuality {
        get { BuildQuality(rawValue: UserDefaults.standard.string(forKey: Key.buildQuality) ?? "") ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.buildQuality) }
    }

    // MARK: Photo rate → extra-photo timing

    /// Turn at least this many degrees between extra photos.
    static func boostDegrees(rate: Double) -> Double { 8 - 6.5 * clamp(rate) }
    /// Wait at least this long between extra photos.
    static func boostInterval(rate: Double) -> TimeInterval { 0.8 - 0.65 * clamp(rate) }

    static func rateDescription(_ rate: Double) -> String {
        String(format: "A photo every %.1f° of turn (at most %.0f a second)",
               boostDegrees(rate: rate), 1 / boostInterval(rate: rate))
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
