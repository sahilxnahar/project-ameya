# Format catalogue

Every format Project Ameya could support beyond what [works today](ROADMAP.md#working-today),
with the implementation route and its licence. Compiled 20 October 2026.

**Local-only rule:** Ameya never uses the network. Anything that needs it is not planned.

**Licence rule:** Apple system frameworks and permissive code (MIT, BSD, Apache-2.0, zlib, ISC, MPL-2.0).
LGPL only as a separate helper process (e.g. an LGPL FFmpeg build without GPL encoders). No GPL/AGPL.
Licences marked *(verify)* came from licence files or memory and must be re-checked before shipping.

**Effort:** S < 2 days · M ≈ 1 week · L = several weeks. **Value:** how often people need it.

## Top 25 to build next

| # | What | Route | Why |
|---|---|---|---|
| 1 | Ogg Vorbis, Opus in/out | FFmpeg helper (LGPL) + libvorbis/libopus (BSD-3) | Biggest audio gap |
| 2 | MP3 output | FFmpeg + LAME (LGPL) | Apple has no MP3 encoder; users expect it |
| 3 | MKV, WebM, AVI in/out | Same FFmpeg helper | Fixes most "my video won't play" cases |
| 4 | WebP output, animated WebP | libwebp (BSD-3) *(verify)* | Web staple; ImageIO can only read it |
| 5 | SVG → PNG/PDF | WebKit (system) | Very common designer request |
| 6 | Resize, crop, rotate, strip EXIF, ICC profiles | Core Image + ImageIO | Daily use (M3 tools) |
| 7 | PDF toolbox + OCR | PDFKit + Vision | Highest-volume need (M3/M4) |
| 8 | Video presets, trim, mute, extract audio | AVFoundation | Cheap, high demand |
| 9 | Transcribe audio/video → TXT/SRT | Speech framework (on-device) | Strong differentiator |
| 10 | ASS/SSA, MicroDVD SUB, SBV, TTML, LRC | Own parsers | Completes subtitles |
| 11 | PPTX, Pages, Keynote, Numbers in | ZIP+XML / embedded previews | Very common input |
| 12 | XLSX and XLS in | CoreXLSX (Apache-2.0), libxls (BSD-2) *(verify)* | Pairs with XLSX out |
| 13 | TOML, JSON Lines, INI, SQLite → CSV/JSON | TOMLKit (MIT), system sqlite3 | Nearly free with the data engine |
| 14 | EML, MBOX, MSG, winmail.dat → PDF/TXT | Own MIME/OLE/TNEF parsers | Everyday email export |
| 15 | vCard, iCalendar ↔ CSV | Contacts framework + own ICS parser | System API, high value |
| 16 | GeoJSON, KML/KMZ, GPX, lat/lon CSV | MapKit decoder + own XML | Popular with GPS users |
| 17 | Zstandard, CAB, LZH, ISO in; AES-encrypted ZIP | libarchive; libzip (BSD-3) *(verify)* | Small additions |
| 18 | QR and barcode create/read | Core Image + Vision | Tiny and popular |
| 19 | USD/USDZ, OBJ, STL, PLY, glTF | Model I/O + tinygltf (MIT) | 3D printing and AR |
| 20 | WOFF, WOFF2 fonts | woff2 (MIT) + brotli (MIT) | Web developers |
| 21 | MOBI/AZW3, FB2 → EPUB | Own parsers | Top ebook request |
| 22 | DDS (read), QOI | Own codecs / DirectXTex (MIT) *(verify)* | Game textures |
| 23 | Lottie → GIF/MP4 | lottie-ios (Apache-2.0) | Motion designers |
| 24 | Translate documents and subtitles | Translation framework (macOS 15+) | On-device, strong story |
| 25 | MIDI → WAV/M4A | AVAudioUnitSampler | Cheap |

## Images

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| SVG | .svg .svgz | In | WebKit snapshot (system); nanosvg (Zlib) as sandbox-safe fallback | M | high |
| SVG (trace bitmap) | .svg | Out | Own tracer or VTracer (MIT) *(verify)*; potrace is GPL | L | low |
| WebP / animated WebP | .webp | Out | libwebp (BSD-3) *(verify)* | M | high |
| JPEG XL | .jxl | Out | libjxl (BSD-3) | M | med |
| Optimised JPEG | .jpg | Out | mozjpeg (BSD/IJG) *(verify)* | M | low |
| Animated JPEG XL | .jxl | Out | libjxl | M | low |
| DDS (read) | .dds | In | Own BCn decoder or DirectXTex (MIT) *(verify)*; ImageIO writes but can't read | M | med |
| QOI, Farbfeld, PCX, Sun Raster, XBM, XPM, WBMP, IFF/ILBM | various | In/Out | Own small codecs | S each | low |
| Windows cursors | .cur .ani | In/Out | Same container as ICO; ANI is RIFF | S/M | low |
| PICT, QuickTime Image | .pict .qtif | In | ImageIO (legacy) | S | low |
| Live Photos | .heic + .mov | In | ImageIO + AVFoundation | M | med |
| iPhone HDR (gain map), ProRAW | .heic .dng | In/Out | Core Image / ImageIO (macOS 14+) | M | med |
| Image sequence ↔ video | .png series | In/Out | AVAssetWriter / AVAssetImageGenerator | M | med |
| ICC profile conversion | .icc | Op | ColorSync | S | med |
| Contact sheet → multi-page TIFF | .tiff | Out | ImageIO | S | med |

## Vector and design

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| SVG → PDF | .svg | Out | WebKit createPDF | M | high |
| PDF → SVG | .svg | Out | Own Core Graphics path emitter (MuPDF is AGPL) | L | med |
| Adobe Illustrator | .ai | In | PDF-compatible AI files open with PDFKit | S | med |
| Pages, Keynote, Numbers | .pages .key .numbers | In | Embedded preview PDF/JPEG; libetonyek (MPL-2.0) *(verify)* for full import | M | high |
| Visio, CorelDRAW | .vsdx .cdr | In | libvisio / libcdr (MPL-2.0) + librevenge *(verify)*, as a helper | L | low |
| WMF/EMF | .wmf .emf | In | Own renderer (libwmf is LGPL) | M | med |
| Lottie, dotLottie | .json .lottie | In | lottie-ios (Apache-2.0) | M | med |
| PDF/A, linearised, encrypted PDF | .pdf | Out | qpdf (Apache-2.0) as helper | L | med |
| Colour palettes | .ase .aco .gpl | In/Out | Own | S | low |
| LUTs | .cube .3dl | In/Out | Own + Core Image CIColorCube | S | med |

## Video

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| MKV / MKA | .mkv .mka | In/Out | FFmpeg (LGPL) | M | high |
| WebM (VP8/VP9/AV1) | .webm | In/Out | FFmpeg + libvpx (BSD-3), libaom (BSD-2) *(verify)* | M | high |
| AVI | .avi | In/Out | FFmpeg | M | high |
| MPEG-1/2, VOB, MPEG-TS, M2TS | .mpg .vob .ts .m2ts | In/Out | FFmpeg | M | med |
| WMV/ASF, FLV, RealMedia, MXF, OGV, MOD/TOD | various | In | FFmpeg (+ libtheora BSD-3 for OGV) | M | low–med |
| 3GP / 3G2 | .3gp | In/Out | AVFoundation in, FFmpeg out | M | med |
| DV | .dv | In/Out | AVFoundation | S | low |
| HEVC and ProRes presets | .mp4 .mov | In/Out | AVFoundation / VideoToolbox | S | high |
| AV1 encode | .mp4 .webm | Out | SVT-AV1 / libaom *(verify)* | M | med |
| Animated WebP/APNG → video | | Out | ImageIO + AVAssetWriter | M | med |
| HLS packaging | .m3u8 | Out | AVAssetWriter fMP4 segments | L | low |
| Spatial video (MV-HEVC) | .mov | In/Out | AVFoundation (macOS 14+) | L | low |
| Burn-in subtitles | | Op | Core Image + AVFoundation | M | med |

## Audio

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| MP3 | .mp3 | Out | FFmpeg + LAME (LGPL) | M | high |
| Ogg Vorbis | .ogg .oga | In/Out | FFmpeg + libvorbis (BSD-3) | M | high |
| Opus | .opus | In/Out | libopus (BSD-3) *(verify)* | M | high |
| AC3/E-AC3, MP2, GSM, AU/SND, W64/RF64, raw PCM | various | In/Out | Core Audio / FFmpeg | S–M | low |
| AMR | .amr | In/Out | Core Audio (NB); opencore-amr (Apache-2.0) *(verify)* | M | low |
| WMA, APE, WavPack, TTA, Musepack, DSD (DSF/DFF), DTS | various | In | FFmpeg decoders | M | low |
| MIDI → audio | .mid | In | AVAudioUnitSampler + Apple DLS | M | med |
| Tracker music | .mod .xm .it .s3m | In | libopenmpt (BSD-3) *(verify)* | M | low |
| M4B audiobook with chapters | .m4b | In/Out | AVFoundation | M | med |
| Transcribe → TXT/SRT | | Out | Speech framework (on-device) | M | high |
| Text → speech | .m4a .aiff | Out | AVSpeechSynthesizer | S | med |
| Waveform image | .png | Out | Core Graphics | S | low |

## Documents and office

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| RTFD, Web archive | .rtfd .webarchive | In/Out | NSAttributedString / WebKit | S | med |
| Own DOCX writer (keeps links, styles) | .docx | Out | Own OOXML | M | high |
| WordPerfect, MS Works, Lotus WordPro | .wpd .wps .lwp | In | libwpd/libwps (MPL-2.0) *(verify)*, as a helper | M | low |
| AbiWord, flat ODF | .abw .fodt | In/Out | Own XML | S | low |
| Hangul (HWPX/HWP) | .hwpx .hwp | In | Own (HWPX is ZIP+XML) | M | low |
| reStructuredText, AsciiDoc, Org, Textile, MediaWiki | various | In/Out | Own converters (pandoc is GPL) | M | low |
| LaTeX | .tex | In | Own text conversion; KaTeX (MIT) for maths only | L | low |
| Evernote export | .enex | In | Own XML | S | low |
| OCR → searchable PDF / text | .pdf .txt | Out | Vision | M | high |
| Translate, summarise | | Op | Translation (macOS 15+), Foundation Models (macOS 26+) | M | high / low |

## Ebooks and comics

| Format | Ext | In/Out | Route | Effort | Value |
|---|---|---|---|---|---|
| MOBI, AZW, AZW3 (DRM-free) | .mobi .azw3 | In | Own PalmDB/MOBI parser | L | high |
| FB2 | .fb2 | In/Out | Own XML | M | med |
| CBR, CB7, CBT | .cbr .cb7 .cbt | In | libarchive | S | high |
| iBooks Author | .ibooks | In | ZIP/XML | M | low |

## Spreadsheets and presentations

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| XLSX | .xlsx | In | CoreXLSX (Apache-2.0) or own | M | high |
| XLS | .xls | In | libxls (BSD-2) *(verify)* | M | high |
| ODS | .ods | In/Out | Own ZIP+XML | M | med |
| Numbers | .numbers | In | Embedded preview; libetonyek *(verify)* | M | high |
| PPTX / PPSX | .pptx | In | Own ZIP+XML text and images; Quick Look for previews | L | high |
| Keynote, ODP | .key .odp | In | Embedded preview / own XML | M | med |
| PPT | .ppt | In | Quick Look previews only | L | med |
| DIF, SYLK | .dif .slk | In/Out | Own | S | low |
| Slides → video | .mp4 | Out | PDFKit + AVAssetWriter | M | med |

## Data and config

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| TOML | .toml | In/Out | TOMLKit (MIT) | S | high |
| YAML (read) | .yaml .yml | In | Yams (MIT) | S | high |
| JSON Lines / NDJSON | .jsonl | In/Out | Own | S | high |
| INI, .properties, .env | | In/Out | Own | S | med |
| JSON5 / JSONC | .json5 | In | Own | S | low |
| SQLite → CSV/JSON/SQL dump | .sqlite .db | In | System sqlite3 | S | high |
| MessagePack, CBOR, BSON | | In/Out | Small MIT/Apache libraries *(verify)* | S | low |
| Parquet, Avro, Arrow | | In/Out | Apache libraries (Apache-2.0); heavy | L | med |
| HTML tables → CSV | .html | In | SwiftSoup (MIT) | S | med |
| Localisation: .strings, .xcstrings, XLIFF, PO, Android strings | | In/Out | Own | S | med |
| Base64, hex, data URLs | | In/Out | Foundation | S | med |

## Subtitles and lyrics

| Format | Ext | In/Out | Route | Effort | Value |
|---|---|---|---|---|---|
| ASS / SSA | .ass .ssa | In/Out | Own | M | high |
| MicroDVD, SBV, SAMI, MPL2 | .sub .sbv .smi | In/Out | Own | S | med |
| TTML / DFXP | .ttml .dfxp | In/Out | Own XML | M | med |
| LRC lyrics | .lrc | In/Out | Own | S | med |
| SCC (CEA-608), EBU STL | .scc .stl | In/Out | Own | M | low |
| VobSub, PGS (bitmap subtitles) | .sub/.idx .sup | In | Vision OCR | L | low |
| Shift timing / change frame rate | | Op | Own | S | med |
| Extract subtitles from MKV/MP4 | | In | FFmpeg / AVFoundation | M | med |

## Fonts

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| WOFF | .woff | In/Out | Own + Compression (zlib) | M | high |
| WOFF2 | .woff2 | In/Out | woff2 (MIT) + brotli (MIT) | M | high |
| TTF, OTF, TTC, dfont, Type 1 | various | In | Core Text | S | med |
| EOT | .eot | In/Out | Own (uncompressed) | M | low |
| Font specimen PDF/PNG | | Out | Core Text | S | med |
| Subsetting | | Op | HarfBuzz subset (MIT) *(verify)* | M | med |

## 3D and CAD

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| USD, USDZ, USDA, USDC | | In/Out | Model I/O / SceneKit | S | high |
| OBJ, STL, PLY | | In/Out | Model I/O | S | high |
| glTF / GLB | .gltf .glb | In/Out | tinygltf (MIT) / cgltf (MIT) *(verify)* | M | high |
| Collada, Alembic, SceneKit | .dae .abc .scn | In(/Out) | SceneKit / Model I/O | S | low–med |
| 3MF, AMF | .3mf .amf | In/Out | Own ZIP+XML | M | med |
| FBX, 3DS, LWO | | In | Assimp (BSD-3) *(verify)* | M | med |
| DXF | .dxf | In/Out | Own ASCII parser | M | med |
| STEP, IGES | .step .iges | In | OpenCascade (LGPL + exception) as helper; large | L | med |
| Point clouds (OFF, XYZ, PCD, LAS/LAZ) | | In/Out | Own; LASzip (Apache-2.0) *(verify)* | S–M | low |
| Draco | .drc | In/Out | draco (Apache-2.0) | M | low |
| G-code preview, MagicaVoxel | .gcode .vox | In | Own | S–M | low |
| 3D → PNG thumbnail | | Out | SceneKit snapshot | S | med |

## GIS and maps

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| GeoJSON | .geojson | In/Out | MapKit decoder + own | S | high |
| KML / KMZ | .kml .kmz | In/Out | Own XML + libarchive | M | high |
| GPX | .gpx | In/Out | Own XML | S | high |
| TCX, Garmin FIT | .tcx .fit | In | Own (FIT SDK licence *(verify)*) | M | med |
| Shapefile | .shp | In/Out | Own reader; GDAL (MIT) *(verify)* as helper | M | med |
| GeoPackage, MBTiles | .gpkg .mbtiles | In(/Out) | System sqlite3 + own WKB | M | med |
| GeoTIFF | .tif | In | ImageIO + tag parsing | M | med |
| WKT/WKB, TopoJSON, lat/lon CSV | | In/Out | Own | S | med |

## Archives, compression and disk images

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| Single-file gzip, bzip2, xz, LZMA | .gz .bz2 .xz .lzma | In/Out | libarchive / Compression | S | high |
| Zstandard, TAR.ZST | .zst | In/Out | libzstd (BSD option) *(verify)*; system libarchive lacks zstd | S | high |
| Brotli, LZ4, LZFSE | .br .lz4 .lzfse | In/Out | Compression framework | S | low–med |
| Password-protected ZIP (AES) | .zip | In/Out | libzip (BSD-3) / minizip-ng (zlib) *(verify)* | M | high |
| CAB, LZH/LHA, Unix compress | .cab .lzh .Z | In | libarchive | S | low–med |
| ISO 9660 | .iso | In | libarchive | S | med |
| XAR, PKG, RPM, DEB, cpio, ar | | In | libarchive | S | low |
| DMG | .dmg | In/Out | hdiutil, which the sandbox blocks; needs a privileged helper | M | high |
| StuffIt | .sit .sitx | In | The Unarchiver's XADMaster (LGPL) as helper *(verify)* | M | low |
| Split archives | .001 .z01 | In/Out | Own | S | low |
| Extract archive to folder | | Op | libarchive + safe extraction (M3) | M | high |

## Email, contacts and calendar

| Format | Ext | In/Out | Route | Effort | Value |
|---|---|---|---|---|---|
| EML, EMLX | .eml .emlx | In/Out | Own MIME parser | M | high |
| MBOX, Maildir | .mbox | In/Out | Own | M | med |
| Outlook MSG | .msg | In | Own OLE parser | L | high |
| winmail.dat (TNEF) | .dat | In | Own | M | med |
| PST / OST | .pst | In | libpff (LGPL-3) *(verify)* as helper | L | med |
| Email → PDF | .pdf | Out | WebKit | M | high |
| vCard ↔ CSV | .vcf | In/Out | Contacts framework | S | high |
| iCalendar ↔ CSV | .ics | In/Out | Own parser | M | high |
| LDIF, Google/Outlook contact CSV | | In/Out | Own | S | med |

## Code, notebooks and text

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| Source code → highlighted HTML/PDF/RTF | various | Out | Tree-sitter (MIT) or highlight.js (BSD-3) *(verify)* | M | med |
| Jupyter notebooks | .ipynb | In | Own JSON → HTML/MD/PDF | M | high |
| R Markdown, Quarto | .rmd .qmd | In | As Markdown | S | low |
| Text encodings (UTF-16, Latin-1, Shift-JIS, GBK…) | .txt | Op | Foundation | S | high |
| Line endings, BOM | | Op | Own | S | med |
| ANSI art → HTML | .ans | Out | Own | S | low |

## Medical and scientific

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| FITS | .fits | In | Own | M | med |
| NIfTI, NRRD, MetaImage | .nii .nrrd .mha | In | Own | M | low |
| NumPy | .npy .npz | In | Own | S | low |
| SPSS, Stata, SAS, R data | .sav .dta .sas7bdat .rds | In | ReadStat (MIT) *(verify)* | M | low |
| HDF5, NetCDF, MATLAB | .h5 .nc .mat | In | HDF5 / matio *(verify)*; heavy | L | low |
| FASTA/FASTQ, GenBank, EDF | | In | Own | S–M | low |
| OME-TIFF | .ome.tif | In | ImageIO + XML | M | low |
| Whole-slide images | .svs .ndpi | In | OpenSlide (LGPL) as helper | L | low |

## Games and textures

| Format | Ext | In/Out | Route (licence) | Effort | Value |
|---|---|---|---|---|---|
| Basis Universal | .basis | In/Out | basis_universal (Apache-2.0) *(verify)* | M | low |
| PVR | .pvr | In | Own PVRv3 parser | M | low |
| Sprite sheets (TexturePacker JSON) | .png + .json | In/Out | Own | M | med |
| Tiled maps, Aseprite | .tmx .aseprite | In | Own | M | low |
| Cubemap ↔ equirectangular, normal maps | | Op | Core Image / Metal | M | low |
| Bitmap fonts (BMFont) | .fnt | Out | Core Text | M | low |

## Everyday extras

| Format | Ext | In/Out | Route | Effort | Value |
|---|---|---|---|---|---|
| QR codes | .png .svg .pdf | In/Out | Core Image generate, Vision read | S | high |
| Barcodes (Code 128, PDF417, Aztec) | | In/Out | Core Image, Vision | S | med |
| Web page → PDF/PNG | url | — | Not planned: Ameya never uses the network | — | — |
| Link shortcuts | .webloc .url .inetloc | In/Out | Own | S | med |
| Browser bookmarks | .html .json | In/Out | Own | S | med |
| OPML, RSS/Atom | .opml .rss | In/Out | Own XML | S | low |
| Certificates | .pem .cer .p12 | In/Out | Security framework | S | low |
| Apple Wallet passes | .pkpass | In | ZIP+JSON | S | low |
| Torrent files (info) | .torrent | In | Own bencode | S | low |

## Not feasible under the licence rule

| Format / task | Reason |
|---|---|
| EPS / PostScript in or out | macOS 14 removed its PostScript converter; Ghostscript is AGPL |
| MuPDF-based rendering | AGPL |
| x264, x265, FFmpeg `--enable-gpl` | GPL; use VideoToolbox for H.264/HEVC |
| fdk-aac | Non-free; use AudioToolbox AAC |
| pandoc | GPL-2.0 |
| DjVu | DjVuLibre is GPL |
| JBIG2 standalone | jbig2dec is AGPL/GPL (PDFKit still renders it inside PDFs) |
| potrace | GPL |
| DWG (LibreDWG, libdxfrw) | GPL; ODA SDK is proprietary |
| FontForge | GPL |
| libpst | GPL (libpff, LGPL, as a helper is the alternative) |
| Open Babel chemistry formats | GPL |
| Exiv2 | GPL; use ImageIO metadata |
| RAR writing | unrar's licence forbids RAR compressors |
| ACE archives | Non-free |
| Blender files via Blender | GPL |
| Dolby (AC-4, Atmos, TrueHD), DTS encoding | Proprietary |
| FBX SDK, DWG TrueView | Proprietary |
| Figma, Affinity, Adobe XD native files | Proprietary and undocumented |
