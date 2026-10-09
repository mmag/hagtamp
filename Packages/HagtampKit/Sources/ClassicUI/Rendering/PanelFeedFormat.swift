import Foundation
import SkinKit

/// The wire format of the app's local panel feed (a WebSocket for displays
/// outside the app): binary messages carry parts of the main window as it
/// is drawn, text ones colors as hex.
public enum PanelFeedFormat {
    /// The main window's display: play/pause indicator, time and visualizer.
    public static let display: UInt8 = 0x01
    /// The scrolling song title.
    public static let marquee: UInt8 = 0x02

    /// Where the display sits in the main window (right of the clutter bar).
    public static let displayRect = PixelRect(x: 20, y: 22, width: 83, height: 42)
    public static let marqueeRect = MainWindowRenderer.marqueeRect

    /// [type][width][height][0x00][sequence, u32 little-endian], then
    /// width × height RGBA pixels, rows top to bottom.
    public static func frame(_ bitmap: Bitmap, type: UInt8, sequence: UInt32) -> Data {
        var data = Data(capacity: 8 + bitmap.width * bitmap.height * 4)
        data.append(contentsOf: [type, UInt8(clamping: bitmap.width), UInt8(clamping: bitmap.height), 0x00])
        data.append(contentsOf: withUnsafeBytes(of: sequence.littleEndian, Array.init))
        for argb in bitmap.pixels {
            data.append(contentsOf: [UInt8(truncatingIfNeeded: argb >> 16), UInt8(truncatingIfNeeded: argb >> 8), UInt8(truncatingIfNeeded: argb), UInt8(truncatingIfNeeded: argb >> 24)])
        }
        return data
    }

    /// "#RRGGBB".
    public static func hex(_ color: PixelColor) -> String {
        String(format: "#%06X", color.argb & 0xFF_FFFF)
    }
}
