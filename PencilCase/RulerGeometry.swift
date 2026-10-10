import Foundation

struct RulerGeometry {
    static let height: CGFloat = 76
    static let cornerRadius: CGFloat = 13
    // Leave room for four-digit endpoint labels before the resize grips.
    static let inset: CGFloat = 40
    static let minimumLength: CGFloat = 100
    static let maximumLength: CGFloat = 2000

    var length: CGFloat = 400
    var angle: CGFloat = 0
    /// Counterclockwise is positive; clockwise is negative. Preserve the
    /// approach direction at the equivalent +180 and -180 endpoints.
    var displayedAngle: CGFloat { Self.signedAngle(angle) }
    var angleText: String {
        let rounded = (displayedAngle * 100).rounded() / 100
        let magnitude = Double(abs(rounded)).formatted(
            .number.grouping(.never).precision(.fractionLength(2)))
        let sign = rounded == 0 ? "" : (rounded < 0 ? "−" : "+")
        return sign + magnitude
    }

    static func signedAngle(_ angle: CGFloat) -> CGFloat {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        if remainder > 180 { return remainder - 360 }
        if remainder < -180 { return remainder + 360 }
        return remainder == 0 ? 0 : remainder
    }
    var width: CGFloat { length + Self.inset * 2 }
    var radians: CGFloat { angle * .pi / 180 }
    var axis: CGPoint { CGPoint(x: cos(radians), y: sin(radians)) }
    var enclosingSize: CGSize {
        CGSize(width: ceil(abs(cos(radians)) * width + abs(sin(radians)) * Self.height) + 48,
               height: ceil(abs(sin(radians)) * width + abs(cos(radians)) * Self.height) + 48)
    }

    static func normalizedAngle(_ angle: CGFloat, snapping: Bool) -> CGFloat {
        let value = snapping ? (angle / 45).rounded() * 45 : angle
        return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Coordinates are local to the rotated ruler; end padding is not measurable.
    func hoveredPoint(at location: CGPoint) -> CGFloat? {
        // Include the tick marks and their number labels, with a little space below.
        guard location.y >= 34, location.y <= Self.height,
              location.x >= Self.inset, location.x <= Self.inset + length else { return nil }
        return min(length, max(0, (location.x - Self.inset).rounded()))
    }

    /// Keep the opposite end fixed and retain one point per ruler division.
    func resized(delta: CGPoint, end: CGFloat) -> (geometry: Self, centerOffset: CGPoint) {
        let projected = delta.x * axis.x + delta.y * axis.y
        let newLength = min(Self.maximumLength, max(Self.minimumLength, (length + projected * end).rounded()))
        let shift = (newLength - length) * end / 2
        var result = self
        result.length = newLength
        return (result, CGPoint(x: axis.x * shift, y: axis.y * shift))
    }
}


/// Angular hysteresis prevents chatter. Raw pointer motion remains separate
/// from the attracted output so the user can always pull out of a snap.
struct RulerAngleSnap {
    static let captureDistance: CGFloat = 2
    static let releaseDistance: CGFloat = 3.5
    static let attractionDistance: CGFloat = 6
    private(set) var target: CGFloat?

    mutating func resolve(_ rawAngle: CGFloat, force: Bool) -> CGFloat {
        let nearest = (rawAngle / 45).rounded() * 45
        if force {
            target = nearest
            return nearest
        }
        if let target, abs(rawAngle - target) <= Self.releaseDistance {
            return target
        }
        target = nil
        let delta = rawAngle - nearest
        let distance = abs(delta)
        if distance <= Self.captureDistance {
            target = nearest
            return nearest
        }
        guard distance < Self.attractionDistance else { return rawAngle }
        // Ease into the exact angle spatially, without animation lag or overshoot.
        let t = (distance - Self.captureDistance) / (Self.attractionDistance - Self.captureDistance)
        let smooth = t * t * (3 - 2 * t)
        return nearest + delta * smooth
    }
}
