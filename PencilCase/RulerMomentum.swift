import Foundation
import CoreGraphics

/// Tabletop sliding in logical points. No rendering or window allocation here.
struct RulerMomentum {
    struct Surface {
        let friction: CGFloat
        let drag: CGFloat
        let restitution: CGFloat
        let tangentialRetention: CGFloat

        static let ruler = Surface(friction: 900, drag: 1.3, restitution: 0.24, tangentialRetention: 0.78)
        static let marker = Surface(friction: 600, drag: 0.9, restitution: 0.36, tangentialRetention: 0.86)
    }

    var velocity: CGPoint
    var surface: Surface = .ruler

    /// Fit recent pointer motion instead of relying on two potentially noisy events.
    /// A pause before release means placement, not a throw.
    static func releaseVelocity(samples: [(point: CGPoint, time: TimeInterval)], now: TimeInterval) -> CGPoint? {
        let recent = samples.filter { now - $0.time >= 0 && now - $0.time <= 0.09 }
        guard let first = recent.first, let last = recent.last,
              last.time - first.time >= 0.012, now - last.time < 0.07 else { return nil }

        var weightSum: CGFloat = 0
        var meanTime: CGFloat = 0
        var meanPoint = CGPoint.zero
        for sample in recent {
            let weight = CGFloat(exp((sample.time - now) / 0.035))
            let time = CGFloat(sample.time - now)
            weightSum += weight
            meanTime += time * weight
            meanPoint.x += sample.point.x * weight
            meanPoint.y += sample.point.y * weight
        }
        meanTime /= weightSum
        meanPoint.x /= weightSum
        meanPoint.y /= weightSum

        var variance: CGFloat = 0
        var covariance = CGPoint.zero
        for sample in recent {
            let weight = CGFloat(exp((sample.time - now) / 0.035))
            let time = CGFloat(sample.time - now) - meanTime
            variance += weight * time * time
            covariance.x += weight * time * (sample.point.x - meanPoint.x)
            covariance.y += weight * time * (sample.point.y - meanPoint.y)
        }
        guard variance > 0.000001 else { return nil }

        let freshness = CGFloat(exp(-max(0, now - last.time - 0.012) / 0.025))
        var result = CGPoint(x: covariance.x / variance * freshness,
                             y: covariance.y / variance * freshness)
        let speed = hypot(result.x, result.y)
        guard speed > 180 else { return nil }

        let scale = min(1, 2800 / speed)
        result.x *= scale
        result.y *= scale
        return result
    }

    mutating func step(origin: CGPoint, size: CGSize, limits: CGRect, dt: Double) -> CGPoint {
        guard dt.isFinite, dt > 0 else { return origin }
        var position = origin
        var remaining = min(dt, 0.1)

        // Small bounded steps make edge contacts consistent across timer rates.
        while remaining > 0.000001 {
            let interval = min(remaining, 1.0 / 240)
            remaining -= interval
            let speed = hypot(velocity.x, velocity.y)
            if speed > 0 {
                // Integrate dv/dt = -friction - drag*v exactly, up to rest.
                let stopTime = log1p(speed * surface.drag / surface.friction) / surface.drag
                let time = min(CGFloat(interval), stopTime)
                let decay = exp(-surface.drag * time)
                let travel = (speed + surface.friction / surface.drag) * (1 - decay) / surface.drag
                    - surface.friction * time / surface.drag
                position.x += velocity.x / speed * travel
                position.y += velocity.y / speed * travel

                let nextSpeed = max(0, (speed + surface.friction / surface.drag) * decay - surface.friction / surface.drag)
                velocity.x *= nextSpeed / speed
                velocity.y *= nextSpeed / speed
            }

            let restitution = surface.restitution
            func confine(_ point: inout CGFloat, _ normal: inout CGFloat,
                         lower: CGFloat, upper: CGFloat, length: CGFloat) -> Bool {
                guard upper - lower >= length else {
                    point = (lower + upper - length) / 2
                    normal = 0
                    return false
                }
                let hitLow = point < lower
                let hitHigh = point > upper - length
                guard hitLow || hitHigh else { return false }
                point = min(upper - length, max(lower, point))

                // Don't bounce an object already moving away from the edge.
                guard (hitLow && normal < 0) || (hitHigh && normal > 0) else { return false }
                let impact = abs(normal)
                let rebound = impact < 80 ? 0 : impact * restitution
                normal = hitLow ? rebound : -rebound
                return true
            }

            let hitX = confine(&position.x, &velocity.x, lower: limits.minX, upper: limits.maxX, length: size.width)
            let hitY = confine(&position.y, &velocity.y, lower: limits.minY, upper: limits.maxY, length: size.height)
            if hitX && !hitY { velocity.y *= surface.tangentialRetention }
            if hitY && !hitX { velocity.x *= surface.tangentialRetention }
            if hypot(velocity.x, velocity.y) < 2 { velocity = .zero }
        }
        return position
    }

    var isStopped: Bool { velocity == .zero }
}
