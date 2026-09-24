# Plan

Goal: a macOS player that looks and behaves like Winamp 2.x with classic skins, playing local files and Navidrome (Subsonic API), with caching designed in from the start.

## Decisions

- macOS only, Swift 6 + AppKit, macOS 14+. SwiftUI only for plain dialogs (preferences).
- Classic skins (`.wsz`) only. Modern skins (`.wal`, MAKI) are out of scope.
- Audio: SFBAudioEngine (MIT) on AVAudioEngine — gapless, wide format support; AVAudioUnitEQ for the 10-band EQ + preamp; vDSP FFT for the visualizer.
- Storage: GRDB (SQLite) for the local library index, Navidrome metadata cache and the audio cache index.
- Streaming = caching: Navidrome tracks are downloaded (HTTP Range) into the cache while the player reads the same file; complete files stay cached (LRU with size limit, pinned albums/playlists are never evicted). Offline mode browses the DB and plays cached tracks.
- Navidrome browsing lives in a Media Library window skinned with GEN.BMP/GENEX.BMP, like Winamp 5.
- References: Webamp source = spec for sprite coordinates/layout; Reamp (`reamp/`) and Winamp itself = reference for behaviour. Targeted reverse engineering of Reamp only for specific questions.

## Stages

0. **Done** — clean repo, XcodeGen project, `HagtampKit` package, Makefile.
1. **Done** — `SkinKit` + static rendering of main/EQ/playlist windows, golden comparison against Skin Museum screenshots (`make compare`).
2. **Done** — window system: hit-testing and pressed states for every control, sliders (incl. EQ band sweeping), window shapes from `region.txt` (transparent pixels click through), easy move, snapping to windows and screen edges, main window pulling its docked windows, docked windows following shade/double-size/resize changes, shade modes for all windows, playlist resize and bottom menus, skin cursors (`.cur`/`.ani`), Winamp keys Z X C V B and arrows. Playback is simulated by `PlayerModel` until stage 3.
3. Audio: local playback, live main window (time, marquee scrolling, kbps/kHz, seek), EQ (presets, `.eqf`), visualizer (spectrum/oscilloscope with all options).
4. Playlist: selection, drag reordering, scrolling, resize, ADD/REM/SEL/MISC/LIST menus, sorting, `m3u`/`pls`, Jump to file.
5. Navidrome client + cache + Media Library window.
6. Polish: Winamp main menu, hotkeys, preferences, skin browser, media keys / Now Playing, Milkdrop (projectM) maybe.

## Skin format findings

Collected while matching the museum screenshots; keep adding.

- Config files use CRLF — split on `Character.isNewline` (`"\r\n"` is one Swift `Character`).
- RLE8/RLE4 bitmaps: pixels skipped by end-of-line/end-of-bitmap/delta keep palette index 0. Deltas move right *and down* from the current position (ImageIO gets this wrong, so we decode BMP ourselves).
- 32-bit BMPs: alpha is ignored (GDI).
- Missing BALANCE.BMP → balance slider uses the skin's own VOLUME.BMP (not the base skin's balance).
- NUMS_EX.BMP overrides NUMBERS.BMP and is never inherited from the base skin.
- Marquee is 155 px wide (31 glyphs); museum screenshots disagree on the last column.
- `region.txt`: values may carry trailing `;comments` (Winamp's atoi still reads the number, Webamp drops the section); all polygons of a section form one region with non-zero winding, so hole polygons cut holes (Webamp unions them).
- Cursor files come with sloppy headers (non-zero reserved field, cursors typed as icons with the hotspot in the planes/bit-count fields); load them like Windows does.

## Open questions (verify against Reamp / Winamp)

- Is the blank "no minus" glyph drawn in elapsed mode? (We draw it; Webamp doesn't.)
- EQ graph: exact curve algorithm and preamp line direction (Webamp's is an approximation; Reamp has `EqGraphThingy`).
- Region fill rule: WINDING vs ALTERNATE for overlapping polygons.
- Playlist font rendering: size, antialiasing, vertical position; Retina text (1x bitmap font look vs crisp text).
- kbps/kHz alignment for values that are not 3/2 digits long (we right-align).
- Balance slider: does Winamp snap to center near the middle?
- EQ shade slider thumbs: vertical position (we use y = 4).
- Playlist menus: exact press/release behaviour (we: press-drag-release picks, a plain click keeps the menu open).
