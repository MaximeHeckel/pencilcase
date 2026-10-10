import Foundation
import Combine

nonisolated struct InkLifetime {
    let automatic: Bool
    let seconds: TimeInterval
    static let fadeDuration = 0.5

    init(automatic: Bool = true, seconds: TimeInterval = 30) {
        self.automatic = automatic
        self.seconds = seconds.isFinite ? min(3600, max(1, seconds)) : 30
    }

    func opacity(age: TimeInterval) -> Double {
        automatic ? max(0, min(1, (seconds + Self.fadeDuration - age) / Self.fadeDuration)) : 1
    }

    func expired(age: TimeInterval) -> Bool { automatic && age >= seconds + Self.fadeDuration }
    func nextUpdate(age: TimeInterval) -> TimeInterval? {
        guard automatic else { return nil }
        return age < seconds ? seconds - age : 1 / 30.0
    }
}

@MainActor
final class DrawingPreferences: ObservableObject {
    static let shared = DrawingPreferences()
    private let defaults: UserDefaults
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "inkAutomaticallyDisappears") } }
    @Published var seconds: Int { didSet { defaults.set(seconds, forKey: "inkLifetimeSeconds") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automatic = defaults.object(forKey: "inkAutomaticallyDisappears") as? Bool ?? true
        seconds = Int(InkLifetime(seconds: defaults.object(forKey: "inkLifetimeSeconds") as? Double ?? 30).seconds)
    }

    var lifetime: InkLifetime { InkLifetime(automatic: automatic, seconds: Double(seconds)) }
}
