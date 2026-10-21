# Project Ameya — Roadmap

A native macOS file converter and toolbox. Drag files, pick an action, get a new file.
Everything runs on the Mac: no account, no upload, no usage limits. Licensed MPL-2.0.

Priorities: **P0** ships in v1.0 · **P1** follows in v1.x · **P2** later or exploratory.
Status: ✅ done · 🚧 in progress · ⬜ not started.

## Principles

1. **Originals are never modified.** Every job writes a new file. A checksum proves the source is unchanged.
2. **The interface never freezes.** All file work runs in a separate sandboxed worker process with time and memory limits. Cancel kills the worker; a crash fails one job, not the app.
3. **Everything stays on this Mac.** No network access at all: no accounts, no servers, no uploads, no downloads. The app and its workers have no network permission, and a test enforces it. Smart features use models already on the Mac.
4. **Honest output.** If a conversion loses something (transparency, layers, pages, quality), the app says so before it runs.
5. **Tested on real files.** Every engine ships with fixtures and round-trip tests. CI runs on every push.
6. **Licence-clean.** MPL-2.0 project code. No GPL code. Satsuma (MIT) may be reused with credit. FFmpeg only as an LGPL build without GPL encoders; H.264/HEVC encoding uses Apple VideoToolbox.

## Architecture

| Part | Responsibility |
|---|---|
| `Ameya` (app) | Menu bar, drop window, drag wheel, settings, job list. Sandboxed. Owns file access. |
| `AmeyaWorker` (helper process) | Does the actual conversion. **One fresh process per job**, inheriting the app's sandbox. It never opens files by path: the app hands it the source as a read-only stdin and a hidden temporary file as stdout. A hang, crash or runaway job affects only that job; cancel and timeout kill it instantly. |
| `AmeyaCore` | Format registry, capability matrix, output naming, worker protocol and runner. Pure Swift, fully unit-tested. |
| `AmeyaEngines` | Conversion engines (ImageIO, PDFKit, AVFoundation, Vision, textutil, libarchive, LGPL FFmpeg). Run inside the worker. |

Targets macOS 14 Sonoma or later, universal binary (Apple silicon + Intel). Features that need newer
macOS versions (e.g. on-device language models on macOS 26) are switched on only where available.

## Milestones

| # | Milestone | Exit criteria | Status |
|---|---|---|---|
| M0 | Foundation | Package builds, sandboxed app + per-job worker, job engine with timeout/cancel, image conversion end-to-end, tests and CI green | ✅ |
| M1 | Core formats | Images, PDF, audio/video, documents, subtitles, archives with fixture tests | 🚧 (see "Working today" below) |
| M2 | Ways in | Global drag wheel, menu bar, command palette, Finder actions, Shortcuts, Services, CLI | ⬜ |
| M3 | Tools | Image, video, audio, PDF and file tools (below) | ⬜ |
| M4 | Smart features | OCR, background removal, transcription, translation, smart redaction | ⬜ |
| M5 | Workflows | Recipes, goal presets, undo/history, watch folders, shelf | ⬜ |
| M6 | Reach | iPhone/iPad app + Share extension, plug-ins, localisation | ⬜ |
| M7 | Release | Notarized builds (needs Apple Developer account), auto-update, accessibility audit, website | ⬜ |

## Features

### Foundation and trust

| Feature | Priority | Status |
|---|---|---|
| Sandboxed app + one sandboxed worker process per job, no file paths | P0 | ✅ |
| Job queue: parallel jobs, progress, per-job timeout, hard cancel, crash isolation | P0 | ✅ |
| Safe output: never overwrite (RENAME_EXCL), unique names, atomic write, source opened read-only | P0 | ✅ |
| Save to Downloads/Ameya | P0 | ✅ |
| Save beside the original (sandbox "related items") or a chosen folder | P0 | 🚧 |
| Capability matrix: only offer conversions this Mac can do; warn about losses before converting | P0 | ✅ |
| Animated and multi-page images handled frame by frame; EXIF orientation applied | P0 | ✅ |
| Decompression-bomb guard (pixel and frame limits checked before decoding) | P0 | ✅ |
| Privacy check before sharing: show hidden metadata, remove in one click | P0 | ⬜ |
| Large real-world fixture corpus + fuzzing of every parser | P1 | ⬜ |

### Ways in

