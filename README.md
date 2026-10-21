# Project Ameya

A native macOS file converter and toolbox. Drop files on it, pick what you want, get a new file.
Everything happens on your Mac: no account, no uploads, no limits.

> **Status: early development.** Plenty already works (see below), but expect rough edges.

## What it converts

Images (HEIC, WebP, AVIF, RAW, SVG and more), PDFs, Word/RTF/ODT/HTML documents, Markdown, e-books
and comics, audio and video (including MKV, WebM, Ogg and Opus), subtitles, CSV/JSON/XML data,
archives and compressed files, 3D models, SQLite, contacts, GPS tracks and QR codes, plus tools such
as resizing, stripping metadata and on-device transcription.

- Exactly what works today: [roadmap → Working today](docs/ROADMAP.md#working-today)
- Everything we could add, with licences: [format catalogue](docs/FORMAT-CATALOGUE.md)

## Install

Download `Ameya-<version>.zip` from [Releases](https://github.com/sahilxnahar/project-ameya/releases),
unzip it and move **Ameya.app** to Applications. Requires macOS 14 or later (Apple silicon or Intel).

Ameya is ad-hoc signed and **not notarized yet**, so macOS will block the first launch. To open it:

- **Right-click** (or Control-click) Ameya.app → **Open** → **Open**, or
- try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only need to do this once. `SHA256SUMS.txt` on each release lets you check the download.

## Private by design

**Ameya never uses the network — enforced by tests.** The app and its worker have no network
entitlements, and the test suite fails if networking code or entitlements creep in. Each conversion
runs in a separate, sandboxed worker process that can only see the file you gave it, so a bad file
can't crash the app, Cancel really stops the work, and your originals are never changed.

## Build from source

Requires macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/sahilxnahar/project-ameya.git
cd project-ameya
swift test                    # run the test suite
./scripts/build-app.sh        # builds dist/Ameya.app (universal; NATIVE=1 for this Mac only)
open dist/Ameya.app
```

Optional: `./scripts/build-ffmpeg.sh` builds the LGPL FFmpeg helper (needs `pkg-config`:
`brew install pkgconf`; takes a while). Without it, Ogg, Opus, MP3 output, MKV, WebM and AVI aren't
offered and everything else works. Run it before `build-app.sh` to include the helper.

| Path | What it is |
|---|---|
| `Sources/AmeyaCore` | Formats, capability matrix, output naming, worker protocol |
| `Sources/AmeyaEngines` | Conversion engines (run only inside the worker) |
| `Sources/AmeyaWorker` | The sandboxed helper process, one per job |
| `Sources/Ameya` | The menu bar app |
| `Tests` | Unit and integration tests |
| `Resources`, `scripts` | Info.plists, entitlements, build and packaging scripts |

## Licences

Ameya is open source under the [Mozilla Public License 2.0](LICENSE). It includes third-party
components (libwebp, and an LGPL build of FFmpeg with LAME, libvpx, Opus and Vorbis in a separate
helper); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Every release also carries the exact
source of the FFmpeg helper.

Contributions are welcome. Please don't paste code from GPL-licensed projects; Ameya must stay
licence-clean.
