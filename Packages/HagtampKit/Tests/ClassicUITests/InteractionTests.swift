import SkinKit
import Testing

@testable import ClassicUI

@Suite struct SliderTests {
    @Test func horizontalThumbAndValueRoundTrip() {
        let volume = MainWindowLayout.volume
        #expect(volume.thumbPosition(0) == 107)
        #expect(volume.thumbPosition(1) == 107 + 51)
        #expect(volume.thumbPosition(0.78) == 107 + 40)
        // Grabbing the thumb keeps the pointer where it held it.
        let grab = volume.grabOffset(pointer: 150, value: 0.78)
        #expect(grab == 150 - 147)
        #expect(abs(volume.value(pointer: 150, grab: grab) - 40.0 / 51) < 1e-9)
    }

    @Test func pressingTheTrackCentresTheThumb() {
        let volume = MainWindowLayout.volume
        #expect(volume.grabOffset(pointer: 110, value: 1) == 7)
        #expect(volume.value(pointer: 110, grab: 7) == 0)
        #expect(volume.value(pointer: 400, grab: 7) == 1)
    }

    @Test func verticalSlidersAreInverted() {
        let band = EqualizerWindowLayout.band
        #expect(band.thumbPosition(1) == 38)
        #expect(band.thumbPosition(0) == 38 + 51)
        #expect(band.value(pointer: 38 + 5, grab: 5) == 1)
    }
}

@Suite struct LayoutTests {
    @Test func buttonsWinOverTheTitleBar() {
        let regions = MainWindowLayout.regions(shade: false)
        #expect(regions.hit(x: 266, y: 5)?.control == .close)
        #expect(regions.hit(x: 100, y: 5)?.control == .titleBar)
        #expect(regions.hit(x: 50, y: 95)?.control == .play)
        #expect(regions.hit(x: 5, y: 100) == nil)  // body: easy move
    }

    @Test func playlistRegionsFollowTheSize() {
        let regions = PlaylistWindowLayout.regions(width: 350, height: 174, shade: false)
        #expect(regions.hit(x: 340, y: 165)?.control == .resize)
        #expect(regions.hit(x: 310, y: 150)?.control == .menu(.list))
        #expect(regions.hit(x: 15, y: 150)?.control == .menu(.add))
        #expect(regions.hit(x: 100, y: 60)?.control == .trackList)
    }

    @Test func menuItemsStackUpFromTheButton() {
        let bottom = PlaylistWindowLayout.menuItemRect(.add, item: 2, width: 275, height: 116)
        let top = PlaylistWindowLayout.menuItemRect(.add, item: 0, width: 275, height: 116)
        #expect(bottom == PixelRect(x: 14, y: 86, width: 22, height: 18))
        #expect(top.y == 86 - 36)
    }
}

@Suite struct DockingTests {
    let main = WindowBox(.main, x: 100, y: 100, width: 275, height: 116)
    let eq = WindowBox(.equalizer, x: 100, y: 216, width: 275, height: 116)
    let pl = WindowBox(.playlist, x: 100, y: 332, width: 275, height: 116)

    @Test func mainPullsTheDockedChain() {
        let loose = WindowBox(.playlist, x: 600, y: 600, width: 275, height: 116)
        #expect(WindowDocking.movingGroup(dragging: .main, windows: [main, eq, pl]) == [.main, .equalizer, .playlist])
        #expect(WindowDocking.movingGroup(dragging: .main, windows: [main, eq, loose]) == [.main, .equalizer])
        #expect(WindowDocking.movingGroup(dragging: .equalizer, windows: [main, eq, pl]) == [.equalizer])
    }

    @Test func draggingSnapsToNearbyEdges() {
        let screen = WindowBox(.main, x: 0, y: 0, width: 1920, height: 1080)
        // The playlist is dragged to 6 px right of the equalizer's right edge: it snaps flush.
        let moving = WindowBox(.playlist, x: 800, y: 216, width: 275, height: 116)
        let offset = WindowDocking.snappedOffset(moving: [moving], stationary: [main, eq], screens: [screen], dx: -419, dy: 3)
        #expect(offset.dx == -425)
        #expect(offset.dy == 0)
        // Near the screen's left edge.
        let edge = WindowDocking.snappedOffset(moving: [main], stationary: [], screens: [screen], dx: -95, dy: 0)
        #expect(edge.dx == -100)
    }

    @Test func shadingTheMainWindowPullsDockedWindowsUp() {
        let result = WindowDocking.reflow([main, eq, pl], newSizes: [.main: (275, 14)])
        #expect(result.map(\.y) == [100, 114, 230])
    }

    @Test func doubleSizeKeepsTheStackTogether() {
        let result = WindowDocking.reflow([main, eq, pl], newSizes: [.main: (550, 232), .equalizer: (550, 232), .playlist: (550, 232)])
        #expect(result.map(\.y) == [100, 332, 564])
        #expect(result.map(\.x) == [100, 100, 100])
    }
}

@Suite struct MarqueeTextTests {
    @Test func messages() {
        #expect(Marquee.volumeText(0.78) == "Volume: 78%")
        #expect(Marquee.balanceText(0) == "Balance: Center")
        #expect(Marquee.balanceText(-0.31) == "Balance: 31% Left")
        #expect(Marquee.seekText(position: 0.5, duration: 191) == "Seek to: 1:35/3:11 (50%)")
        #expect(Marquee.equalizerText(band: 0, value: 0.625) == "EQ: 60HZ +3.0 DB")
        #expect(Marquee.equalizerText(band: nil, value: 0.5) == "EQ: Preamp 0.0 DB")
    }
}

@Suite struct WindowRestoreTests {
    let screen = WindowBox(.main, x: 0, y: 25, width: 1440, height: 875)
    let main = WindowBox(.main, x: 100, y: 100, width: 275, height: 116)
    var equalizer: WindowBox { WindowBox(.equalizer, x: 100, y: 216, width: 275, height: 116) }

    @Test func windowsOnScreenStayPut() {
        let result = WindowDocking.restore([main, equalizer], screens: [screen], home: (80, 105))
        #expect(result.placed == [main, equalizer])
        #expect(result.unreachable.isEmpty)
    }

    @Test func aGroupFromAMissingScreenComesHomeTogether() {
        // Saved on a second screen to the right that is no longer attached.
        let away = [main.offsetBy(dx: 2000, dy: 0), equalizer.offsetBy(dx: 2000, dy: 0)]
        let result = WindowDocking.restore(away, screens: [screen], home: (80, 105))
        #expect(result.placed.map(\.x) == [80, 80])
        #expect(result.placed.map(\.y) == [105, 221])  // still docked
    }

    @Test func aStrayWindowIsReported() {
        let stray = WindowBox(.albumArt, x: 3000, y: 100, width: 275, height: 290)
        let result = WindowDocking.restore([main, stray], screens: [screen], home: (80, 105))
        #expect(result.placed == [main])
        #expect(result.unreachable == [.albumArt])
    }

    @Test func aTitleBarUnderTheMenuBarIsOutOfReach() {
        #expect(!WindowDocking.isReachable(WindowBox(.main, x: 100, y: 0, width: 275, height: 116), screens: [screen]))
        #expect(WindowDocking.isReachable(WindowBox(.main, x: 1420, y: 100, width: 275, height: 116), screens: [screen]) == false)
        #expect(WindowDocking.isReachable(WindowBox(.main, x: 1400, y: 100, width: 275, height: 116), screens: [screen]))
    }
}
