# Handover — Project Ameya

Everything needed to pick this project up from another account, as of 21 October 2026.
`main` is the source of truth; unfinished work sits on the branches listed below.

## What Ameya is

A native file converter and toolbox. Drop files on it, pick what you want, get a new file.
Started as a clean-room replacement for the GPL "Open Tangerine" app (working name "tangerine",
renamed **Project Ameya**). No code from Open Tangerine was used.

### Product decisions (from the owner)

- **Everything stays on the computer.** No network use of any kind: no accounts, servers, uploads,
  downloads, model downloads or web fetching. Enforced by `Tests/AmeyaCoreTests/LocalOnlyTests.swift`
  (no network entitlements, no networking APIs). Network-dependent features are "not planned".
- **Easy, accessible and fun.** One obvious action, plain words; full keyboard + VoiceOver; respects
  Reduce Motion / Transparency / Increase Contrast; tasteful delight (Ameya gold accent, celebrations).
- **Menu-bar-first** on Mac (and tray-first on Windows), fast and light when idle.
- **Open source, MPL-2.0.** Permissive dependencies only; LGPL only as a separate process (FFmpeg);
  never GPL/AGPL. Satsuma (MIT) may be reused with credit; Open Tangerine (GPL) may not.
- **FFmpeg LGPL source:** "do both" — attach exact sources to every release *and* keep the 3-year
  written offer in `THIRD_PARTY_NOTICES.md`.
- **Windows version:** native **C# + WinUI 3**, Windows 11 and Windows 10 22H2, in `windows/`.
- No Apple Developer account yet → builds are ad-hoc signed, not notarized.

### Open decisions

1. "Fit for email" preset targets 25 MB; Gmail's limit applies after encoding (~+33%), so ~18 MB
   would be safer. Suggested: change to 18 MB, keep the label "Fit for email (25 MB limit)".
