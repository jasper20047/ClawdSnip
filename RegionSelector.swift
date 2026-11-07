import Cocoa

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionSelector: NSView {
    private var origin: NSPoint?
    private var selection = CGRect.zero
    private var overlay: NSWindow?
    private var completion: ((CGRect?) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func present(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        frame = CGRect(origin: .zero, size: screen.frame.size)
        let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.level = .screenSaver; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = self; overlay = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(self)
        NSCursor.crosshair.push()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill(); bounds.fill()
        if !selection.isEmpty {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
        }
        let text = "拖动框选录制区域 · Esc 取消"
        text.draw(at: NSPoint(x: 24, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(origin.x - point.x), height: abs(origin.y - point.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finish(selection.width >= 4 && selection.height >= 4 ? selection : nil)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }
    func cancel() { finish(nil) }
    private func finish(_ rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        overlay?.orderOut(nil); overlay?.close(); overlay = nil
        NSCursor.pop()
        completion(rect)
    }
}
