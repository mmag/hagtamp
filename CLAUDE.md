# Hagtamp

Native macOS music player that reproduces Winamp 2.x (classic `.wsz` skins, as faithful to the original as possible) with Navidrome and local files as sources. Plan and status: `docs/PLAN.md`.

## Layout

- `App/Sources` — AppKit app (borderless skinned windows). Xcode project is generated from `project.yml` by XcodeGen; `*.xcodeproj` is not committed.
- `Packages/HagtampKit` — Swift package with the testable core:
  - `SkinKit` — skin loading: zip/folder access, BMP decoder, sprite table, `pledit.txt`/`viscolor.txt`/`region.txt`, TEXT.BMP font, base-skin fallback.
  - `ClassicUI` — `Rendering/`: pure functions `state -> Bitmap` for the main, equalizer and playlist windows (normal and shade); `Interaction/`: control hit areas, slider geometry, window docking/snapping math; `Visualization/`: Winamp's analyzer/oscilloscope; `ReferenceScene` + `ImageDiff` for golden comparisons.
  - `PlayerCore` — player domain without dependencies: `TrackInfo`, `Playlist` (order, Winamp selection, editing), `PlaylistFile` (m3u/m3u8/pls), equalizer presets, `.eqf` files.
  - `AudioCore` — playback on SFBAudioEngine: `AudioEngine` (gapless queue, EQ, balance, volume, visualizer sample tap), `TrackInfo.read` (tags/properties).
  - `skintool` — CLI: `info`, `render`, `sheets` (decoded bitmaps as PNG), `gen` (generic window preview), `compare`.
- `skins/` — test skins (`winamp.wsz` = the original Winamp 2.91 base skin, used by golden checks). The app's default skin is `SkinKit/Resources/hagtamp-base.wsz`, generated from it by `scripts/retitle_base_skin.py` (title lettering "HAGTAMP").
- `reamp/` — Reamp.app, closed-source reference player (git-ignored). Use it to check Winamp behaviour, don't copy from it.
- `.corpus/` — ~300 Skin Museum skins + reference screenshots (git-ignored, `make corpus`).

## Commands

- `make test` — package tests (Swift Testing).
- `make app` / `make run` — generate the Xcode project, build, launch.
- `HAGTAMP_SELFTEST=<dir> [HAGTAMP_SELFTEST_SKIN=<skin>] build/DerivedData/Build/Products/Debug/Hagtamp.app/Contents/MacOS/Hagtamp` — debug builds play two generated tones silently (time, visualizer, gapless handover) and walk through the UI (buttons, shade, resize, double size, docking), write a snapshot per step and quit. `AudioCoreTests` also play audio, at zero volume.
- `make corpus` then `make compare` — render every corpus skin in the museum screenshot state and diff against the screenshots; visual diffs land in `.artifacts/compare` (reference | ours | diff).

App state lives in `Storage` (UserDefaults + `~/Library/Application Support/Hagtamp`); the self test swaps both for its own so it never touches the user's settings or playlist.

No Winamp/Nullsoft branding in anything the user sees (menus, texts, default skin); code comments may reference Winamp as the behavioural reference.

## Conventions

- Rendering is done in our own `Bitmap` (premultiplied ARGB, top-left origin) by blitting sprites, at 1x skin pixels; windows scale it with nearest-neighbour filtering. Keep renderers free of AppKit so they stay testable.
- Winamp behaviour is the reference, Webamp source (MIT) is the spec for sprite coordinates and layout. Where they disagree, follow Winamp and document the deviation (see `ReferenceScene.volatileRects`, `webampBugs` in skintool).
- Skin files are messy: parse leniently, never crash on a bad skin, fall back to the base skin per bitmap.
- Swift 6 strict concurrency, macOS 14+.
