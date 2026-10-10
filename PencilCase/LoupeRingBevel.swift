import AppKit

@MainActor
enum LoupeRingBevel {
    /// Cached at backing resolution; the dial does not redraw these bands per frame.
    static func image(size: CGSize, scale: CGFloat) -> NSImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * scale),
                                      height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)

        let angle: CGFloat = 125 * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = CGPoint(x: center.x - direction.x * 145, y: center.y - direction.y * 145)
        let end = CGPoint(x: center.x + direction.x * 145, y: center.y + direction.y * 145)

        for index in 0..<48 {
            let depth = CGFloat(index) * 0.25
            // Keep the ruler’s light direction, with a broader, brighter shoulder on the ring.
            for innerEdge in [false, true] {
                if innerEdge && depth > 8 { continue }
                let radius: CGFloat = innerEdge ? 108 + depth + 0.25 : 144.1 - depth
                let strength: CGFloat = innerEdge ? 0.85 : 1
                let colors = [NSColor.white.withAlphaComponent(0.075 * exp(-depth / 2.25) * strength).cgColor,
                              NSColor.white.withAlphaComponent(0.36 * exp(-depth / 4.5) * strength).cgColor] as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                colors: colors, locations: [0, 1]) else { continue }

                context.saveGState()
                context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
                context.addEllipse(in: CGRect(x: center.x - radius + 0.25, y: center.y - radius + 0.25,
                                              width: (radius - 0.25) * 2, height: (radius - 0.25) * 2))
                context.clip(using: .evenOdd)
                context.drawLinearGradient(gradient, start: innerEdge ? end : start,
                                           end: innerEdge ? start : end,
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
        }

        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}
