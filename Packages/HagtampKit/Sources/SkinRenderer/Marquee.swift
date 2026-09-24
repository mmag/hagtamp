import SkinKit

/// Scrolling of the main window's song title display.
///
/// Titles that fit are padded with spaces (which paints the text background
/// across the whole display); longer ones loop with a `  ***  ` separator.
public enum Marquee {
    public static let separator = "  ***  "
    /// Titles of at least this many characters scroll.
    public static let scrollThreshold = 31
    /// Winamp advances the marquee one character every 220 ms.
    public static let stepInterval = 0.22

    public static func scrolls(_ text: String) -> Bool {
        text.count >= scrollThreshold
    }

    public static func displayText(_ text: String) -> String {
        guard scrolls(text) else {
            return text + String(repeating: " ", count: scrollThreshold - text.count)
        }
        return text + separator + text
    }

    /// Pixel offset after `step` one-character steps plus a manual drag.
    public static func offset(for text: String, step: Int, dragPixels: Int = 0) -> Int {
        guard scrolls(text) else { return 0 }
        let period = (text.count + separator.count) * SkinFont.glyphWidth
        let raw = step * SkinFont.glyphWidth + dragPixels
        return ((raw % period) + period) % period
    }
}
