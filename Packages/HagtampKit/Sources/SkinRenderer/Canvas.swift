import SkinKit

extension Bitmap {
    /// Blits a sprite of `skin` with its top-left at (`x`, `y`).
    mutating func draw(_ skin: Skin, _ sprite: Sprite, x: Int, y: Int, clip: PixelRect? = nil) {
        guard let sheet = skin.bitmap(sprite.sheet) else { return }
        draw(sheet, from: sprite.rect, atX: x, y: y, clip: clip)
    }

    /// Blits the top-left `width`x`height` part of a sprite, the way an HTML
    /// element smaller than its background image shows only part of it.
    mutating func draw(_ skin: Skin, _ sprite: Sprite, x: Int, y: Int, width: Int, height: Int) {
        draw(skin, sprite, x: x, y: y, clip: PixelRect(x: x, y: y, width: width, height: height))
    }

    /// Repeats a sprite over `rect`, anchored at the rect's top-left corner
    /// unless another origin is given.
    mutating func tile(_ skin: Skin, _ sprite: Sprite, over rect: PixelRect, originX: Int? = nil, originY: Int? = nil) {
        guard let sheet = skin.bitmap(sprite.sheet) else { return }
        tile(sheet, from: sprite.rect, into: rect, originX: originX ?? rect.x, originY: originY ?? rect.y)
    }

    /// Draws `text` with the TEXT.BMP font, clipped to `width` pixels when given.
    mutating func drawText(_ skin: Skin, _ text: String, x: Int, y: Int, width: Int? = nil) {
        drawText(skin, text, x: x, y: y, clip: width.map { PixelRect(x: x, y: y, width: $0, height: SkinFont.glyphHeight) })
    }

    mutating func drawText(_ skin: Skin, _ text: String, x: Int, y: Int, clip: PixelRect?) {
        var cursor = x
        for character in text {
            defer { cursor += SkinFont.glyphWidth }
            if let clip {
                if cursor >= clip.maxX { break }
                if cursor + SkinFont.glyphWidth <= clip.x { continue }
            }
            draw(skin, SkinFont.sprite(for: character), x: cursor, y: y, clip: clip)
        }
    }
}

/// Maps a 0...1 value to one of `frames` background frames.
func frameIndex(_ value: Double, frames: Int) -> Int {
    min(frames - 1, max(0, Int((value * Double(frames - 1)).rounded())))
}
