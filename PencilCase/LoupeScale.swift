import Foundation

/// One shared angular scale for labels, ticks, continuous zoom, and feedback.
nonisolated enum LoupeScale {
    static let levels: [Double] = [1, 1.25, 1.5, 2, 3, 4, 6, 8, 10]
    static let degreesPerLevel = 32.0
    static let subdivisions = 8

    static func clamp(_ position: Double) -> Double {
        min(Double(levels.count - 1), max(0, position))
    }

    static func zoom(at position: Double) -> Double {
        let position = clamp(position)
        let lower = Int(position)
        let upper = min(lower + 1, levels.count - 1)
        let fraction = position - Double(lower)

        return levels[lower] + (levels[upper] - levels[lower]) * fraction
    }

    static func angle(at position: Double, dial: Double) -> Double {
        (90 + (position - dial) * degreesPerLevel) * .pi / 180
    }

    static func crossesTick(from old: Double, to new: Double) -> Bool {
        levels.indices.contains { index in
            let tick = Double(index)
            return old < tick && new >= tick || old > tick && new <= tick
        }
    }
}
