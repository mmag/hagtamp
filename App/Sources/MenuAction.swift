import AppKit

/// Lets menu items run closures (NSMenuItem only knows target/action).
@MainActor
final class MenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: Any?) {
        handler()
    }
}

extension NSMenuItem {
    /// A menu item that runs `handler`, with a check mark when `checked`.
    @MainActor
    convenience init(title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        let action = MenuAction(handler)
        self.init(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        target = action
        representedObject = action  // menu items hold targets weakly
        state = checked ? .on : .off
        isEnabled = enabled
    }
}
