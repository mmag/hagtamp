# Hagtamp

Native macOS music player that reproduces Winamp 2.x (classic `.wsz` skins, as faithful to the original as possible) with Navidrome and local files as sources. Plan and status: `docs/PLAN.md`.

## Layout

- `App/Sources` — AppKit app (borderless skinned windows). Both library windows are `LibraryWindowController` over a `LibrarySource` (`LocalLibraryService`, `NavidromeService` in `NavidromeLibrary.swift`). Winamp's main menu and keys: `MainMenu.swift`, `WindowManager.handleKey`; media keys and Now Playing: `NowPlaying`; skins folder and browser: `SkinLibrary`. Xcode project is generated from `project.yml` by XcodeGen; `*.xcodeproj` is not committed.
- `Packages/HagtampKit` — Swift package with the testable core:
  - `SkinKit` — skin loading: zip/folder access, BMP decoder, sprite table, `pledit.txt`/`viscolor.txt`/`region.txt`, TEXT.BMP font, base-skin fallback.
  - `ClassicUI` — `Rendering/`: pure functions `state -> Bitmap` for the main, equalizer and playlist windows (normal and shade); `Interaction/`: control hit areas, slider geometry, window docking/snapping math; `Visualization/`: Winamp's analyzer/oscilloscope; `ReferenceScene` + `ImageDiff` for golden comparisons.
  - `PlayerCore` — player domain without dependencies: `TrackInfo`, `Playlist` (order, Winamp selection, editing), `PlaylistFile` (m3u/m3u8/pls), `Lyrics` (LRC and plain), equalizer presets, `.eqf` files.
  - `NavidromeKit` — Subsonic API client (`NavidromeClient`, response cache), `AudioCache` (LRU track cache; `stream` downloads into `<name>.part`, shared between playback and prefetch, renamed when complete), `NavidromeTrack` (`hagtamp-nd://song/<id>` playlist URLs).
  - `LibraryKit` — local library: `LocalLibrary` (actor: scans folders, rereads only changed files, JSON index), `LibraryCatalog` (artists / albums / tracks grouping, search), `LibraryEntry` (tags of one file), `FolderWatcher` (FSEvents).
  - `StreamingInput` — Objective-C: `StreamingInputSource` (SFB input source reading a file that is still downloading; unseekable until complete), `LiveInputSource` (internet radio, fed from memory), `AudioStreamDecoder` (AAC streams via AudioFileStream + AudioConverter) and `PositionedDecoder` (starts a decoder part way through, opened on the player's thread).
  - `AudioCore` — playback on SFBAudioEngine: `AudioEngine` (gapless queue of files, `StreamingTrack`s and `LiveStream`s, EQ, balance, volume, visualizer sample tap), `LiveStream` (radio: HTTP, ICY titles, .pls/.m3u), `TrackInfo.read` (tags/properties).
  - `Milkdrop` — MilkDrop presets without the GPU: `MilkdropPreset` (.milk), `EELProgram` (the expression language compiled to closures), `MilkdropEngine` (one preset's frame: warp mesh, waves, shapes, borders, composite), `MilkdropSession` (switches with blending, sound analysis). `MilkdropMetal` — `MilkdropRenderer`, the Metal passes (shader source compiled at run time). Both build with `-O` even in debug (preset code runs thousands of times a frame); the app draws them on a render thread paced by `CAMetalDisplayLink` (`VisualizationWindowController`).
  - `skintool` — CLI: `info`, `render`, `sheets` (decoded bitmaps as PNG), `gen` (generic window preview), `compare`.
- `skins/` — test skins (`winamp.wsz` = the original Winamp 2.91 base skin, used by golden checks). The app's default skin is `SkinKit/Resources/hagtamp-base.wsz`, generated from it by `scripts/retitle_base_skin.py` (title lettering "HAGTAMP", Hagtamp logo on the about button, an H on the menu button).
- `art/` — the logo as pixel art, drawn by `scripts/make_logo.py`, which also builds the app icon (`App/Assets.xcassets/AppIcon.appiconset`). Edit the script, not the PNGs; then rerun `retitle_base_skin.py` for the skin's copy.
- `.corpus/` — ~300 Skin Museum skins + reference screenshots (git-ignored, `make corpus`).

## Commands

- `make test` — package tests (Swift Testing).
- `make app` / `make run` — generate the Xcode project, build, launch.
- `HAGTAMP_SELFTEST=<dir> [HAGTAMP_SELFTEST_SKIN=<skin>] build/DerivedData/Build/Products/Debug/Hagtamp.app/Contents/MacOS/Hagtamp` — debug builds play two generated tones silently (time, visualizer, gapless handover) and walk through the UI (buttons, shade, resize, double size, docking), write a snapshot per step and quit. `AudioCoreTests` also play audio, at zero volume.
- `scripts/navidrome_dev.sh` — local Navidrome (http://localhost:4533, admin/admin) with a generated test library; `NavidromeKitTests` live tests and the self test's Navidrome steps run when it is up. Localhost downloads finish before playback starts; to exercise streaming, put a throttling proxy in front and set `HAGTAMP_SELFTEST_NAVIDROME=http://localhost:<port>` (the self test logs `seekable=false` when a track started as a stream).
- `make screenshots` — the README's pictures in `docs/screenshots`: the self test's isolated app plays a made-up library (`Screenshots.swift`: invented artists, synthesized music, generated covers, engine muted) and captures its windows.
- `make corpus` then `make compare` — render every corpus skin in the museum screenshot state and diff against the screenshots; visual diffs land in `.artifacts/compare` (reference | ours | diff).

mpg123's per-decoder setup isn't thread-safe: open decoders only on SFB's decoding thread (the app does), and keep tests that open MP3 decoders serialized.

App state lives in `Storage`: UserDefaults, `~/Library/Application Support/Hagtamp` (playlist, library index, login token, skins, music kept offline in `Offline/`) and `~/Library/Caches/Hagtamp` (audio cache, covers, server responses: all fetchable again). The self test swaps all three for its own so it never touches the user's state.

No Winamp/Nullsoft branding in anything the user sees (menus, texts, default skin); code comments may reference Winamp as the behavioural reference.

## Conventions

- Rendering is done in our own `Bitmap` (premultiplied ARGB, top-left origin) by blitting sprites, at 1x skin pixels; windows scale it with nearest-neighbour filtering. Keep renderers free of AppKit so they stay testable.
- Winamp behaviour is the reference, Webamp source (MIT) is the spec for sprite coordinates and layout. Where they disagree, follow Winamp and document the deviation (see `ReferenceScene.volatileRects`, `webampBugs` in skintool).
- Skin files are messy: parse leniently, never crash on a bad skin, fall back to the base skin per bitmap.
- Swift 6 strict concurrency, macOS 14+.
