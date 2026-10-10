import AppKit

/// Shared native material for the ruler and loupe rail.
@MainActor
enum InstrumentGlass {
    static let acrylicOverlayOpacity: CGFloat = 0.24

    static func configure(_ glass: NSGlassEffectView, cornerRadius: CGFloat) {
        glass.style = .clear
        glass.appearance = NSAppearance(named: .aqua)
        glass.tintColor = nil
        glass.cornerRadius = cornerRadius
    }
}
