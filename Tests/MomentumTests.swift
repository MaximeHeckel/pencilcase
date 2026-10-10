import Foundation

@main
struct MomentumTests {
    static func main() {
        let desktop = CGRect(x: 0, y: 0, width: 1400, height: 900)
        func body(_ grab: CGPoint = .zero, center: CGPoint = CGPoint(x: 700, y: 450), angle: CGFloat = 0,
                  velocity: CGPoint = CGPoint(x: 800, y: 600)) -> InstrumentMomentum {
            InstrumentMomentum(center: center, angle: angle, velocity: velocity, grabOffset: grab,
                               size: CGSize(width: 400, height: 76), surface: .ruler)
        }
        precondition(body().angularVelocity == 0)
        let left = body(CGPoint(x: -150, y: 0)), right = body(CGPoint(x: 150, y: 0))
        precondition(left.angularVelocity < 0 && right.angularVelocity > 0)
        precondition(abs(left.angularVelocity + right.angularVelocity) < 0.0001)
        var straight = body()
        straight.step(limits: desktop, dt: 0.05)
        precondition(straight.angle == 0)
        precondition(abs((straight.center.y - 450) / (straight.center.x - 700) - 0.75) < 0.00001)
        var face = body(center: CGPoint(x: 1199, y: 450), velocity: CGPoint(x: 1000, y: 0))
        face.step(limits: desktop, dt: 1 / 60)
        precondition(abs(face.angularVelocity) < 0.0001 && face.velocity.x <= 0)
        var corner = body(center: CGPoint(x: 1200, y: 450), angle: 0.3, velocity: CGPoint(x: 1000, y: 0))
        corner.step(limits: desktop, dt: 1 / 60)
        precondition(abs(corner.angularVelocity) > 0.1)

        var a = right, b = right
        for _ in 0..<60 { a.step(limits: desktop, dt: 1 / 60) }
        for _ in 0..<120 { b.step(limits: desktop, dt: 1 / 120) }
        precondition(hypot(a.center.x - b.center.x, a.center.y - b.center.y) < 0.001)
        precondition(abs(a.angle - b.angle) < 0.001)

        for index in 0..<100 {
            let angle = CGFloat(index) * 0.17
            let size = index % 2 == 0 ? CGSize(width: 480, height: 76) : CGSize(width: 32, height: 186)
            var moving = InstrumentMomentum(center: CGPoint(x: 700, y: 450), angle: angle,
                velocity: CGPoint(x: cos(angle) * 2800, y: sin(angle) * 2800),
                grabOffset: CGPoint(x: 90, y: -60), size: size, surface: index % 2 == 0 ? .ruler : .marker)
            var energy = moving.velocity.x * moving.velocity.x + moving.velocity.y * moving.velocity.y
                + (size.width * size.width + size.height * size.height) / 12 * moving.angularVelocity * moving.angularVelocity
            for _ in 0..<960 {
                moving.step(limits: desktop, dt: 1 / 240)
                precondition(moving.center.x.isFinite && moving.center.y.isFinite && moving.angle.isFinite)
                let x = abs(cos(moving.angle)) * size.width / 2 + abs(sin(moving.angle)) * size.height / 2
                let y = abs(sin(moving.angle)) * size.width / 2 + abs(cos(moving.angle)) * size.height / 2
                precondition(moving.center.x >= x - 0.001 && moving.center.x <= desktop.width - x + 0.001)
                precondition(moving.center.y >= y - 0.001 && moving.center.y <= desktop.height - y + 0.001)
                let nextEnergy = moving.velocity.x * moving.velocity.x + moving.velocity.y * moving.velocity.y
                    + (size.width * size.width + size.height * size.height) / 12 * moving.angularVelocity * moving.angularVelocity
                precondition(nextEnergy <= energy + 0.001)
                energy = nextEnergy
            }
            precondition(moving.isStopped)
        }
        var invalid = body()
        invalid.step(limits: desktop, dt: .nan)
        precondition(invalid.center == CGPoint(x: 700, y: 450))
        print("PASS: center and off-center flicks, diagonal trajectory, face/corner impacts, timestep invariance, 100 throws with bounded energy and containment, finite settling")
    }
}
