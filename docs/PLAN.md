# Plan

Goal: a macOS player that looks and behaves like Winamp 2.x with classic skins, playing local files and Navidrome (Subsonic API), with caching designed in from the start.

## Decisions

- macOS only, Swift 6 + AppKit, macOS 14+. SwiftUI only for plain dialogs (preferences).
- Classic skins (`.wsz`) only. Modern skins (`.wal`, MAKI) are out of scope.
- Audio: SFBAudioEngine (MIT) on AVAudioEngine — gapless, wide format support; AVAudioUnitEQ for the 10-band EQ + preamp; vDSP FFT for the visualizer.
- Storage: plain files. The local library index is JSON (`library.json`, loaded into memory, grouped by `LibraryCatalog`), Navidrome responses are cached as JSON, and the audio cache is files whose modification date is their last use. GRDB/SQLite only if libraries outgrow memory.
- Streaming = caching: Navidrome tracks are downloaded into the cache while the player reads the same file; complete files stay cached (LRU with size limit, pinned albums/playlists are never evicted). Offline mode browses cached responses and plays cached tracks.
- Libraries are browsed in skinned windows (GEN.BMP/GENEX.BMP, like Winamp 5's media library): one for the local files, one for Navidrome, same controller over a `LibrarySource`.
- References: Webamp source = spec for sprite coordinates/layout; Reamp (`reamp/`) and Winamp itself = reference for behaviour. Targeted reverse engineering of Reamp only for specific questions.

## Stages

0. **Done** — clean repo, XcodeGen project, `HagtampKit` package, Makefile.
1. **Done** — `SkinKit` + static rendering of main/EQ/playlist windows, golden comparison against Skin Museum screenshots (`make compare`).
2. **Done** — window system: hit-testing and pressed states for every control, sliders (incl. EQ band sweeping), window shapes from `region.txt` (transparent pixels click through), easy move, snapping to windows and screen edges, main window pulling its docked windows, docked windows following shade/double-size/resize changes, shade modes for all windows, playlist resize and bottom menus, skin cursors (`.cur`/`.ani`), Winamp keys Z X C V B and arrows. Playback is simulated by `PlayerModel` until stage 3.
3. **Done** — audio on SFBAudioEngine (`AudioCore`): local files in every format SFB decodes, gapless queue honouring shuffle/repeat, Winamp transport semantics, seek, volume (squared curve), balance, 10-band EQ + preamp (peaking filters sized to band spacing, shelves at the ends), EQ presets (Winamp's 17 built-ins, user presets, `.eqf` load/save), visualizer (Nullsoft FFT analyzer with normal/fire/line, thick/thin, peaks, falloffs; oscilloscope dots/lines/solid; shade-mode mini vis) fed from a post-EQ pre-volume tap, file opening (eject, L, drag and drop, Finder). Volume/EQ/visualizer settings persist.
4. **Done** — playlist (`PlayerCore.Playlist` + `PlaylistFile`): Winamp 2 selection (click, Shift range from the anchor, ⌘ toggle), dragging the selection, keyboard (arrows, Shift/⌥ + arrows, Page/Home/End, Enter, Delete, ⌘A), ADD (URL/dir/file), REM (duplicates, dead files, all, crop, selected), SEL, MISC (sort by title/filename/path, reverse, randomize, file info, jump to file), LIST (new/save/load `m3u`/`m3u8`/`pls`), right-click menu, drop at position, follow current track, running time with "+", tags read in the background, unplayable entries skipped, the playing file keeps showing after removal, playlist restored on launch (`Application Support/Hagtamp/playlist.m3u8`). Deferred: HTML playlist, tag editing in file info, "enqueue" in Jump to file. Deleting files from disk is deliberately not offered.
   Also done after stage 4: optional Album Art window (generic GEN.BMP frame, cover from the track's folder — cover/folder/front… — or embedded in its tags), EQ preset menu fix, no Winamp/Nullsoft branding in the UI, default skin retitled "HAGTAMP" (`scripts/retitle_base_skin.py`). Logo and app icon: pixel-art H with a lightning bolt on a silver diamond (`scripts/make_logo.py`, `art/`), also on the main window's about button in place of the Winamp bolt.
5. **Done** — Navidrome: `NavidromeKit` (Subsonic API client with token auth, on-disk response cache for offline browsing, `AudioCache` with LRU eviction), Preferences window (server, login saved as a Subsonic token in `credentials.json`, not the password, stream quality incl. MP3 transcoding, cache limit/clear), playing Navidrome songs (progressive: MP3/FLAC/Opus start after 256 KB with "Buffering: N%" and keep downloading into the cache, other formats wait for the whole file; next track prefetched for gapless playback, covers, scrobbling), skinned library window titled "Navidrome" (GEN/GENEX: sidebar Library / Favourites / Recently Added / Playlists / Radio, search, artist + album lists over the track list, Play/Enqueue, keyboard). Dev server: `scripts/navidrome_dev.sh`.
6. Polish: Winamp main menu, hotkeys, preferences, skin browser, media keys / Now Playing, Milkdrop (projectM) maybe.

## TODO / known issues

- [x] Dragging the main window moves the docked equalizer/playlist along, but they could end up behind other apps' windows (only the clicked window was raised). Fixed: a click on any window raises all of them (`WindowManager.raiseAll`).

- [x] Progressive streaming. `StreamingInput` (Objective-C, since SFBAudioEngine's `InputSource` can't be subclassed from Swift) reads the growing `.part` file and waits for bytes. It is unseekable until the download completes, because mpg123 scans a whole seekable file and opusfile reads its last page before playing. So a stream can't seek until it is downloaded; after that, seeking reopens the cached file at the position (`PositionedDecoder`). Ogg Vorbis and MP4/M4A still wait for the whole file: SFB's Vorbis seek callback reports failures as successes, and MP4 may keep its index at the end.
- [ ] "Keep offline" pinning of albums/playlists (never evicted from the cache).
- [x] Internet radio: http(s) entries (playlist ADD > URL, Navidrome's radio stations) play live (`LiveStream`: .pls/.m3u links resolved, ICY song titles in the marquee, AAC through Audio Toolbox's stream parser since SFB's AAC decoder needs a whole file). A station after a track starts when the track ends (endless streams can't be queued gaplessly). Not supported: HLS (.m3u8).
- [x] Local library window: folders chosen in Preferences, scanned in the background (`LibraryKit`: tags read only for new or changed files, index kept in `library.json`), Audio (artists | albums | tracks, compilations without album artist tags become "Various Artists") and Recently Added views, search, Play/Enqueue. Not yet: watching folders for changes (rescan on launch or from Preferences), Most Played / Never Played (needs play counts).
- [x] Window layout across launches (`WindowManager.saveLayout`): positions, visibility, shade, sizes, library views, double size, always on top, time mode; windows from a screen that is gone come back with the main window (`WindowDocking.restore`). Optionally the position in the current track (Preferences > Playback): saved every 5 s and on quit, forgotten on Stop.

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
- Streaming: seeking past the downloaded part of a stream isn't possible (it would need HTTP Range requests into a sparse file). An MP3 whose LAME header promises more frames than it holds fails at its very end when streamed, because only a whole-file scan corrects the count; files from LAME and ffmpeg are fine.
