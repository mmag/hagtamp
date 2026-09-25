import Foundation

/// The cursor files of a classic skin (`<name>.cur`, possibly animated RIFF data).
public enum SkinCursorName: String, CaseIterable, Sendable {
    case close = "CLOSE"
    case eqClose = "EQCLOSE"
    case eqNormal = "EQNORMAL"
    case eqSlider = "EQSLID"
    case eqTitle = "EQTITLE"
    case mainMenu = "MAINMENU"
    case shadeMenu = "MMENU"
    case minimize = "MIN"
    case normal = "NORMAL"
    case playlistClose = "PCLOSE"
    case playlistNormal = "PNORMAL"
    case positionBar = "POSBAR"
    case playlistSize = "PSIZE"
    case playlistTitleBar = "PTBAR"
    case playlistScroll = "PVSCROLL"
    case playlistWindowButton = "PWINBUT"
    case playlistShadeNormal = "PWSNORM"
    case playlistShadeSize = "PWSSIZE"
    case songName = "SONGNAME"
    case titleBar = "TITLEBAR"
    case volumeBalance = "VOLBAL"
    case windowButton = "WINBUT"
    case shadeNormal = "WSNORMAL"
    case shadePositionBar = "WSPOSBAR"
}

/// A decoded skin cursor: one frame, or several for animated (.ani) cursors.
public struct SkinCursor: Sendable {
    public struct Frame: Sendable {
        public let image: Bitmap
        public let hotspotX: Int
        public let hotspotY: Int
    }

    public let frames: [Frame]
    /// Seconds each entry of `sequence` is shown.
    public let durations: [Double]
    /// Frame indices in display order.
    public let sequence: [Int]

    public var isAnimated: Bool { sequence.count > 1 }
}

/// Decoder for Windows `.cur` files and animated `.ani` (RIFF ACON) cursors.
enum CursorDecoder {
    static func decode(_ data: Data) -> SkinCursor? {
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8) {
            return decodeANI(data)
        }
        guard let frame = decodeCUR(data) else { return nil }
        return SkinCursor(frames: [frame], durations: [0], sequence: [0])
    }

    /// ICO/CUR container: the first image of the directory, with its hotspot.
    static func decodeCUR(_ data: Data) -> SkinCursor.Frame? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // Editors wrote sloppy headers (non-zero reserved field, cursors typed as icons);
        // Windows loads them regardless, so only the image count is checked.
        guard bytes.count >= 22, [1, 2].contains(u16(2)), u16(4) >= 1 else { return nil }
        let entry = 6
        let width = Int(bytes[entry]) == 0 ? 256 : Int(bytes[entry])
        let height = Int(bytes[entry + 1]) == 0 ? 256 : Int(bytes[entry + 1])
        // For icons these fields are planes/bit count; treat them as a hotspot only if
        // they don't look like that.
        let (fieldX, fieldY) = (u16(entry + 4), u16(entry + 6))
        let looksLikeIconFields = fieldX <= 1 && [0, 1, 4, 8, 16, 24, 32].contains(fieldY)
        let hasHotspot = (u16(2) == 2 || !looksLikeIconFields) && fieldX < width && fieldY < height
        let hotspotX = hasHotspot ? fieldX : 0
        let hotspotY = hasHotspot ? fieldY : 0
        let size = u32(entry + 8), offset = u32(entry + 12)
        guard offset < bytes.count else { return nil }
        let end = size > 0 ? min(bytes.count, offset + size) : bytes.count
        let image = Data(bytes[offset..<end])

        let bitmap: Bitmap?
        if image.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            bitmap = Bitmap(imageData: image)
        } else {
            bitmap = try? BMPDecoder.decodeIconDIB(image)
        }
        guard let bitmap else { return nil }
        return SkinCursor.Frame(image: bitmap, hotspotX: hotspotX, hotspotY: hotspotY)
    }

    /// RIFF "ACON": `anih` header, optional `rate`/`seq ` chunks, frames in a `LIST fram`.
    static func decodeANI(_ data: Data) -> SkinCursor? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            at + 3 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : 0
        }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<min(bytes.count, at + 4)], as: UTF8.self) }

        var frames: [SkinCursor.Frame] = []
        var defaultRate = 10  // jiffies (1/60 s)
        var rates: [Int] = []
        var sequence: [Int] = []

        /// Frames kept: real animated cursors have a dozen or so.
        let maxFrames = 32
        func walk(_ start: Int, _ end: Int, depth: Int = 0) {
            var at = start
            while at + 8 <= end {
                let id = tag(at), size = u32(at + 4), body = at + 8
                let bodyEnd = min(end, body + size)
                switch id {
                case "anih" where size >= 36:
                    let rate = u32(body + 28)
                    if rate > 0 { defaultRate = rate }
                case "rate":
                    rates = stride(from: body, to: bodyEnd - 3, by: 4).map(u32)
                case "seq ":
                    sequence = stride(from: body, to: bodyEnd - 3, by: 4).map(u32)
                case "LIST":
                    // Frames sit one list deep; a file nesting lists thousands deep would exhaust the stack.
                    if tag(body) == "fram", depth < 2 { walk(body + 4, bodyEnd, depth: depth + 1) }
                case "icon" where frames.count < maxFrames && body < bodyEnd:
                    if let frame = decodeCUR(Data(bytes[body..<bodyEnd])) { frames.append(frame) }
                default:
                    break
                }
                at = body + size + size % 2
            }
        }
        guard tag(8) == "ACON" else { return nil }
        walk(12, bytes.count)
        guard !frames.isEmpty else { return nil }

        if sequence.isEmpty { sequence = Array(frames.indices) }
        sequence = sequence.map { min($0, frames.count - 1) }
        let durations = sequence.indices.map { i in Double(i < rates.count && rates[i] > 0 ? rates[i] : defaultRate) / 60 }
        return SkinCursor(frames: frames, durations: durations, sequence: sequence)
    }
}