| Feature | Priority | Status |
|---|---|---|
| Menu bar icon + drop window (basic; design pass pending) | P0 | 🚧 |
| Global drag wheel (hold Shift/Command/Control while dragging), remappable keys | P0 | ⬜ |
| Keyboard command palette (full keyboard and VoiceOver access) | P0 | ⬜ |
| Finder right-click Quick Actions + macOS Services | P0 | 🚧 |
| Shortcuts / App Intents for every action | P0 | ⬜ |
| Suggested actions: likeliest actions for this file shown first | P1 | ⬜ |
| Clipboard conversion: convert what's copied, paste the result | P1 | ✅ |
| `ameya` command-line tool | P1 | ⬜ |
| Local MCP server so AI agents can convert files on the Mac | P1 | ⬜ |
| Shelf: collect files from several places, then act | P1 | ⬜ |
| Raycast / Alfred extensions | P2 | ⬜ |

### Image tools

| Feature | Priority | Status |
|---|---|---|
| Compress (quality or target size), resize, crop, rotate/flip | P0 | ⬜ |
| Edit (exposure, contrast, saturation, …) with hold-to-compare | P0 | ⬜ |
| Redact (blur, pixelate, solid) + auto-detect faces and number plates | P0 | ⬜ |
| Background removal (on-device) and cut-out sticker with outline | P0 | ⬜ |
| Add background / frame, screenshot beautifier (shadow, corners, device frame) | P0 | ⬜ |
| Annotate: arrows, boxes, text, numbered steps | P1 | ⬜ |
| Watermark in bulk (text or logo) | P1 | ⬜ |
| Collage, contact sheet, sprite sheet | P1 | ⬜ |
| Upscale, denoise, straighten/flatten photographed documents | P1 | ⬜ |
| Passport / visa photo maker (country presets) | P1 | ⬜ |
| Colour palette extraction, portrait background blur | P2 | ⬜ |
| Duplicate and near-duplicate photo finder | P2 | ⬜ |

### Video tools

| Feature | Priority | Status |
|---|---|---|
| Trim, split, crop, change speed, join | P0 | ⬜ |
| Compress with size presets (email, WhatsApp, Discord 10 MB) | P0 | ⬜ |
| Extract audio, save frames, thumbnail grid, video → GIF with size target | P0 | ⬜ |
| Auto-subtitles (on-device speech recognition) → SRT/VTT, burn in | P0 | 🚧 SRT/VTT done; burn-in to do |
| Redact video (blur regions, auto-blur faces) | P1 | ⬜ |
| Auto-cut silences | P1 | ⬜ |
| Landscape → vertical 9:16 following the subject | P1 | ⬜ |
| Stabilise, split at scene changes | P2 | ⬜ |

### Audio tools

| Feature | Priority | Status |
|---|---|---|
| Trim, merge, fade, normalise loudness (incl. −16 LUFS podcast preset) | P0 | ⬜ |
| Channels (mono/stereo/swap), speed and pitch | P0 | ⬜ |
| Transcribe to text | P0 | ✅ |
| Bleep words, voice isolation / noise removal | P1 | ⬜ |
| Ringtone maker (.m4r), trim silence, audio visualiser video | P1 | ⬜ |
| BPM and key detection | P2 | ⬜ |

### PDF tools

| Feature | Priority | Status |
|---|---|---|
| Merge, split, reorder, rotate, delete pages | P0 | ⬜ |
| Compress (to target size) | P0 | ⬜ |
| OCR → searchable PDF | P0 | ⬜ |
| True redaction (removes underlying text) + auto-find emails, phones, Aadhaar/PAN | P0 | ⬜ |
| Sign and fill forms | P1 | ⬜ |
| Add/remove password, page numbers, watermark, flatten | P1 | ⬜ |
| Extract images, extract tables → CSV/Excel | P1 | ⬜ |
| Compare two PDFs, booklet and n-up printing, PDF/A | P2 | ⬜ |
| Read aloud → audio file | P2 | ⬜ |

### Any-file tools

| Feature | Priority | Status |
|---|---|---|
| Edit/remove metadata (all, sensitive, GPS only) | P0 | ⬜ |
| Checksums + verify a download against a published hash | P0 | ⬜ |
| Batch rename (patterns, date taken, content-based names) | P1 | ⬜ |
| Password-encrypt a file (opens on other platforms) | P1 | ⬜ |
| Send to phone over Wi-Fi | — | Not planned (needs the network) |
| Share sheet (AirDrop, Messages, Mail) handled by macOS, not by Ameya | P2 | ⬜ |
| QR code create and read | P1 | ⬜ |
| Sort into folders by date/place, find largest files, duplicate cleanup | P2 | ⬜ |
| Base64, split/join large files, check an app's code signature | P2 | ⬜ |

