import AppKit

@main
struct InkRenderingTests {
    @MainActor static func main() {
        let size = 256
        let color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        func context(_ scale: Int) -> CGContext {
            CGContext(data: nil, width: size * scale, height: size * scale,
                      bitsPerComponent: 8, bytesPerRow: size * scale * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        var observedDelta = 0
        func assertSame(_ a: CGContext, _ b: CGContext, _ label: String, tolerance: Int = 2) {
            let bytes = a.bytesPerRow * a.height
            let aa = a.data!.assumingMemoryBound(to: UInt8.self)
            let bb = b.data!.assumingMemoryBound(to: UInt8.self)
            var maxDelta = 0
            for i in 0..<bytes { maxDelta = max(maxDelta, abs(Int(aa[i]) - Int(bb[i]))) }
            // Core Graphics can round edge coverage by up to two 8-bit steps when
            // rasterizing the same vector path under a smaller clip rectangle.
            observedDelta = max(observedDelta, maxDelta)
            precondition(maxDelta <= tolerance, "\(label): maximum channel delta \(maxDelta)")
        }
        let canvas = CGRect(x: -400, y: -200, width: size, height: size)
        let rulerA = CGPath(roundedRect: CGRect(x: -310, y: -150, width: 30, height: 120), cornerWidth: 8, cornerHeight: 8, transform: nil)
        let rulerB = CGPath(roundedRect: CGRect(x: -220, y: -140, width: 45, height: 110), cornerWidth: 8, cornerHeight: 8, transform: nil)

        func paint(_ context: CGContext, scale: Int, dirty: CGRect, strokes: [MarkerStroke], ruler: CGPath?, time: Double = 10) {
            context.saveGState()
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.translateBy(x: -canvas.minX, y: -canvas.minY)
            let clipped = dirty.integral.intersection(canvas)
            context.clip(to: clipped)
            context.clear(clipped)
            for stroke in strokes where stroke.bounds.intersects(clipped) {
                stroke.draw(in: context, at: time, canvasBounds: canvas, ruler: ruler)
            }
            context.restoreGState()
        }

        for scale in [1, 2] {
            for width: CGFloat in [2, 6, 16] {
                let opacity: CGFloat = width == 16 ? 0.45 : 1
                let first = CGPoint(x: -380, y: -170)
                let stroke = MarkerStroke(point: first, color: color, width: width, opacity: opacity, excludedRuler: rulerA)
                var points = [first]
                let cached = context(scale)
                let partial = context(scale)
                paint(partial, scale: scale, dirty: stroke.bounds, strokes: [stroke], ruler: rulerB)
                for i in 1...150 {
                    let point = CGPoint(x: -380 + Double(i), y: -100 + sin(Double(i) * 0.09) * 65)
                    points.append(point)
                    let damage = stroke.append(point, guided: false)
                    paint(partial, scale: scale, dirty: damage, strokes: [stroke], ruler: rulerB)
                    paint(cached, scale: scale, dirty: canvas, strokes: [stroke], ruler: rulerB)
                    assertSame(partial, cached, "incremental round joins, width \(width), scale \(scale), point \(i)")
                }

                // Independent implementation of the former per-point draw path.
                let reference = context(scale)
                reference.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                reference.translateBy(x: -canvas.minX, y: -canvas.minY)
                for exclusion in [rulerA, rulerB] {
                    reference.addRect(canvas.insetBy(dx: -1, dy: -1))
                    reference.addPath(exclusion)
                    reference.clip(using: .evenOdd)
                }
                reference.setStrokeColor(color.withAlphaComponent(opacity).cgColor)
                reference.setLineWidth(width)
                reference.setLineCap(.round)
                reference.setLineJoin(.round)
                reference.move(to: points[0])
                for point in points.dropFirst() { reference.addLine(to: point) }
                reference.strokePath()
                assertSame(cached, reference, "cached versus original geometry", tolerance: 0)
                stroke.finish(at: 10)
                paint(cached, scale: scale, dirty: canvas, strokes: [stroke], ruler: rulerB)
                assertSame(cached, reference, "frozen geometry", tolerance: 0)

                let guided = MarkerStroke(point: CGPoint(x: -385, y: -80), color: .yellow, width: 16, opacity: 0.45, excludedRuler: nil)
                var previous = guided.bounds
                for point in [CGPoint(x: -160, y: -80), CGPoint(x: -350, y: -80), CGPoint(x: -175, y: -80)] {
                    let damage = guided.append(point, guided: true)
                    precondition(damage.contains(previous) && damage.contains(guided.bounds))
                    paint(partial, scale: scale, dirty: damage, strokes: [stroke, guided], ruler: rulerB)
                    paint(cached, scale: scale, dirty: canvas, strokes: [stroke, guided], ruler: rulerB)
                    assertSame(partial, cached, "guided extension/retraction and translucent overlap")
                    previous = guided.bounds
                }
                guided.finish(at: 10)
                // Undo and redo repaint only this stroke's former region.
                paint(partial, scale: scale, dirty: guided.bounds, strokes: [stroke], ruler: rulerB)
                paint(cached, scale: scale, dirty: canvas, strokes: [stroke], ruler: rulerB)
                assertSame(partial, cached, "undo")
                paint(partial, scale: scale, dirty: guided.bounds, strokes: [stroke, guided], ruler: rulerB)
                paint(cached, scale: scale, dirty: canvas, strokes: [stroke, guided], ruler: rulerB)
                assertSame(partial, cached, "redo")

                let rulerDamage = rulerB.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
                paint(partial, scale: scale, dirty: rulerDamage, strokes: [stroke, guided], ruler: nil)
                paint(cached, scale: scale, dirty: canvas, strokes: [stroke, guided], ruler: nil)
                assertSame(partial, cached, "ruler removed, original exclusion retained")
                for time in [40.0, 40.1, 40.25, 40.5] {
                    paint(partial, scale: scale, dirty: stroke.bounds.union(guided.bounds), strokes: [stroke, guided], ruler: nil, time: time)
                    paint(cached, scale: scale, dirty: canvas, strokes: [stroke, guided], ruler: nil, time: time)
                    assertSame(partial, cached, "fade \(time)")
                }
            }
        }
        print("Maximum edge-coverage delta: \(observedDelta)/255")
        print("PASS: cached geometry and partial redraws match within two 8-bit edge-coverage steps at 1x/2x for all widths, negative desktop coordinates, joins, ruler clipping/removal, guided retraction, overlapping highlighter, undo/redo, and fade.")
    }
}
