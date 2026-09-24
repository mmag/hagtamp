import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A premultiplied 32-bit color stored as `0xAARRGGBB`.
public struct PixelColor: Hashable, Sendable, CustomStringConvertible {
    public var argb: UInt32

    public init(argb: UInt32) {
        self.argb = argb
    }

    /// Opaque color from 8-bit components.
    public init(r: UInt8, g: UInt8, b: UInt8) {
        argb = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    /// Opaque color from `0xRRGGBB`.
    public init(rgb: UInt32) {
        argb = 0xFF00_0000 | (rgb & 0x00FF_FFFF)
    }

    public var alpha: UInt8 { UInt8(argb >> 24) }
    public var red: UInt8 { UInt8((argb >> 16) & 0xFF) }
    public var green: UInt8 { UInt8((argb >> 8) & 0xFF) }
    public var blue: UInt8 { UInt8(argb & 0xFF) }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }

    public var description: String {
        String(format: "#%02X%02X%02X", red, green, blue) + (alpha == 255 ? "" : String(format: "@%02X", alpha))
    }

    public static let clear = PixelColor(argb: 0)
    public static let black = PixelColor(rgb: 0x000000)
}

public struct PixelRect: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    public var description: String { "(\(x),\(y) \(width)x\(height))" }
}

/// A mutable premultiplied ARGB pixel buffer with a top-left origin.
///
/// Skins are drawn by copying rectangles between bitmaps, exactly like Winamp
/// blits between DIBs. Keeping pixels in our own buffer (instead of going
/// through CoreGraphics) makes rendering deterministic and testable
/// pixel-for-pixel.
public struct Bitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row-major pixels, `0xAARRGGBB`. In memory (little-endian) this is BGRA,
    /// the native CoreGraphics layout.
    public var pixels: [UInt32]

    public init(width: Int, height: Int, fill: PixelColor = .clear) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
        pixels = Array(repeating: fill.argb, count: width * height)
    }

    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    public subscript(x: Int, y: Int) -> PixelColor {
        get { PixelColor(argb: pixels[y * width + x]) }
        set { pixels[y * width + x] = newValue.argb }
    }

    public mutating func fill(_ rect: PixelRect, with color: PixelColor) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        pixels.withUnsafeMutableBufferPointer { dst in
            for y in r.y..<r.maxY {
                let row = y * width
                for x in r.x..<r.maxX { dst[row + x] = color.argb }
            }
        }
    }

    /// Copies `source[rect]` so that its top-left lands at (`x`, `y`).
    ///
    /// Only pixels inside both `source` and `clip` (default: whole bitmap) are
    /// written, so a sprite that extends past the edge of an undersized skin
    /// bitmap leaves the destination untouched there. Opaque pixels are copied,
    /// translucent ones (PNG skins) are composited.
    public mutating func draw(_ source: Bitmap, from rect: PixelRect, atX x: Int, y: Int, clip: PixelRect? = nil) {
        let srcRect = rect.intersection(source.bounds)
        guard !srcRect.isEmpty else { return }
        let dx = x + (srcRect.x - rect.x)
        let dy = y + (srcRect.y - rect.y)
        let target = PixelRect(x: dx, y: dy, width: srcRect.width, height: srcRect.height)
            .intersection(clip.map { $0.intersection(bounds) } ?? bounds)
        guard !target.isEmpty else { return }
        let offsetX = srcRect.x - dx, offsetY = srcRect.y - dy
        let srcWidth = source.width, dstWidth = width
        source.pixels.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for ty in target.y..<target.maxY {
                    let srcRow = (ty + offsetY) * srcWidth + offsetX
                    let dstRow = ty * dstWidth
                    for tx in target.x..<target.maxX {
                        let p = src[srcRow + tx]
                        let a = p >> 24
                        if a == 0xFF {
                            dst[dstRow + tx] = p
                        } else if a != 0 {
                            dst[dstRow + tx] = Self.sourceOver(p, dst[dstRow + tx])
                        }
                    }
                }
            }
        }
    }

    /// Fills `dest` by repeating `source[rect]`, with the tiling pattern
    /// anchored at (`originX`, `originY`) like a CSS background.
    public mutating func tile(_ source: Bitmap, from rect: PixelRect, into dest: PixelRect, originX: Int, originY: Int) {
        guard rect.width > 0, rect.height > 0 else { return }
        let area = dest.intersection(bounds)
        guard !area.isEmpty else { return }
        func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
        let startX = originX + floorDiv(area.x - originX, rect.width) * rect.width
        let startY = originY + floorDiv(area.y - originY, rect.height) * rect.height
        var ty = startY
        while ty < area.maxY {
            var tx = startX
            while tx < area.maxX {
                draw(source, from: rect, atX: tx, y: ty, clip: area)
                tx += rect.width
            }
            ty += rect.height
        }
    }

    public func cropped(to rect: PixelRect) -> Bitmap {
        var out = Bitmap(width: rect.width, height: rect.height)
        out.draw(self, from: rect, atX: 0, y: 0)
        return out
    }

    /// Nearest-neighbour upscale by an integer factor (double-size mode, previews).
    public func scaled(by factor: Int) -> Bitmap {
        guard factor > 1 else { return self }
        var out = Bitmap(width: width * factor, height: height * factor)
        pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<out.height {
                    let srcRow = (y / factor) * width
                    let dstRow = y * out.width
                    for x in 0..<out.width { dst[dstRow + x] = src[srcRow + x / factor] }
                }
            }
        }
        return out
    }

    private static func sourceOver(_ s: UInt32, _ d: UInt32) -> UInt32 {
        let inv = 255 - (s >> 24)
        func channel(_ shift: UInt32) -> UInt32 {
            let sc = (s >> shift) & 0xFF, dc = (d >> shift) & 0xFF
            return min(255, sc + (dc * inv + 127) / 255) << shift
        }
        return channel(24) | channel(16) | channel(8) | channel(0)
    }
}

// MARK: - CoreGraphics interop

extension Bitmap {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    public func makeCGImage() -> CGImage {
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Decodes any image CoreGraphics understands. Returns nil for empty images.
    public init?(cgImage: CGImage) {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        var bitmap = Bitmap(width: cgImage.width, height: cgImage.height)
        bitmap.withCGContext { ctx in
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        self = bitmap
    }

    /// Runs `body` with a CoreGraphics context drawing directly into the
    /// pixels. The context uses CoreGraphics' bottom-left origin.
    public mutating func withCGContext(_ body: (CGContext) -> Void) {
        let (w, h) = (width, height)
        guard w > 0, h > 0 else { return }
        pixels.withUnsafeMutableBytes { raw in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo)
            else { return }
            ctx.interpolationQuality = .none
            body(ctx)
        }
    }

    public func pngData() -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeCGImage(), nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    public init?(imageData data: Data) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.init(cgImage: image)
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(imageData: data)
    }
}