### Smart features (on-device only)

| Feature | Priority | Status |
|---|---|---|
| OCR (images and PDFs), translation | P0 | ⬜ |
| Rename by content | P1 | ⬜ |
| Alt text for images | P1 | ⬜ |
| Summarise documents (macOS 26+ on-device model) | P2 | ⬜ |

### Workflows

| Feature | Priority | Status |
|---|---|---|
| Undo and history (outputs go to Trash, never deleted) | P0 | ⬜ |
| Goal presets: "Fit for email", "Under 200 KB for a portal", "WhatsApp-ready" | P0 | ⬜ |
| Recipes: chain steps, pin to the wheel, run on 1 or 500 files | P1 | ⬜ |
| Watch folders | P1 | ⬜ |
| Share recipes as `.ameyarecipe` files | P1 | ⬜ |

### Reach

| Feature | Priority | Status |
|---|---|---|
| iPhone/iPad app + Share-sheet extension (same engine) | P1 | ⬜ |
| Localisation (Hindi first) | P1 | ⬜ |
| Sandboxed plug-in system for community formats | P2 | ⬜ |
| Community gallery of recipes and plug-ins | P2 | ⬜ |

### Release

| Feature | Priority | Status |
|---|---|---|
| CI: build, tests, app bundle and sandboxed self-test on every push | P0 | ✅ |
| Universal binary, macOS 14+ | P0 | ✅ |
| Accessibility audit (VoiceOver, keyboard, Reduce Motion/Transparency) | P0 | ⬜ |
| Developer ID signing + notarization + auto-update (needs Apple Developer account) | P0 | ⬜ |
| Project website (static, outside the app) | P2 | ⬜ |

## Formats

### Working today

| Family | Converts | Notes |
|---|---|---|
| Images | JPEG, PNG, HEIC, animated HEIC, AVIF, TIFF, BMP, GIF, WebP (still and animated), JPEG 2000, PSD, OpenEXR, TGA, Netpbm, KTX, KTX2, ASTC ↔ each other; JPEG XL, camera RAW (30+ brands), DICOM, Radiance HDR, SGI in | Animation and pages kept where the target supports them |
| Vector | SVG and SVGZ → every image format above (transparent) and → PDF (vector, text kept as text) | Rendered by the system SVG engine (CoreSVG); 1024 px long side when the SVG has no size; outside links dropped |
| Icons | Any image → ICO (16–256 px) and ICNS (16–1024 px), all standard sizes in one file | Padded to a square, centred |
| Markdown | Markdown ↔ HTML, DOCX, DOC, RTF, ODT, TXT, and → PDF; PDF → Markdown | Headings, lists, tables, code, links, bold/italic. Apple's DOCX writer drops links |
| Archives | ZIP, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, 7-Zip ↔ each other; RAR in | Unsafe paths, escaping links and zip bombs are blocked |
| PDF | Images ↔ PDF pages; PDF → TXT, RTF, HTML, DOCX, DOC, ODT | PDF text extraction; scanned PDFs need OCR (M4) |
| Documents | TXT, RTF, HTML, DOCX, DOC, ODT ↔ each other, and → PDF (A4) | Tables, lists and images laid out by the system text engine |
| Audio | MP3, M4A, WAV, AIFF, CAF, FLAC in → AAC, Apple Lossless, WAV, AIFF, CAF, FLAC | Up to stereo; AAC capped at 48 kHz |
| Video | MP4, MOV, M4V ↔ each other; video → GIF (first 30 s); GIF → MP4/MOV; sound from any video | Hardware encoding |
| Subtitles | SRT, WebVTT, ASS/SSA, SBV, TTML/DFXP, LRC, MicroDVD (.sub), SAMI ↔ each other; time shift option | Bold/italic/underline kept; positions, colours and fonts dropped (with a warning). LRC keeps start times only; MicroDVD assumes 23.976 fps unless the file says |
| Data | CSV, TSV, JSON, property list (XML and binary), XML ↔ each other; → YAML, XLSX, HTML table, Markdown table | Own code + Foundation. Nested JSON flattened to "a.b" columns; `;` CSV detected; XLSX is one sheet |
| E-books | EPUB → PDF, HTML, Markdown, TXT, DOCX, DOC, RTF, ODT; Markdown, HTML, DOCX, DOC, RTF, ODT, TXT → EPUB 3 | Chapters split at h1/h2; pictures carried over; DRM-protected books refused |
| Comics | CBZ, CBR → PDF (natural page order); CBR → CBZ; PDF → CBZ (one JPEG per page) | JPEG pages embedded without re-encoding |
| Transcription | Any audio or video → TXT, SRT, WebVTT | On-device only, with language models already on the Mac (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer before); never downloads; captions ≤ 2 × 42 chars, ≤ 7 s |
| Mac integration | Open With / drop on the Dock icon; Finder → Services → "Convert with Ameya" and "Convert to JPEG with Ameya"; menu bar "Convert Clipboard…" and "Copy Clipboard Picture As JPEG/PNG/PDF"; optional auto-convert of new HEIC photos in Downloads to JPEG; save to Downloads/Ameya or a chosen folder; open at login | Never the default app (Viewer, Alternate). Auto-convert is off by default, waits until a file has stopped growing for 2 s, writes the JPEG beside the photo, and only moves the original to the Trash if asked. A chosen folder is remembered with a security-scoped bookmark |

