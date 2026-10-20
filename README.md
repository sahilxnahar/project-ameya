# Project Ameya

A native macOS file converter and toolbox. Drag files, pick an action, get a new file.
Everything runs on your Mac: no account, no upload, no usage limits.

> **Status: early development (M1 — Core formats).** Converts images, PDFs, Word/RTF/ODT/HTML
> documents, audio, video and subtitles. Not ready for everyday use yet.
> See the [roadmap](docs/ROADMAP.md) for exactly what works today and what's planned.

## Why another converter

- **Never freezes.** Conversions run in a separate sandboxed worker process. Cancel really stops the work, and a bad file can't crash the app.
- **Never touches your originals.** Every action writes a new file.
- **Private.** No network access for file processing. Smart features (OCR, background removal, transcription) run on-device.
- **Open source** under the [Mozilla Public License 2.0](LICENSE).

## Build from source

Requires macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/sahilxnahar/project-ameya.git
cd project-ameya
swift test                 # run the test suite
./scripts/build-app.sh     # builds dist/Ameya.app
open dist/Ameya.app
```

Local builds are ad-hoc signed and not notarized.

## Project layout

| Path | What it is |
|---|---|
| `Sources/AmeyaCore` | Formats, capability matrix, jobs, output naming, worker protocol |
| `Sources/AmeyaEngines` | Conversion engines (run inside the worker) |
| `Sources/AmeyaWorker` | Sandboxed helper process, one per job, that performs conversions |
| `Sources/Ameya` | The menu bar app |
| `Tests` | Unit and integration tests |
| `Resources` | Info.plists and entitlements for the app bundle |
| `scripts` | Build and packaging scripts |

## Contributing

Contributions are welcome. Please don't paste code from GPL-licensed projects;
this project is MPL-2.0 and must stay licence-clean (see the roadmap's principles).
