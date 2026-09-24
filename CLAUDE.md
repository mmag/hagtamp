# Hagtamp

Native macOS music player that reproduces Winamp 2.x (classic `.wsz` skins, as faithful to the original as possible) with Navidrome and local files as sources. Plan and status: `docs/PLAN.md`.

## Layout

- `App/Sources` — AppKit app (borderless skinned windows). Xcode project is generated from `project.yml` by XcodeGen; `*.xcodeproj` is not committed.
- `Packages/HagtampKit` — Swift package with the testable core:
  - `SkinKit` — skin loading: zip/folder access, BMP decoder, sprite table, `pledit.txt`/`viscolor.txt`/`region.txt`, TEXT.BMP font, base-skin fallback.
  - `SkinRenderer` — pure functions `state -> Bitmap` for the main, equalizer and playlist windows; `ReferenceScene` + `ImageDiff` for golden comparisons.
  - `skintool` — CLI: `info`, `render`, `compare`.
- `skins/` — test skins (`winamp.wsz` = Winamp 2.91 base skin, also bundled as `SkinKit/Resources/base-2.91.wsz`).
- `reamp/` — Reamp.app, closed-source reference player (git-ignored). Use it to check Winamp behaviour, don't copy from it.
- `.corpus/` — ~300 Skin Museum skins + reference screenshots (git-ignored, `make corpus`).

## Commands

- `make test` — package tests (Swift Testing).
- `make app` / `make run` — generate the Xcode project, build, launch.
- `make corpus` then `make compare` — render every corpus skin in the museum screenshot state and diff against the screenshots; visual diffs land in `.artifacts/compare` (reference | ours | diff).

## Conventions

- Rendering is done in our own `Bitmap` (premultiplied ARGB, top-left origin) by blitting sprites, at 1x skin pixels; windows scale it with nearest-neighbour filtering. Keep renderers free of AppKit so they stay testable.
- Winamp behaviour is the reference, Webamp source (MIT) is the spec for sprite coordinates and layout. Where they disagree, follow Winamp and document the deviation (see `ReferenceScene.volatileRects`, `webampBugs` in skintool).
- Skin files are messy: parse leniently, never crash on a bad skin, fall back to the base skin per bitmap.
- Swift 6 strict concurrency, macOS 14+.
