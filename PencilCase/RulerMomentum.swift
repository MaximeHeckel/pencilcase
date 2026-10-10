import Foundation
import CoreGraphics

/// Point-space motion, independent of rendering and display scale.
struct RulerMomentum {
    var velocity: CGPoint

    mutating func step(origin: CGPoint, size: CGSize, limits: CGRect, dt: Double) -> CGPoint {
        let friction = 3.75
        let damping = exp(-friction * dt)
        let travel = (1 - damping) / friction
        var result = CGPoint(x: origin.x + velocity.x * travel,
                             y: origin.y + velocity.y * travel)
        velocity.x *= damping
        velocity.y *= damping

        var collided = false

        func confine(_ position: inout CGFloat, _ speed: inout CGFloat,
                     lower: CGFloat, upper: CGFloat, length: CGFloat) {
            guard upper - lower >= length else {
                position = (lower + upper - length) / 2
                speed = 0
                return
            }
            if position < lower {
                position = lower
                speed = abs(speed)
                collided = true
            } else if position > upper - length {
                position = upper - length
                speed = -abs(speed)
                collided = true
            }
        }

        confine(&result.x, &velocity.x, lower: limits.minX, upper: limits.maxX, length: size.width)
        confine(&result.y, &velocity.y, lower: limits.minY, upper: limits.maxY, length: size.height)
        // Reflect the normal, then damp the whole vector once (also at corners).
        // Damping only the normal changes the angle into an edge-skimming slide.
        if collided {
            velocity.x *= 0.22
            velocity.y *= 0.22
        }
        return result
    }

    var isStopped: Bool { hypot(velocity.x, velocity.y) < 18 }
}
