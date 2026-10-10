import AppKit

@main
struct MarkerTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let controller = MarkerController.shared
        precondition(controller.tools.map(\.width) == [2, 6, 16])
        precondition(controller.tools.map(\.name) == ["Pencil", "Marker", "Highlighter"])
        let original = controller.tools
        controller.selectColor(.purple, for: 1)
        precondition(controller.tools[0].color == original[0].color)
        precondition(controller.tools[2].color == original[2].color)
        precondition(controller.tools.map(\.width) == [2, 6, 16])
        precondition(controller.tools.map(\.opacity) == [1, 1, 0.45])
        controller.selectTool(1)
        precondition(controller.isSelected(.purple) && controller.strokeWidth == 6)
        controller.selectTool(0)
        precondition(controller.strokeWidth == 2)
        controller.selectColor(original[1].color, for: 1)

        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                       CGRect(x: 0, y: 0, width: 800, height: 600)] {
            let frames = MarkerGeometry.spawnFrames(in: screen)
            for i in frames.indices {
                precondition(screen.contains(frames[i]))
                for j in frames.indices where j != i { precondition(!frames[i].intersects(frames[j])) }
            }
        }
        for angle in stride(from: -360.0, through: 360.0, by: 1) {
            let size = MarkerGeometry.size(angle: angle)
            for point in [CGPoint(x: 33, y: 105), CGPoint(x: 33, y: 180), CGPoint(x: 17, y: 12)] {
                let a = angle * .pi / 180
                let x = point.x - 33, y = point.y - 105
                let rotated = CGPoint(x: x * cos(a) - y * sin(a) + size.width / 2,
                                      y: x * sin(a) + y * cos(a) + size.height / 2)
                let recovered = MarkerGeometry.localPoint(rotated, size: size, angle: angle)
                precondition(hypot(recovered.x - point.x, recovered.y - point.y) < 0.0001)
                precondition(CGRect(origin: .zero, size: size).contains(rotated))
            }
        }
        controller.activateTip(0)
        precondition(controller.isDrawing)
        controller.beginStroke(at: CGPoint(x: 20, y: 20))
        controller.continueStroke(at: CGPoint(x: 40, y: 40))
        controller.activateTip(1)
        precondition(controller.isDrawing && controller.selectedToolID == 1)
        precondition(controller.canUndo)
        controller.beginStroke(at: CGPoint(x: 60, y: 60))
        controller.finishStroke()
        controller.activateTip(1)
        precondition(!controller.isDrawing)
        controller.undoStroke()
        precondition(controller.canRedo && controller.canUndo)
        controller.undoStroke()
        precondition(!controller.canUndo && controller.canRedo)
        controller.redoStroke()
        precondition(controller.canUndo)
        controller.clearMarkings()
        precondition(!controller.hasMarkings && !controller.canUndo && !controller.canRedo)
        let inkWindow = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 100, height: 100),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        let inkView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        inkWindow.contentView = inkView

        func maximumInkAlpha() -> CGFloat {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current!.cgContext.clear(inkView.bounds)
            controller.drawInk(in: inkView)
            NSGraphicsContext.restoreGraphicsState()
            var maximum: CGFloat = 0
            for y in 0..<100 {
                for x in 0..<100 { maximum = max(maximum, bitmap.colorAt(x: x, y: y)!.alphaComponent) }
            }
            return maximum
        }

        for id in 0..<3 {
            controller.clearMarkings()
            controller.selectTool(id)
            controller.setDrawing(true)
            controller.beginStroke(at: inkWindow.convertPoint(toScreen: CGPoint(x: 20, y: 50)))
            controller.continueStroke(at: inkWindow.convertPoint(toScreen: CGPoint(x: 80, y: 50)))
            let expected: CGFloat = id == 2 ? 0.45 : 1
            precondition(abs(maximumInkAlpha() - expected) < 0.01)
            controller.finishStroke()
            controller.selectTool((id + 1) % 3)
            controller.undoStroke()
            precondition(maximumInkAlpha() == 0)
            controller.redoStroke()
            precondition(abs(maximumInkAlpha() - expected) < 0.01)
        }
        controller.clearMarkings()
        controller.setVisible(false)

        let image = NSImage(size: CGSize(width: 540, height: 300))
        image.lockFocus()
        NSColor(white: 0.2, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 540, height: 300)).fill()
        for id in 0..<3 {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: CGFloat(id) * 175 + 15, yBy: 35)
            transform.concat()
            let size = MarkerGeometry.size(angle: MarkerGeometry.spawnAngles[id])
            let view = MarkerView(frame: CGRect(origin: .zero, size: size), toolID: id)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: independent colors, fixed widths, selection, opacity, cluster placement, 721 rotation/hit-test round trips, three-tool rendering, tip switching, drawing mode, undo/redo, rendered opacity before and after redo")
    }
}
