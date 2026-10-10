import Foundation
import CoreGraphics

/// Unit-mass rigid rectangle sliding on the desktop. Angles are radians.
struct InstrumentMomentum {
    var center: CGPoint
    var angle: CGFloat
    var velocity: CGPoint
    var angularVelocity: CGFloat
    let size: CGSize
    let surface: RulerMomentum.Surface

    private var inertia: CGFloat { (size.width * size.width + size.height * size.height) / 12 }

    init(center: CGPoint, angle: CGFloat, velocity: CGPoint, grabOffset: CGPoint,
         size: CGSize, surface: RulerMomentum.Surface) {
        self.center = center
        self.angle = angle
        self.velocity = velocity
        self.size = size
        self.surface = surface
        let moment = grabOffset.x * velocity.y - grabOffset.y * velocity.x
        angularVelocity = max(-3, min(3, 0.18 * moment / ((size.width * size.width + size.height * size.height) / 12)))
    }

    var isStopped: Bool { velocity == .zero && angularVelocity == 0 }

    mutating func step(limits: CGRect, dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        var remaining = min(dt, 0.1)
        while remaining > 0.000001 {
            let h = CGFloat(min(remaining, 1 / 240.0))
            remaining -= Double(h)
            let speed = hypot(velocity.x, velocity.y)
            if speed > 0 {
                let time = min(h, log1p(speed * surface.drag / surface.friction) / surface.drag)
                let decay = exp(-surface.drag * time)
                let travel = (speed + surface.friction / surface.drag) * (1 - decay) / surface.drag - surface.friction * time / surface.drag
                center.x += velocity.x / speed * travel
                center.y += velocity.y / speed * travel
                let next = max(0, (speed + surface.friction / surface.drag) * decay - surface.friction / surface.drag)
                velocity.x *= next / speed
                velocity.y *= next / speed
            }

            let spin = abs(angularVelocity)
            if spin > 0 {
                let drag: CGFloat = 1.8
                let friction: CGFloat = 1.6
                let time = min(h, log1p(spin * drag / friction) / drag)
                let decay = exp(-drag * time)
                let sign: CGFloat = angularVelocity < 0 ? -1 : 1
                angle += sign * ((spin + friction / drag) * (1 - decay) / drag - friction * time / drag)
                angularVelocity = sign * max(0, (spin + friction / drag) * decay - friction / drag)
            }
            angle = atan2(sin(angle), cos(angle))
            // Resolve both walls at desktop corners, including rotational contact velocity.
            for _ in 0..<3 { resolveContacts(limits: limits) }
            if hypot(velocity.x, velocity.y) < 2 { velocity = .zero }
            if abs(angularVelocity) < 0.005 { angularVelocity = 0 }
        }
    }

    private mutating func resolveContacts(limits: CGRect) {
        let c = cos(angle), s = sin(angle)
        let offsets = [-1.0, 1.0].flatMap { x in
            [-1.0, 1.0].map { y in
                let px = CGFloat(x) * size.width / 2, py = CGFloat(y) * size.height / 2
                return CGPoint(x: px * c - py * s, y: px * s + py * c)
            }
        }
        let extentX = offsets.map { abs($0.x) }.max()!
        let extentY = offsets.map { abs($0.y) }.max()!
        if extentX * 2 > limits.width {
            center.x = limits.midX
            velocity.x = 0
            angularVelocity = 0
        }
        if extentY * 2 > limits.height {
            center.y = limits.midY
            velocity.y = 0
            angularVelocity = 0
        }
        let walls: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 1, y: 0), limits.minX - (center.x - extentX)),
            (CGPoint(x: -1, y: 0), center.x + extentX - limits.maxX),
            (CGPoint(x: 0, y: 1), limits.minY - (center.y - extentY)),
            (CGPoint(x: 0, y: -1), center.y + extentY - limits.maxY)
        ]
        for (normal, penetration) in walls where penetration > 0 {
            if normal.x != 0 && extentX * 2 > limits.width { continue }
            if normal.y != 0 && extentY * 2 > limits.height { continue }
            center.x += normal.x * penetration
            center.y += normal.y * penetration
            let minimum = offsets.map { $0.x * normal.x + $0.y * normal.y }.min()!
            let contacts = offsets.filter { $0.x * normal.x + $0.y * normal.y < minimum + 0.5 }
            // Average a face's two corners so a centered, square-on hit adds no spin.
            let r = CGPoint(x: contacts.reduce(0) { $0 + $1.x } / CGFloat(contacts.count),
                            y: contacts.reduce(0) { $0 + $1.y } / CGFloat(contacts.count))
            let contactVelocity = CGPoint(x: velocity.x - angularVelocity * r.y,
                                          y: velocity.y + angularVelocity * r.x)
            let vn = contactVelocity.x * normal.x + contactVelocity.y * normal.y
            guard vn < 0 else { continue }
            let lever = r.x * normal.y - r.y * normal.x
            let restitution = -vn < 80 ? 0 : surface.restitution
            let impulse = -(1 + restitution) * vn / (1 + lever * lever / inertia)
            velocity.x += normal.x * impulse
            velocity.y += normal.y * impulse
            angularVelocity += lever * impulse / inertia

            let tangent = CGPoint(x: -normal.y, y: normal.x)
            let tangentLever = r.x * tangent.y - r.y * tangent.x
            let vt = (velocity.x - angularVelocity * r.y) * tangent.x + (velocity.y + angularVelocity * r.x) * tangent.y
            let friction = max(-0.2 * impulse, min(0.2 * impulse, -vt / (1 + tangentLever * tangentLever / inertia)))
            velocity.x += tangent.x * friction
            velocity.y += tangent.y * friction
            angularVelocity += tangentLever * friction / inertia
            angularVelocity = max(-6, min(6, angularVelocity))
        }
    }
}
