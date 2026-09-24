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
3. **Done** — audio on SFBAudioEngine (`AudioCore`): local files in every format SFB decodes, gapless queue honouring shuffle/repeat, Winamp transport semantics, seek, volume (squared curve), balance, 10-band EQ + preamp (peaking filters sized to band spacing, shelves at the ends), EQ presets (Winamp's 17 built-ins, user presets, `.eqf` load/save), visualizer (Nullsoft FFT analyzer with normal/fire/line, thick/thin, peaks, falloffs; oscilloscope dots/lines/solid; shade-mode mini vis) fed from a post-EQ pre-volume tap, file opening (eject, L, drag and drop, Finder). Volume/EQ/visualizer settings persist.
4. **Done** — playlist (`PlayerCore.Playlist` + `PlaylistFile`): Winamp 2 selection (click, Shift range from the anchor, ⌘ toggle), dragging the selection, keyboard (arrows, Shift/⌥ + arrows, Page/Home/End, Enter, Delete, ⌘A), ADD (URL/dir/file), REM (duplicates, dead files, all, crop, selected), SEL, MISC (sort by title/filename/path, reverse, randomize, file info, jump to file), LIST (new/save/load `m3u`/`m3u8`/`pls`), right-click menu, drop at position, follow current track, running time with "+", tags read in the background, unplayable entries skipped, the playing file keeps showing after removal, playlist restored on launch (`Application Support/Hagtamp/playlist.m3u8`). Deferred: HTML playlist, tag editing in file info, "enqueue" in Jump to file. Deleting files from disk is deliberately not offered.
   Also done after stage 4: optional Album Art window (generic GEN.BMP frame, cover from the track's folder — cover/folder/front… — or embedded in its tags), EQ preset menu fix, no Winamp/Nullsoft branding in the UI, default skin retitled "HAGTAMP" (`scripts/retitle_base_skin.py`).
5. Navidrome client + cache + Media Library window (reuses the generic window frame).
6. Polish: Winamp main menu, hotkeys, preferences, skin browser, media keys / Now Playing, Milkdrop (projectM) maybe.

## TODO / known issues

- [x] Dragging the main window moves the docked equalizer/playlist along, but they could end up behind other apps' windows (only the clicked window was raised). Fixed: a click on any window raises all of them (`WindowManager.raiseAll`).

## Licensing notes

- The bundled default skin is Nullsoft's Winamp 2.91 base skin with the title lettering redrawn. Fine for personal use; a public release should ship an original default skin.
- SFBAudioEngine is MIT, but some of its decoders are LGPL (mpg123, LAME, Musepack, libsndfile). Fine for an open-source app; distributing a closed build means honouring LGPL relinking terms or dropping those decoders.

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
- Visualizer: analyzer bar colours and the 2 px "push down" come from Webamp; Webamp's fire style used the background colour for bar tips, we start at colour 2. Is the vis area drawn while stopped?
- Volume curve (we use amplitude = slider²) and the EQ filter shapes vs. Winamp's actual equalizer.
- Streaming (stage 5): SFBAudioEngine's `InputSource` can't be subclassed from Swift; progressive playback of a growing cache file needs another route (custom `PCMDecoding`, or AudioToolbox for transcoded streams).