2. PDF passwords use AES-128 (Apple frameworks can't write AES-256). AES-256 would need qpdf
   (Apache-2.0) as a helper.
3. Apple Developer ID signing + notarization (needs a paid account).
4. Passport presets marked "unsure" (India passport/visa/OCI, Schengen, UAE) need checking against
   official rules.

## Architecture (Mac)

| Part | Role |
|---|---|
| `Sources/Ameya` | Sandboxed menu bar app (SwiftUI + AppKit): window, tools, results, drag wheel, Settings, Services, clipboard, auto HEIC→JPEG |
| `Sources/AmeyaCore` | Formats, detection (content first), conversion matrix + loss notes, output naming (never overwrites), worker protocol + runner, strict TAR for multi-file jobs |
| `Sources/AmeyaEngines` | All converters/tools; linked only into the worker |
| `Sources/AmeyaWorker` | One short-lived sandboxed process **per job**: stdin in, stdout out, status lines on stderr, timeouts, hard cancel, crash isolation |
| `Sources/CArchive`, `Sources/CWebP` | System libarchive headers; vendored libwebp 1.6.0 |
| `scripts/build-app.sh` | Builds `dist/Ameya.app` (universal; `NATIVE=1` for this Mac only) |
| `scripts/build-ffmpeg.sh` | Builds the LGPL FFmpeg helper (`ameya-ffmpeg`) from pinned, checksummed sources |

Key docs: [ROADMAP.md](ROADMAP.md) ("Working today" is the source of truth for what works),
[FORMAT-CATALOGUE.md](FORMAT-CATALOGUE.md) (200+ formats with routes and licences),
`THIRD_PARTY_NOTICES.md`, `windows/README.md` (on the `windows/foundation` branch).

### Build and verify

```sh
swift build && swift test                       # all tests
./scripts/build-ffmpeg.sh                       # optional, slow; enables Ogg/Opus/MP3/MKV/WebM/AVI
NATIVE=1 ./scripts/build-app.sh                 # dist/Ameya.app
dist/Ameya.app/Contents/MacOS/Ameya --self-test # real conversions inside the sandbox; must print SELFTEST OK
```

Merge rule used so far: merge a branch only when `swift test` has zero failures **and** the bundle
self-test prints `SELFTEST OK`.

## Branches waiting to be merged

`ready/` = finished by its agent with all `swift test` green; `wip/` = unfinished.
Suggested merge order is top to bottom. Every branch adds tools through `Sources/Ameya/ToolCatalog.swift`
and new cases in `Conversion.swift`; expect small "both sides added lines" conflicts there — keep both.

| Branch | What it adds | State |
|---|---|---|
| `ready/pdf-preview-in-worker` | PDF page thumbnails drawn by the worker (the app no longer parses PDFs); test banning in-app parsers | Tests green; preview self-test cases pass |
| `ready/privacy-tools` | "What's hidden in this file?" for photos/PDF/Office/EPUB/media, remove hidden details, edit photo details (date shift), batch rename, checksums + verify download | Tests green; its 7 self-test cases pass |
| `ready/photo-tools` | Edit photo (adjustments + compare), Redact (auto faces/text/plates, burns in, strips thumbnails), Remove background, Add background/beautify, Watermark (logo as 2nd input), Annotate | Tests green; its 5 self-test cases pass. Note: app-side previews run Core Image/Vision on a downscaled copy |
| `ready/shortcuts-and-cli` | Shortcuts actions (convert, run tool, 3 ready-made shortcuts; metadata generated by `scripts/app-intents-metadata.sh`) and the `ameya` CLI at `Contents/Helpers/ameya` with its own sandboxed worker copy | Tests green; CLI verified end to end |
| `ready/recipes-and-watch-folders` | Recipes (chained steps, editor, `.ameyarecipe` files, starter recipes) and watch folders (replacing the Downloads HEIC rule) | Its own checks pass; self-test re-run was interrupted |
| `wip/menubar-first` | Menu-bar-first app: no Dock icon by default, drop onto the status item, compact panel, ⌃⌥Space global shortcut, progress on the icon, `--bench` timing | Was about to build the bundle and run checks; performance numbers not yet reported |
| `wip/audio-video-tools` | Even volume (own BS.1770 meter + true-peak limiter), fades, trim, speed, channels, join audio/video, audiobook (M4B), ringtone, GIF for chat, extract frames, burned-in/auto captions, visualiser | `swift test` was green (257 + 131 + 11); last commit is uncommitted work saved as WIP; self-test not run |
| `wip/hardening-worker-isolation` | Worker self-restricting sandbox profile, memory/disk watchdogs, stderr cap, access pairing, FFmpeg group kill, safer auto-converter, Undo identity check | Integration tests passed under the strict profile; unfinished, saved as one WIP commit |
| `wip/hardening-engines` | Strip external references from HTML/Markdown/EPUB, block reference movies in AVFoundation, model-reference stripping, total pixel/node budgets, safer gzip names, symlink-chain checks, SQLite hardening | Unfinished, saved as one WIP commit |
| `windows/foundation` | Windows app: shared spec (`spec/formats.json`, exported and checked from Swift), C# core, sandboxed worker in a Job Object, WIC images, tray-first WinUI 3 app, CI | Windows CI not green yet (last run was still iterating) |
| `windows/ffmpeg` | Windows LGPL FFmpeg helper (x64 + arm64, llvm-mingw cross-build) + CI smoke tests | CI not green yet |

### Hardening still to finish (from an internal security review)

Neutral summary; the two `wip/hardening-*` branches contain the fixes in progress.
1. Workers inherit the app's whole sandbox (all of Downloads, the output folder) — tighten each
   worker to its own scratch folder (approach on `wip/hardening-worker-isolation`).
2. Remove the remaining in-app parsing of untrusted files (done on `ready/pdf-preview-in-worker`).
3. Strip external references in HTML/Markdown/EPUB/media/3D inputs; per-job memory and disk ceilings;
   total pixel and node budgets.
4. Auto-converter should trust file contents, not extensions, and skip quarantined downloads.
5. Smaller items: gzip-header output names, archive symlink chains, SQLite schema bombs, stderr buffer
   cap, security-scoped access pairing, FFmpeg outliving a cancelled worker, Undo identity check.
6. Release pipeline was hardened on `main` (fresh FFmpeg builds, draft releases, provenance); not run yet.

## Known issues on `main`

- **CI self-test failure:** `FAIL png -> txt: The converter sent an unexpected reply: reported 40 bytes,
  wrote 290` (GitHub run 39596613468). Something writes extra bytes to the worker's stdout during the
  image → text (QR/barcode reading) path — likely a framework logging to stdout. Fix: redirect stdout
  inside the worker to a private fd for the converted output, or route framework logging to stderr.
- **Text-recognition self-test checks time out (120 s) on a heavily loaded machine** ("Make PDF
  searchable", "picture to Word"). First Vision use loads models (~60 s). Consider a longer self-test
  timeout for OCR or warming Vision once.
- Intel half of the FFmpeg helper is built but never run (no Rosetta here).
- Release workflow and new CI steps have never run on GitHub.

## Manual checks nobody could automate

Drag wheel during a real Finder drag (hold ⇧ while dragging); Finder → Services → "Convert with Ameya";
⌘V paste in the window; passport photo with a real person (background replacement); PDF page grid
panels; Shortcuts actions in the Shortcuts app; menu bar drop + global shortcut (after merging
`wip/menubar-first`).

## Working notes

- Development used many parallel AI agents, each in its own git worktree, merged by a lead after
  tests + self-test. Worktrees are local only (`.claude/worktrees/`, git-ignored); everything worth
  keeping is on the branches above.
- The `tools-core WIP` git stash on the original machine is obsolete (already merged).
