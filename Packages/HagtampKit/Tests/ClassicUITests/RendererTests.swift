import Foundation
import SkinKit
import Testing

@testable import ClassicUI

@Suite struct RendererTests {
    /// The base skin must match the Winamp Skin Museum screenshot (rendered by
    /// Webamp) pixel for pixel, apart from the areas documented in
    /// `ReferenceScene.volatileRects`.
    @Test func baseSkinMatchesMuseumScreenshot() throws {
        let url = try #require(Bundle.module.url(forResource: "base-2.91-museum", withExtension: "png", subdirectory: "Fixtures"))
        let reference = try #require(Bitmap(contentsOf: url))
        // The original Winamp 2.91 base skin (the bundled default is retitled).
        let skinURL = try #require(Bundle.module.url(forResource: "base-2.91", withExtension: "wsz", subdirectory: "Fixtures"))
        let skin = try Skin.load(contentsOf: skinURL)
        let diff = ImageDiff(
            reference: reference, render: ReferenceScene.render(skin),
            areas: [("scene", reference.bounds)], ignoring: ReferenceScene.volatileRects)
        #expect(diff.areas[0].compared > 75_000)
        #expect(diff.totalMismatches == 0)
    }

    @Test func playlistGrowsInSteps() {
        var state = PlaylistWindowState()
        state.widthSteps = 3
        state.heightSteps = 2
        let bitmap = PlaylistWindowRenderer.render(.base, state)
        #expect(bitmap.width == 275 + 75)
        #expect(bitmap.height == 116 + 58)
        // The corners stay anchored whatever the size.
        let corner = try? #require(Skin.base.bitmap(.pledit))
        #expect(bitmap[bitmap.width - 1, bitmap.height - 1] == corner?[126 + 149, 72 + 37])
    }

    @Test func marqueeScrollsOnlyLongTitles() {
        #expect(Marquee.displayText("Short") == "Short" + String(repeating: " ", count: 26))
        let long = String(repeating: "x", count: 40)
        #expect(Marquee.displayText(long) == long + Marquee.separator + long)
        #expect(Marquee.offset(for: "Short", step: 5) == 0)
        #expect(Marquee.offset(for: long, step: 2) == 10)
        #expect(Marquee.offset(for: long, step: 47) == 0)  // wraps after title + separator
        #expect(Marquee.offset(for: long, step: 0, dragPixels: -5) == 47 * 5 - 5)
    }

    @Test func timeDigitsWrapLikeWinamp() {
        #expect(TimeDisplay(seconds: 3).digits == [0, 0, 0, 3])
        #expect(TimeDisplay(seconds: 754).digits == [1, 2, 3, 4])
        #expect(TimeDisplay(seconds: 100 * 60 + 5).digits == [0, 0, 0, 5])
    }
}
