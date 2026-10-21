# Ameya for Windows

The Windows version of Ameya: a native C# / WinUI 3 (Windows App SDK) app for **Windows 11 and
Windows 10 22H2 (build 19045)**, packaged as MSIX. Same promises as the Mac app: everything runs
on the PC, nothing is uploaded, originals are never touched, and nothing is ever overwritten.

## Build

You need Windows 10 22H2 or 11, the .NET 8 SDK and (for MSIX packages) Visual Studio 2022's
MSBuild with the Windows App SDK workload. From the repository root:

```powershell
# Tests (Debug, so the worker's test hooks are compiled in)
dotnet test windows/tests/Ameya.Tests/Ameya.Tests.csproj

# The app, for x64 or ARM64
dotnet build windows/src/Ameya.App/Ameya.App.csproj -c Release -p:Platform=x64

# Self-test: converts generated pictures through the real, sandboxed worker
windows/src/Ameya.App/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/Ameya.App.exe --self-test

# MSIX package (unsigned; sign it with your own certificate to install it)
msbuild windows/src/Ameya.App/Ameya.App.csproj /restore /p:Configuration=Release /p:Platform=x64 `
  /p:AmeyaSelfContained=true /p:GenerateAppxPackageOnBuild=true /p:UapAppxPackageBuildMode=SideloadOnly
```

CI (`.github/workflows/windows.yml`, on `windows-latest`) runs all of this on every push that
touches `windows/`, `spec/` or the workflow, signs the packages with a throwaway certificate made
for that run (only its public `.cer` is uploaded), installs the x64 package with its Windows App
SDK runtime, runs the installed app's self-test through its `Ameya.exe` alias, and uploads the
MSIX files.

## Layout

| Project | What it is |
|---|---|
| `src/Ameya.Core` | Formats, detection, conversion matrix, output naming, the strict TAR stream, the worker protocol and `WorkerRunner` with its sandbox. Plain .NET 8; the Win32 sandbox calls live in `Windows/`. |
| `src/Ameya.Engines` | Conversion engines. So far: pictures through the Windows Imaging Component (WIC), an ICO writer and a PDF writer. |
| `src/Ameya.Worker` | The worker exe: one short-lived process per job. |
| `src/Ameya.App` | The tray-first WinUI 3 app (MSIX). |
| `tests/Ameya.Tests` | xUnit: spec parity, detection vectors, TAR, output planner, protocol, the real worker (timeouts, cancelling, crashes, isolation), picture conversions, and the local-only guard. |

## One spec for both apps

The Mac app's tests export `spec/formats.json` (every format with its names and flags, every
family timeout, every note and its message, and every conversion route with what it may lose),
`spec/detection-vectors.json` (first bytes + file name → expected format, answered by the Mac's
own detector) and `spec/tar-sample.tar`. A Swift test fails when they are out of date:

```sh
AMEYA_WRITE_SPEC=1 swift test --filter SpecExport
```

Windows embeds `formats.json`, so it can **never offer a route the spec doesn't have**. It offers
fewer: a route is shown only when this PC can read the source and write the target
(`WindowsCapabilities`). Detection is a line-by-line port of the Swift detector and must give the
same answer for every vector; the TAR writer must produce byte-identical output.

## How a conversion runs

Exactly as on the Mac (`WorkerRunner.swift`, `AmeyaWorker/main.swift`), with Windows mechanisms:

1. The app detects the format from the first 512 bytes and picks a free name in
   `Downloads\Ameya` (never one that exists).
2. It opens the source **read-only** and passes that handle as the worker's stdin; it creates a
   hidden `.name.<id>.partial` file and passes it as stdout; stderr is a pipe for status lines
   (`AMEYA:progress:`, `AMEYA:done:<result JSON>`, `AMEYA:error:`). The request is JSON after
   `--request`; a password would travel on stdin ahead of the file (`WorkerSecret`), never on the
   command line. Only these three handles are inherited (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`).
3. The worker starts **suspended**, joins its own **Job Object**, then runs. The job has
   `KILL_ON_JOB_CLOSE`, a 4 GB per-process memory limit, `DIE_ON_UNHANDLED_EXCEPTION`, and all UI
   restrictions (no clipboard, global atoms, desktop switching, other processes' windows, system
   or display settings). Timeout (per format family, from the spec) or Cancel terminates the whole
   job, so anything the worker started (FFmpeg later) dies with it.
4. The worker runs at **Low integrity**: a copy of the app's token lowered to `S-1-16-4096`. It can
   read what it is given but can't write to the user's files, Downloads, `%TEMP%`, `HKCU` or other
   processes. It copies stdin into a scratch folder in `AppData\LocalLow\Ameya\Scratch` (the one
   place Low integrity may write), converts there and deletes it.
5. On `done`, the app checks the reported size against the partial file, then renames it into
   place with `File.Move(overwrite: false)` (MoveFileEx without `MOVEFILE_REPLACE_EXISTING`): if
   something appeared meanwhile, nothing is replaced. Several outputs arrive as a strict TAR stream
   that is unpacked into a hidden folder and moved the same way.

Exit codes from `0x80000000` up are reported as a crash ("Your original file is untouched").
Leftover partials and scratch folders older than six hours are swept at start-up.

**Why Low integrity rather than an AppContainer?** An AppContainer is a stronger box, but for a
child of a desktop (full-trust) MSIX app it needs a profile created and removed per install,
explicit ACL grants on every folder it reads, and the Store codec extensions (HEIF, AV1, WebP)
are not reliably loadable inside one. Low integrity plus a job object is reliable on every
Windows 10 22H2/11 PC, is verified by the tests (`TheWorkerRunsAtLowIntegrityInAJob` checks the
worker's own token, that it is in a job, and that writes to `%TEMP%`, Documents and the profile
fail while LocalLow works), and leaves room to move to an AppContainer later.

## What works so far

| Area | Status |
|---|---|
| Pictures: JPEG, PNG, TIFF (several pages), BMP, GIF (animated in and out), ICO (read; written with every standard size), PDF (pictures as pages) | ✅ |
| HEIC, AVIF, WebP (read) | ✅ when the free Store extensions are installed; otherwise not offered, with a plain message if met |
| EXIF orientation, sRGB colour, decompression-bomb pixel limit, frame limit | ✅ |
| Transparency flattened onto white only where needed, with a note only when a pixel was really see-through | ✅ |
| Tray icon (left click: panel; right click: Open, Paste files, Settings, Quit), drop zone, Choose files, Ctrl+V, results with Open / Show in folder | ✅ (built; see "Not verified on CI") |
| MSIX without any network capability; code and package scan for networking | ✅ |

Known differences from the Mac, all reported honestly in the result notes:
APNG and animated WebP read as their first frame; GIF output is flattened onto white when the
picture has see-through pixels (WIC's GIF encoder drops alpha); JPEG XR has no format id in the
shared spec, so it isn't offered; HEIC is read but not written yet.

### Not verified on CI

GitHub's runners have no interactive desktop, so the tray icon, the panel's placement, drag and
drop from File Explorer, the file picker, Narrator announcements and high-contrast rendering are
built and compiled but have not been exercised by a person. The self-test and the installed
package's self-test run headless.

## Next

Media through LGPL FFmpeg as a separate process inside the worker's job; documents; PDF tools and
OCR (Windows.Media.Ocr); archives and data; the design pass on the UI; Explorer integration
(context menu, Send to, share target); signing with a real certificate.
