import Foundation

@main struct DrawingPreferencesTests {
    @MainActor static func main() {
        let suite = "PencilCase.DrawingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DrawingPreferences(defaults: defaults)
        precondition(prefs.automatic && prefs.seconds == 30)
        precondition(prefs.lifetime.nextUpdate(age: 5) == 25)
        precondition(prefs.lifetime.opacity(age: 30.25) == 0.5)
        precondition(!prefs.lifetime.expired(age: 30.49))
        precondition(prefs.lifetime.expired(age: 30.5))
        prefs.seconds = 120
        precondition(prefs.lifetime.opacity(age: 60) == 1)
        precondition(prefs.lifetime.nextUpdate(age: 60) == 60)
        prefs.automatic = false
        precondition(prefs.lifetime.opacity(age: 100000) == 1)
        precondition(!prefs.lifetime.expired(age: 100000))
        precondition(prefs.lifetime.nextUpdate(age: 100000) == nil)
        let restored = DrawingPreferences(defaults: defaults)
        precondition(!restored.automatic && restored.seconds == 120)
        restored.automatic = true
        precondition(restored.lifetime.expired(age: 121))
        precondition(InkLifetime(seconds: -1).seconds == 1)
        precondition(InkLifetime(seconds: .infinity).seconds == 30)
        precondition(InkLifetime(seconds: 10000).seconds == 3600)
        print("PASS: drawing lifetime defaults, fade timing, disabled expiry, persistence, re-enable and limits.")
    }
}
