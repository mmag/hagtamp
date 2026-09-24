# Third-party notices

## Webamp

Sprite coordinates, window layout and several skin-parsing rules in
`Packages/HagtampKit/Sources/SkinKit` and `Packages/HagtampKit/Sources/SkinRenderer`
are derived from Webamp (https://github.com/captbaritone/webamp).

    The MIT License (MIT)

    Copyright (c) 2015 Jordan Eldredge

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

The visualizer (`ClassicUI/Visualization`) ports Webamp's VisPainter.ts and
FFTNullsoft.ts; the FFT originates from Nullsoft's MilkDrop (via WACUP's
vis_classic). The built-in equalizer presets and the `.eqf` test fixtures
(`Tests/PlayerCoreTests/Fixtures`, including Winamp's `winamp.q1`) come from
Webamp's `winamp-eqf` package.

## SFBAudioEngine

https://github.com/sbooth/SFBAudioEngine — MIT License, Copyright (c) 2006-2026 Stephen F. Booth.
It pulls in third-party codecs under their own licenses, some of them LGPL
(mpg123, LAME, Musepack, libsndfile); see the SFBAudioEngine repository.

## ZIPFoundation

https://github.com/weichsel/ZIPFoundation — MIT License, Copyright (c) 2017-2024 Thomas Zoechling.

## Winamp base skin

`skins/winamp.wsz` and `SkinKit/Resources/base-2.91.wsz` are the Winamp 2.91 base skin by Nullsoft.
