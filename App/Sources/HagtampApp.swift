import AppKit

@main
@MainActor
enum HagtampApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApp's own lookup answers with the generic icon here, although the
        // asset catalog has ours; the Dock tile and the About panel use it.
        if let icon = NSImage(named: "AppIcon") { app.applicationIconImage = icon }
        app.run()
    }
}