The full list of formats we could add, with routes and licences, is in the [format catalogue](FORMAT-CATALOGUE.md).

Not yet: MP3 output, reading YAML and XLSX, extracting archives to a folder, the FFmpeg-based formats (MKV, WebM, …).

Engines: **IIO** ImageIO · **PK** PDFKit · **AV** AVFoundation · **FF** LGPL FFmpeg · **TU** textutil ·
**WK** WebKit · **MI** Model I/O · **LA** libarchive · **Own** our own Swift code.

### Images

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| JPEG, PNG, HEIC, TIFF, BMP, GIF (still and animated) | ✔ | ✔ | IIO | P0 |
| WebP | ✔ | ✔ | IIO in, Own/libwebp out | P0 |
| AVIF | ✔ | ✔ | IIO | P0 |
| ICO, ICNS, favicon set, iOS/macOS app-icon set | ✔ | ✔ | IIO + Own | P0 |
| PDF (page ↔ image) | ✔ | ✔ | PK | P0 |
| RAW: DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2 | ✔ | — | Core Image RAW | P0 |
| SVG, SVGZ | ✔ | ✔ (traced) | CoreSVG render (done) / Own trace | P1 |
| JPEG XL | ✔ | ✔ | IIO (where supported) | P1 |
| Live Photo → MOV/GIF | ✔ | — | AV | P1 |
| HDR → SDR tone mapping, CMYK for print, P3 ↔ sRGB | ✔ | ✔ | Core Image / ColorSync | P1 |
| PSD (flattened), EXR, Radiance HDR, TGA, DDS, PBM/PGM/PPM, QOI | ✔ | partial | IIO / Own | P2 |
| iPhone HDR photos (gain map) → SDR or HDR-aware JPEG/HEIC | ✔ | ✔ | IIO / Core Image | P1 |
| Spatial (3D) photos → side-by-side or single-eye image | ✔ | — | IIO | P1 |
| JPEG 2000 (JP2) | ✔ | ✔ | IIO | P1 |
| DICOM (medical), FITS (astronomy) | ✔ | — | Own | P2 |
| Adobe swatches (.ase, .aco) ↔ colour palette (PNG, CSS, JSON) | ✔ | ✔ | Own | P2 |

### Video

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| MP4 (H.264, HEVC), MOV, M4V | ✔ | ✔ | AV | P0 |
| GIF, animated WebP, APNG from video | — | ✔ | IIO | P0 |
| ProRes | ✔ | ✔ | AV | P1 |
| MKV, WebM (VP9/AV1), AVI, FLV, WMV, MPEG-TS, 3GP | ✔ | WebM, MKV | FF | P1 |
| GIF → MP4/MOV | ✔ | ✔ | AV | P0 |
| iPhone spatial video (MV-HEVC) → side-by-side or 2D | ✔ | — | AV | P1 |
| HDR video (Dolby Vision, HLG) → SDR | ✔ | — | AV | P1 |
| Animated AVIF and animated WebP output | — | ✔ | IIO / Own | P1 |
| Lottie (.json, .lottie) → GIF / MP4 | ✔ | — | Own renderer | P2 |

