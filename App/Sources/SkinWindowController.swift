import AppKit
import ClassicUI
import SkinKit

/// Pointer handling shared by the three classic windows.
///
/// A press is routed by the control under it: buttons act on release inside,
/// sliders follow the pointer, title bars and the window body move the window
/// (with docking), and `.press` controls are handled by the subclass.
@MainActor
class SkinWindowController: NSObject, SkinViewDelegate {
    let id: WindowID
    let window = SkinWindow()
    unowned let manager: WindowManager

    /// Control drawn pressed.
    var pressed: Control?
    var shade = false

    private enum Tracking {
        case button(Control, PixelRect)
        case slider(Control, SliderGeometry, grab: Int)
        case moveWindow
        case custom(Control)
    }

    private var tracking: Tracking?

    init(id: WindowID, manager: WindowManager) {
        self.id = id
        self.manager = manager
        super.init()
        window.skinView.delegate = self
        window.skinView.cursors = manager.cursors
        window.onFocusChange = { [weak manager] in manager?.render() }
    }

    var isFocused: Bool { window.isKeyWindow }

    // MARK: - Subclass hooks

    func regions() -> [ControlRegion] { [] }
    var bodyCursor: SkinCursorName { .normal }
    func renderBitmap() -> Bitmap { Bitmap(width: 1, height: 1) }
    /// Size of the window in skin pixels for the current mode.
    func pixelSize() -> (width: Int, height: Int) { (1, 1) }
    /// Polygons of the window shape for the current mode, nil = rectangular.
    func shapePolygons() -> [SkinRegions.Polygon]? { nil }

    func sliderValue(_ control: Control) -> Double { 0 }
    func sliderChanged(_ control: Control, value: Double) {}
    func sliderEnded(_ control: Control, value: Double) {}
    func buttonClicked(_ control: Control) {}
    /// Return true to receive the drag and release of this press.
    func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool { false }
    func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {}
    func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {}
    func titleBarDoubleClicked() { manager.toggleShade(id) }
    func scrolled(by delta: CGFloat) {}
    func contextMenuRequested(at point: SkinPoint, event: NSEvent) {}

    /// Lets a subclass take a press before normal routing (e.g. an open menu).
    func interceptPress(at point: SkinPoint, event: NSEvent) -> Bool { false }

    // MARK: - Rendering

    /// The window's bitmap with its region mask applied.
    func renderMasked() -> Bitmap {
        var bitmap = renderBitmap()
        if let polygons = shapePolygons() {
            bitmap.apply(mask: SkinRegions.mask(polygons, width: bitmap.width, height: bitmap.height))
        }
        return bitmap
    }

    private func isInsideShape(_ point: SkinPoint) -> Bool {
        let (width, height) = pixelSize()
        guard point.x >= 0, point.y >= 0, point.x < width, point.y < height else { return false }
        guard let polygons = shapePolygons() else { return true }
        return SkinRegions.mask(polygons, width: width, height: height)[point.y * width + point.x]
    }

    // MARK: - SkinViewDelegate

    func mouseDown(at point: SkinPoint, event: NSEvent) {
        guard isInsideShape(point) else { return }
        manager.raiseAll(keepingOnTop: id)
        if interceptPress(at: point, event: event) { return }

        guard let region = regions().hit(x: point.x, y: point.y) else {
            beginMove()
            return
        }
        switch region.behavior {
        case .moveWindow:
            if event.clickCount == 2 {
                titleBarDoubleClicked()
                return
            }
            beginMove()
        case .button:
            tracking = .button(region.control, region.rect)
            setPressed(region.control)
        case .slider(let geometry):
            let pointer = geometry.axis == .horizontal ? point.x : point.y
            let grab = geometry.grabOffset(pointer: pointer, value: sliderValue(region.control))
            tracking = .slider(region.control, geometry, grab: grab)
            setPressed(region.control)
            sliderChanged(region.control, value: geometry.value(pointer: pointer, grab: grab))
        case .press:
            if pressBegan(region.control, at: point, event: event) {
                tracking = .custom(region.control)
            }
        }
    }

    func mouseDragged(to point: SkinPoint, event: NSEvent) {
        switch tracking {
        case .moveWindow:
            manager.continueMove()
        case .button(let control, let rect):
            setPressed(rect.contains(x: point.x, y: point.y) ? control : nil)
        case .slider(let control, let geometry, let grab):
            let pointer = geometry.axis == .horizontal ? point.x : point.y
            sliderChanged(control, value: geometry.value(pointer: pointer, grab: grab))
        case .custom(let control):
            pressDragged(control, to: point, event: event)
        case nil:
            break
        }
    }

    func mouseUp(at point: SkinPoint, event: NSEvent) {
        let finished = tracking
        tracking = nil
        switch finished {
        case .moveWindow:
            manager.endMove()
        case .button(let control, let rect):
            setPressed(nil)
            if rect.contains(x: point.x, y: point.y) { buttonClicked(control) }
        case .slider(let control, let geometry, let grab):
            setPressed(nil)
            let pointer = geometry.axis == .horizontal ? point.x : point.y
            sliderEnded(control, value: geometry.value(pointer: pointer, grab: grab))
        case .custom(let control):
            pressEnded(control, at: point, event: event)
        case nil:
            break
        }
    }

    func rightMouseDown(at point: SkinPoint, event: NSEvent) {
        contextMenuRequested(at: point, event: event)
    }

    func scrollWheel(at point: SkinPoint, event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        if delta != 0 { scrolled(by: delta) }
    }

    func cursor(at point: SkinPoint) -> SkinCursorName? {
        regions().hit(x: point.x, y: point.y)?.cursor ?? bodyCursor
    }

    func keyDown(_ event: NSEvent) -> Bool { manager.handleKey(event) }

    func filesDropped(_ urls: [URL], at point: SkinPoint) { manager.filesDropped(urls, on: id, at: point) }

    // MARK: - Helpers

    private func beginMove() {
        tracking = .moveWindow
        manager.beginMove(id)
    }

    func setPressed(_ control: Control?) {
        guard pressed != control else { return }
        pressed = control
        manager.render()
    }

    /// Switches an ongoing slider drag to another control (EQ band sweeping).
    func retargetSlider(to control: Control, geometry: SliderGeometry, grab: Int) {
        tracking = .slider(control, geometry, grab: grab)
        pressed = control
    }
}
