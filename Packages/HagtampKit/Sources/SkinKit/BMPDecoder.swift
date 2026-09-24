import Foundation

/// Decoder for Windows BMP files as found in Winamp skins.
///
/// Skins were produced by every paint program of the late 90s, so the decoder
/// is deliberately lenient: bogus sizes, short palettes and truncated pixel
/// data are tolerated the way Windows GDI tolerates them. Alpha is ignored
/// (Winamp blits with GDI, which has no notion of it), so results are opaque.
enum BMPDecoder {
    enum Failure: Error {
        case notBMP
        case unsupported(String)
        case truncated
    }

    static func decode(_ data: Data) throws -> Bitmap {
        try data.withUnsafeBytes { raw in
            try decode(Reader(bytes: raw.bindMemory(to: UInt8.self)))
        }
    }

    private static func decode(_ r: Reader) throws -> Bitmap {
        guard r.count >= 26, r.u8(0) == 0x42, r.u8(1) == 0x4D else { throw Failure.notBMP }
        let dataOffset = Int(r.u32(10))
        let headerSize = Int(r.u32(14))

        var width = 0, height = 0, bpp = 0, compression = 0, colorsUsed = 0
        var paletteEntrySize = 4
        var masks: (r: UInt32, g: UInt32, b: UInt32)?
        var afterHeader = 14 + headerSize

        switch headerSize {
        case 12:  // BITMAPCOREHEADER (OS/2 1.x)
            width = Int(r.u16(18))
            height = Int(Int16(bitPattern: r.u16(20)))
            bpp = Int(r.u16(24))
            paletteEntrySize = 3
        case 16, 40, 52, 56, 64, 108, 124:
            guard r.count >= 14 + min(headerSize, 40) else { throw Failure.truncated }
            width = Int(Int32(bitPattern: r.u32(18)))
            height = Int(Int32(bitPattern: r.u32(22)))
            bpp = Int(r.u16(28))
            if headerSize >= 40 {
                compression = Int(r.u32(30))
                colorsUsed = Int(r.u32(46))
            }
            if compression == 3 || compression == 6 {
                // BI_BITFIELDS: masks live in the V2+ header, or right after a 40-byte one.
                let at = 14 + 40
                guard r.count >= at + 12 else { throw Failure.truncated }
                masks = (r.u32(at), r.u32(at + 4), r.u32(at + 8))
                if headerSize == 40 { afterHeader += compression == 6 ? 16 : 12 }
            }
        default:
            throw Failure.unsupported("header size \(headerSize)")
        }

        let topDown = height < 0
        height = abs(height)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw Failure.unsupported("dimensions \(width)x\(height)")
        }
        guard [1, 2, 4, 8, 16, 24, 32].contains(bpp) else { throw Failure.unsupported("\(bpp) bpp") }

        var palette: [UInt32] = []
        if bpp <= 8 {
            let wanted = colorsUsed > 0 && colorsUsed <= 1 << bpp ? colorsUsed : 1 << bpp
            // Some writers put the pixel data right after a short palette; don't read into it.
            let limit = dataOffset > afterHeader ? min(dataOffset, r.count) : r.count
            let available = max(0, (limit - afterHeader) / paletteEntrySize)
            for i in 0..<min(wanted, available) {
                let at = afterHeader + i * paletteEntrySize
                palette.append(0xFF00_0000 | UInt32(r.u8(at + 2)) << 16 | UInt32(r.u8(at + 1)) << 8 | UInt32(r.u8(at)))
            }
        }

        // A zero or out-of-range offset means the writer didn't bother; assume a packed layout.
        var pixelStart = dataOffset
        if pixelStart < afterHeader || pixelStart >= r.count {
            pixelStart = afterHeader + palette.count * paletteEntrySize
        }

        var bitmap = Bitmap(width: width, height: height, fill: .black)
        let row: (Int) -> Int = { topDown ? $0 : height - 1 - $0 }