### Audio

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| MP3 (in), AAC/M4A, WAV, AIFF, CAF, ALAC | ✔ | ✔ except MP3 out | AV | P0 |
| MP3 out | — | ✔ | FF (LAME is LGPL) | P0 |
| FLAC | ✔ | ✔ | AV / FF | P0 |
| Opus, Ogg Vorbis, WMA, AMR | ✔ | Opus, Ogg | FF | P1 |
| M4R ringtone | — | ✔ | AV | P1 |
| MIDI → audio (built-in synth) | ✔ | — | AVAudioUnitSampler | P2 |
| Several MP3s/M4As → one M4B audiobook with chapters | ✔ | ✔ | AV | P1 |
| LRC synced lyrics ↔ SRT/VTT | ✔ | ✔ | Own | ✅ done |

### Documents

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| TXT, RTF, RTFD, HTML | ✔ | ✔ | TU | P0 |
| DOCX, DOC, ODT, WordML | ✔ | ✔ | TU | P0 |
| PDF ↔ DOCX / TXT (with OCR fallback) | ✔ | ✔ | PK + Vision + Own | P0 |
| Markdown | ✔ | ✔ | Own | P0 |
| .webarchive → PDF, Markdown (web page URLs: not planned, needs the network) | ✔ | — | WK | P1 |
| EPUB ↔ PDF, EPUB from Markdown/DOCX | ✔ | ✔ | WK + Own | P1 |
| EML / MSG → PDF | ✔ | — | Own + WK | P1 |
| Pages, Numbers, Keynote (preview-based export) | ✔ | — | Quick Look | P2 |
| XLSX, PPTX input | ✔ | — | Own (OOXML parser) | P2 |
| Comic books CBZ/CBR ↔ PDF | ✔ | ✔ | LA + PK | P1 |
| DRM-free Kindle MOBI/AZW3, FB2 → EPUB | ✔ | — | Own | P2 |
| Jupyter notebooks (.ipynb) → PDF, HTML, Markdown | ✔ | — | Own + WK | P1 |
| Source code → syntax-highlighted PDF/HTML | ✔ | — | Own | P1 |
| AsciiDoc, reStructuredText → HTML/PDF | ✔ | — | Own | P2 |
| MBOX mailbox → split EML / PDF | ✔ | — | Own + WK | P2 |
| EPS / PostScript | ✘ | ✘ | — | Not planned: macOS removed its converter and Ghostscript is AGPL |

### Data and text

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| CSV, TSV, JSON, XLSX (out), XML, YAML, plist | ✔ | ✔ | Own | P1 |
| Pretty-print / minify JSON, XML | ✔ | ✔ | Own | P1 |
| VCF and ICS split/merge | ✔ | ✔ | Own | P2 |
| Base64 encode/decode | ✔ | ✔ | Own | P2 |
| SQLite → CSV / JSON (per table) | ✔ | — | SQLite3 (system) | P1 |
| TOML ↔ JSON ↔ YAML | ✔ | ✔ | Own | P1 |
| GPX, KML, GeoJSON conversions; photos' GPS → GPX track | ✔ | ✔ | Own | P1 |
| Parquet → CSV | ✔ | — | Own | P2 |
| Xcode string catalogs (.xcstrings), .strings ↔ CSV | ✔ | ✔ | Own | P2 |

### Subtitles

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| SRT, WebVTT | ✔ | ✔ | Own | P0 |
| ASS/SSA, SBV, TTML/DFXP | ✔ | ✔ | Own | ✅ done |
| LRC, MicroDVD (text .sub), SAMI | ✔ | ✔ | Own | ✅ done |

### Fonts, 3D, archives

| Format | In | Out | Engine | Priority |
|---|---|---|---|---|
| TTF, OTF ↔ WOFF, WOFF2 | ✔ | ✔ | Own + Brotli (MIT) | P2 |
| USDZ, USD, OBJ, STL, PLY | ✔ | ✔ | MI | P2 |
| GLB / glTF ↔ USDZ (AR Quick Look on iPhone) | ✔ | ✔ | MI + Own | P1 |
| 3MF (3D printing) | ✔ | ✔ | Own | P2 |
| ZIP (incl. AES-encrypted), TAR, TAR.GZ, TAR.XZ | ✔ | ✔ | LA | P1 |
| 7z, RAR, DMG, ISO (extract only) | ✔ | — | LA / hdiutil | P1 |
| Zstandard, LZ4, bzip2, xz | ✔ | ✔ | LA | P1 |
| macOS installer packages (.pkg) — extract contents | ✔ | — | LA (xar) | P2 |

Archive extraction is bounded (size, file count, nesting depth) and rejects path traversal and links that escape the output folder.
