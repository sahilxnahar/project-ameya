# Third-party notices

Ameya's own code is licensed under the Mozilla Public License 2.0 (see `LICENSE`).
This file lists third-party software that is distributed with or linked by Ameya.

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
- **Used for:** archives and single-file compression, inside the conversion worker only (the app itself does not link it). Ameya links the copy that ships with macOS (`/usr/lib/libarchive.2.dylib`); no libarchive code is vendored, only declarations of the API it uses in `Sources/CArchive`.

## The FFmpeg helper (`Ameya.app/Contents/MacOS/ameya-ffmpeg`)

Ameya ships a build of the FFmpeg command-line tool as a **separate executable**. Ameya's code does not
link to it; the conversion worker runs it as a child process. It is built by
[`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh), which downloads the exact source releases below from
the projects' official sites, verifies their SHA-256 checksums, and links them statically into one
universal (arm64 + x86_64) binary for macOS 14 and later.

| Component | Version | Licence | Source (exact tarball) | SHA-256 |
|---|---|---|---|---|
| FFmpeg | 8.1.3 | LGPL-2.1-or-later | https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz | `7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3` |
| LAME (MP3 encoder) | 3.100 | LGPL-2.0-or-later | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| libopus | 1.5.2 | BSD-3-Clause | https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz | `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1` |
| libvorbis | 1.3.7 | BSD-3-Clause | https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz | `b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b` |
| libogg | 1.3.6 | BSD-3-Clause | https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz | `5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061` |
| libvpx (VP8/VP9) | 1.15.2 | BSD-3-Clause + patent grant | https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.2.tar.gz | `26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa` |

NASM 2.16.03 (BSD-2-Clause) is used only as an assembler while building; it is not shipped.

FFmpeg is configured **without** `--enable-gpl` and **without** `--enable-nonfree`, so the helper is
licensed under the GNU Lesser General Public License, version 2.1 or later. The build script stops if
FFmpeg's `config.h` reports a GPL or non-free configuration. H.264 and HEVC are encoded by Apple's
VideoToolbox framework (part of macOS); AAC by FFmpeg's own encoder. No x264, x265, Xvid or FDK-AAC code
is included. The Matroska/WebM, Ogg, AVI, MP4 and other containers are FFmpeg's own LGPL code.

### Exact FFmpeg configure line

For each architecture (`ARCH` is `arm64` or `x86_64`, `FF_ARCH` is `aarch64` or `x86_64`, `PREFIX` is the
folder the static libraries above were installed into; the x86_64 build on an Apple-silicon Mac also passes
`--enable-cross-compile`):

```
./configure --prefix=$PREFIX --arch=$FF_ARCH --target-os=darwin --cc='clang -arch $ARCH' --cxx='clang++ -arch $ARCH' \
  --extra-cflags='-mmacosx-version-min=14.0 -I$PREFIX/include' --extra-ldflags='-mmacosx-version-min=14.0 -L$PREFIX/lib' \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --disable-everything --disable-autodetect --disable-network --disable-shared --enable-static --disable-debug --disable-doc \
  --disable-ffplay --disable-ffprobe --disable-avdevice \
  --enable-ffmpeg --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample \
  --enable-protocol='file,pipe' \
  --enable-demuxer='mov,matroska,avi,flv,asf,mpegts,mpegps,mpegvideo,ogg,mp3,wav,aiff,flac,caf,aac,h264,hevc,m4v' \
  --enable-muxer='mp4,mov,ipod,matroska,webm,avi,ogg,opus,mp3,wav,aiff,flac,caf,null' \
  --enable-decoder='h264,hevc,mpeg4,mpeg1video,mpeg2video,h263,flv,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,mjpeg,theora,prores,aac,aac_latm,mp1,mp2,mp3,mp3float,ac3,eac3,vorbis,opus,flac,alac,wmav1,wmav2,wmapro,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_qt,adpcm_ms,adpcm_ima_wav' \
  --enable-encoder='libmp3lame,libvorbis,libopus,libvpx_vp8,libvpx_vp9,h264_videotoolbox,hevc_videotoolbox,aac,mpeg4,flac,alac,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be' \
  --enable-parser='h264,hevc,mpeg4video,mpegvideo,mpegaudio,aac,aac_latm,ac3,vorbis,opus,flac,vp8,vp9,vc1,h263,mjpeg' \
  --enable-bsf='h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,vp9_superframe,vp9_superframe_split,extract_extradata,mpeg4_unpack_bframes,null' \
  --enable-filter='aresample,aformat,anull,null,format,scale,fps,setsar,setpts,asetpts,trim,atrim,pad,crop,transpose,hflip,vflip,copy,acopy' \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx
```

`ameya-ffmpeg -L` prints the licence of the shipped binary; `ameya-ffmpeg -buildconf` prints its configuration.

### Source code (LGPL)

The complete corresponding source for `ameya-ffmpeg` is:

- the unmodified upstream tarballs listed above (FFmpeg 8.1.3, LAME 3.100, libvpx 1.15.2, libopus 1.5.2,
  libogg 1.3.6 and libvorbis 1.3.7), identified by their SHA-256 sums; and
- the build script [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh), which records every configure option
  and the two small build fixes applied (removing an obsolete linker flag from libvorbis's `configure`, and
  removing the undefined `lame_init_old` symbol from LAME's export list). Running it reproduces the binary.

**With every release.** Each release on the project's GitHub Releases page
(https://github.com/sahilxnahar/project-ameya/releases) carries, next to the app,
`third-party-sources-<version>.tar.gz`: the exact tarballs that release's helper was built from, their
`SHA256SUMS`, the build script, this file and `LICENSES/`.

**Written offer.** For at least three years after we last distribute a given release of Ameya, we will give
anyone who asks a complete machine-readable copy of the source above for that release, for no charge beyond
the cost of physically providing it (normally nothing: a download link). To ask, open an issue at
https://github.com/sahilxnahar/project-ameya/issues naming the Ameya version.

Because the helper is a separate executable, you may replace `Contents/MacOS/ameya-ffmpeg` with your own
build of FFmpeg (re-sign the app afterwards).

The full text of the GNU Lesser General Public License version 2.1 is in
[`LICENSES/LGPL-2.1.txt`](LICENSES/LGPL-2.1.txt) (copied from the FFmpeg source release). LAME is licensed under
the GNU Library General Public License version 2 "or (at your option) any later version", and is distributed
here under version 2.1 of that licence.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. LAME: copyright the LAME
developers (https://lame.sourceforge.io).

### libogg 1.3.6

```
Copyright (c) 2002, Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### libvorbis 1.3.7

```
Copyright (c) 2002-2020 Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### libopus 1.5.2

```
Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Opus is subject to the royalty-free patent licenses which are
specified at:

Xiph.Org Foundation:
https://datatracker.ietf.org/ipr/1524/

Microsoft Corporation:
https://datatracker.ietf.org/ipr/1914/

Broadcom Corporation:
https://datatracker.ietf.org/ipr/1526/
```

### libvpx 1.15.2

```
Copyright (c) 2010, The WebM Project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google, nor the WebM Project, nor the names
    of its contributors may be used to endorse or promote products
    derived from this software without specific prior written
    permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

```

### libvpx 1.15.2 — additional patent grant

```
Additional IP Rights Grant (Patents)
------------------------------------

"These implementations" means the copyrightable works that implement the WebM
codecs distributed by Google as part of the WebM Project.

Google hereby grants to you a perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable (except as stated in this section) patent license to
make, have made, use, offer to sell, sell, import, transfer, and otherwise
run, modify and propagate the contents of these implementations of WebM, where
such license applies only to those patent claims, both currently owned by
Google and acquired in the future, licensable by Google that are necessarily
infringed by these implementations of WebM. This grant does not include claims
that would be infringed only as a consequence of further modification of these
implementations. If you or your agent or exclusive licensee institute or order
or agree to the institution of patent litigation or any other patent
enforcement activity against any entity (including a cross-claim or
counterclaim in a lawsuit) alleging that any of these implementations of WebM
or any code incorporated within any of these implementations of WebM
constitute direct or contributory patent infringement, or inducement of
patent infringement, then any patent rights granted to you under this License
for these implementations of WebM shall terminate as of the date such
litigation is filed.
```