        switch compression {
        case 0, 3, 6:
            try decodeUncompressed(
                r, from: pixelStart, into: &bitmap, bpp: bpp, palette: palette, masks: masks, row: row)
        case 1 where bpp == 8, 2 where bpp == 4:
            decodeRLE(r, from: pixelStart, into: &bitmap, fourBit: compression == 2, palette: palette, row: row)
        default:
            throw Failure.unsupported("compression \(compression)")
        }
        return bitmap
    }

    private static func decodeUncompressed(
        _ r: Reader, from start: Int, into bitmap: inout Bitmap, bpp: Int, palette: [UInt32],
        masks: (r: UInt32, g: UInt32, b: UInt32)?, row: (Int) -> Int
    ) throws {
        let width = bitmap.width
        let stride = (width * bpp + 31) / 32 * 4
        let rMask = masks?.r ?? (bpp == 16 ? 0x7C00 : 0xFF_0000)
        let gMask = masks?.g ?? (bpp == 16 ? 0x03E0 : 0x00_FF00)
        let bMask = masks?.b ?? (bpp == 16 ? 0x001F : 0x00_00FF)
        let channels = [MaskChannel(rMask), MaskChannel(gMask), MaskChannel(bMask)]

        func paletteColor(_ index: Int) -> UInt32 {
            index < palette.count ? palette[index] : PixelColor.black.argb
        }

        bitmap.pixels.withUnsafeMutableBufferPointer { dst in
            for y in 0..<bitmap.height {
                let rowStart = start + y * stride
                // Truncated files keep whatever rows were present; the rest stays black.
                guard rowStart < r.count else { break }
                let out = row(y) * width
                for x in 0..<width {
                    let color: UInt32
                    switch bpp {
                    case 1, 2, 4, 8:
                        let bit = x * bpp
                        let at = rowStart + bit / 8
                        guard at < r.count else { continue }
                        let shift = 8 - bpp - bit % 8
                        color = paletteColor(Int(r.u8(at) >> UInt8(shift)) & ((1 << bpp) - 1))
                    case 16:
                        let at = rowStart + x * 2
                        guard at + 1 < r.count else { continue }
                        let v = UInt32(r.u16(at))
                        color = 0xFF00_0000 | channels[0].value(v) << 16 | channels[1].value(v) << 8 | channels[2].value(v)
                    case 24:
                        let at = rowStart + x * 3
                        guard at + 2 < r.count else { continue }
                        color = 0xFF00_0000 | UInt32(r.u8(at + 2)) << 16 | UInt32(r.u8(at + 1)) << 8 | UInt32(r.u8(at))
                    default:  // 32
                        let at = rowStart + x * 4
                        guard at + 3 < r.count else { continue }
                        let v = r.u32(at)
                        color = 0xFF00_0000 | channels[0].value(v) << 16 | channels[1].value(v) << 8 | channels[2].value(v)
                    }
                    dst[out + x] = color
                }
            }
        }
    }

    private static func decodeRLE(
        _ r: Reader, from start: Int, into bitmap: inout Bitmap, fourBit: Bool, palette: [UInt32],
        row: (Int) -> Int
    ) {
        let width = bitmap.width, height = bitmap.height
        // Pixels an RLE stream skips (early end of line/bitmap, deltas) keep index 0,
        // as in the zero-initialised DIB section Windows decompresses into.
        bitmap.fill(bitmap.bounds, with: PixelColor(argb: palette.first ?? PixelColor.black.argb))
        var x = 0, y = 0, at = start
        func put(_ index: Int) {
            guard x < width, y < height else { return }
            bitmap.pixels[row(y) * width + x] = index < palette.count ? palette[index] : PixelColor.black.argb
        }
        while at + 1 < r.count, y < height {
            let count = Int(r.u8(at)), value = Int(r.u8(at + 1))
            at += 2
            if count > 0 {
                for i in 0..<count {
                    put(fourBit ? (i % 2 == 0 ? value >> 4 : value & 0x0F) : value)
                    x += 1
                }
                continue
            }
            switch value {
            case 0:
                x = 0
                y += 1
            case 1:
                return
            case 2:
                guard at + 1 < r.count else { return }
                x += Int(r.u8(at))
                y += Int(r.u8(at + 1))
                at += 2
            default:
                // Absolute run of `value` pixels, padded to a 16-bit boundary.
                let bytes = fourBit ? (value + 1) / 2 : value
                for i in 0..<value {
                    let byteAt = at + (fourBit ? i / 2 : i)
                    guard byteAt < r.count else { return }
                    let b = Int(r.u8(byteAt))
                    put(fourBit ? (i % 2 == 0 ? b >> 4 : b & 0x0F) : b)
                    x += 1
                }
                at += bytes + bytes % 2
            }
        }
    }

    private struct MaskChannel {
        let mask: UInt32
        let shift: UInt32
        let maxValue: UInt32

        init(_ mask: UInt32) {
            self.mask = mask
            shift = mask == 0 ? 0 : UInt32(mask.trailingZeroBitCount)
            maxValue = mask == 0 ? 0 : mask >> shift
        }

        /// Scales the masked component to 0...255.
        func value(_ pixel: UInt32) -> UInt32 {
            guard maxValue > 0 else { return 0 }
            let v = (pixel & mask) >> shift
            return maxValue == 255 ? v : (v * 255 + maxValue / 2) / maxValue
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var count: Int { bytes.count }

        func u8(_ at: Int) -> UInt8 { at < bytes.count ? bytes[at] : 0 }
        func u16(_ at: Int) -> UInt16 { UInt16(u8(at)) | UInt16(u8(at + 1)) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    }
}

extension BMPDecoder {
    /// Decodes the image of an icon/cursor resource: a headerless DIB whose
    /// height covers the colour (XOR) bitmap plus a 1-bit AND mask.
    /// Transparency comes from 32-bit alpha when present, else from the mask.
    static func decodeIconDIB(_ dib: Data) throws -> Bitmap {
        let bytes = [UInt8](dib)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let headerSize = u32(0)
        guard headerSize >= 40, bytes.count > headerSize else { throw Failure.unsupported("icon header \(headerSize)") }
        let width = u32(4), height = u32(8) / 2, bpp = u16(14), colorsUsed = u32(32)
        guard width > 0, height > 0, width <= 256, height <= 256 else { throw Failure.unsupported("icon \(width)x\(height)") }

        // Re-wrap as a BMP file with the real height; a zero data offset selects the packed layout.
        var header = bytes
        let h = UInt32(height)
        header.replaceSubrange(8..<12, with: [UInt8(h & 0xFF), UInt8(h >> 8 & 0xFF), 0, 0])
        var file: [UInt8] = Array("BM".utf8)
        let total = UInt32(14 + header.count)
        file += [UInt8(total & 0xFF), UInt8(total >> 8 & 0xFF), UInt8(total >> 16 & 0xFF), UInt8(total >> 24)]
        file += [0, 0, 0, 0, 0, 0, 0, 0]
        var bitmap = try decode(Data(file + header))

        let paletteCount = bpp <= 8 ? (colorsUsed > 0 ? colorsUsed : 1 << bpp) : 0
        let xorStart = headerSize + paletteCount * 4
        let xorStride = (width * bpp + 31) / 32 * 4
        let andStart = xorStart + xorStride * height
        let andStride = (width + 31) / 32 * 4

        var hasAlpha = false
        if bpp == 32 {
            hasAlpha = (0..<width * height).contains { i in
                let at = xorStart + (i / width) * xorStride + (i % width) * 4 + 3
                return at < bytes.count && bytes[at] != 0
            }
        }
        for y in 0..<height {
            let row = height - 1 - y  // bottom-up
            for x in 0..<width {
                var color = bitmap[x, y]
                if hasAlpha {
                    let alpha = UInt32(bytes[xorStart + row * xorStride + x * 4 + 3])
                    func premultiply(_ c: UInt8) -> UInt32 { (UInt32(c) * alpha + 127) / 255 }
                    color = PixelColor(argb: alpha << 24 | premultiply(color.red) << 16 | premultiply(color.green) << 8 | premultiply(color.blue))
                } else {
                    let at = andStart + row * andStride + x / 8
                    let transparent = at < bytes.count && bytes[at] & (0x80 >> UInt8(x % 8)) != 0
                    // Masked pixels with a non-black colour invert the screen on Windows; show them as drawn.
                    if transparent && color.argb & 0xFF_FFFF == 0 { color = .clear }
                }
                bitmap[x, y] = color
            }
        }
        return bitmap
    }
}
