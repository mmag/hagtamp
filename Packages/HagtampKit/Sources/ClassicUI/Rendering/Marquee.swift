import Foundation
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

/// Messages the marquee shows while a control is being dragged (formats from
/// Webamp's marqueeUtils, MIT).
extension Marquee {
    public static func volumeText(_ volume: Double) -> String {
        "Volume: \(Int((volume * 100).rounded()))%"
    }

    public static func balanceText(_ balance: Double) -> String {
        let percent = Int((abs(balance) * 100).rounded())
        return percent == 0 ? "Balance: Center" : "Balance: \(percent)% \(balance > 0 ? "Right" : "Left")"
    }

    public static func seekText(position: Double, duration: Int) -> String {
        let target = Int((position * Double(duration)).rounded(.down))
        return "Seek to: \(timeString(target))/\(timeString(duration)) (\(Int((position * 100).rounded()))%)"
    }

    public static let bandLabels = ["60HZ", "170HZ", "310HZ", "600HZ", "1KHZ", "3KHZ", "6KHZ", "12KHZ", "14KHZ", "16KHZ"]

    /// `band` nil means the preamp. Slider positions 0...1 map to -12...+12 dB.
    public static func equalizerText(band: Int?, value: Double) -> String {
        let db = ((value - 0.5) * 24 * 10).rounded() / 10
        let label = band.map { bandLabels[$0] } ?? "Preamp"
        let formatted = String(format: "%.1f", db)
        return "EQ: \(label) \(db > 0 ? "+" : "")\(formatted == "-0.0" ? "0.0" : formatted) DB"
    }

    public static func doubleSizeText(enabled: Bool) -> String {
        "\(enabled ? "Disable" : "Enable") doublesize mode"
    }

    public static func timeString(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
