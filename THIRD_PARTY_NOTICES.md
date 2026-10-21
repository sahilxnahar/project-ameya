# Third-party notices

Ameya is licensed under the Mozilla Public License 2.0. It includes or links the following third-party software.

## libwebp

- **Version:** 1.6.0
- **Licence:** BSD-3-Clause, plus an additional patent grant. Full texts in [`Sources/CWebP/COPYING`](Sources/CWebP/COPYING) and [`Sources/CWebP/PATENTS`](Sources/CWebP/PATENTS); authors in [`Sources/CWebP/AUTHORS`](Sources/CWebP/AUTHORS).
- **Copyright:** Copyright (c) 2010, Google Inc. All rights reserved.
- **Source:** https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
- **SHA-256:** `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`
- **Verified:** MD5 matches the hash published by the download bucket (`zOtkRxgPlhRzsYHJ7zi2MA==`), and the detached signature `libwebp-1.6.0.tar.gz.asc` is a good signature from the WebP release signing key `6B0E 6B70 976D E303 EDF2 F601 F9C3 D6BD B823 2B5D`.
- **Used for:** writing still and animated WebP (ImageIO can only read WebP).
- **What is vendored:** `src/{dec,demux,dsp,enc,mux,utils,webp}` and `sharpyuv`, unmodified, with the upstream file headers. MIPS and MSA SIMD files, examples, tools and build scripts are left out. `Sources/CWebP/include/CWebP.h` is Ameya's own umbrella header.

## libarchive

- **Licence:** BSD-2-Clause
- **Used for:** archives. Ameya links the copy that ships with macOS (`/usr/lib/libarchive.2.dylib`); no libarchive code is vendored, only declarations of the API it uses in `Sources/CArchive`.
