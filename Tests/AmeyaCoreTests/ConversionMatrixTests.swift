import Foundation
import Testing
@testable import AmeyaCore

@Suite("Conversion matrix")
struct ConversionMatrixTests {
    let matrix = ConversionMatrix(writable: [.jpeg, .png, .tiff, .gif, .pdf, .heic])

    @Test func neverOffersTheSourceOrUnwritableFormats() {
        let targets = matrix.targets(for: .png)
        #expect(!targets.contains(.png))
        #expect(!targets.contains(.webp))
        #expect(targets.contains(.jpeg))
    }

    @Test func commonTargetsAreTheIntersection() {
        let common = matrix.commonTargets(for: [.png, .jpeg])
        #expect(!common.contains(.png))
        #expect(!common.contains(.jpeg))
        #expect(common.contains(.pdf))
        #expect(matrix.commonTargets(for: []).isEmpty)
    }

    @Test func warnsBeforeLosingThings() {
        #expect(matrix.possibleLosses(from: .png, to: .jpeg).contains(.transparencyFilledWhite))
        #expect(matrix.possibleLosses(from: .gif, to: .jpeg).contains(.onlyFirstFrameKept))
        #expect(matrix.possibleLosses(from: .gif, to: .pdf) == [.animationBecamePages])
        #expect(matrix.possibleLosses(from: .pdf, to: .png).contains(.onlyFirstPageKept))
        #expect(matrix.possibleLosses(from: .jpeg, to: .png).isEmpty)
    }

    @Test func routesBetweenFamilies() {
        #expect(ConversionMatrix.canConvert(from: .pdf, to: .docx))
        #expect(ConversionMatrix.canConvert(from: .docx, to: .pdf))
        #expect(!ConversionMatrix.canConvert(from: .docx, to: .png))
        #expect(ConversionMatrix.canConvert(from: .mp4, to: .m4a))
        #expect(ConversionMatrix.canConvert(from: .mp4, to: .gif))
        #expect(ConversionMatrix.canConvert(from: .gif, to: .mp4))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .mp4))
        #expect(!ConversionMatrix.canConvert(from: .m4a, to: .mp4))
        #expect(ConversionMatrix.canConvert(from: .srt, to: .vtt))
        #expect(!ConversionMatrix.canConvert(from: .srt, to: .txt))
    }

    @Test func routesBooksAndComics() {
        for target in [FileFormat.pdf, .html, .md, .txt, .docx, .rtf, .odt] {
            #expect(ConversionMatrix.canConvert(from: .epub, to: target))
        }
        for source in [FileFormat.md, .html, .docx, .rtf, .odt, .txt] {
            #expect(ConversionMatrix.canConvert(from: source, to: .epub))
        }
        #expect(ConversionMatrix.canConvert(from: .cbz, to: .pdf))
        #expect(ConversionMatrix.canConvert(from: .cbr, to: .pdf))
        #expect(ConversionMatrix.canConvert(from: .cbr, to: .cbz))
        #expect(ConversionMatrix.canConvert(from: .pdf, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .cbz, to: .cbr))
        #expect(!ConversionMatrix.canConvert(from: .cbz, to: .txt))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .pdf, to: .epub))
        #expect(!ConversionMatrix.canConvert(from: .epub, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .epub, to: .png))
        #expect(!ConversionMatrix.canConvert(from: .zip, to: .epub))

        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(!FileFormat.systemWritable().contains(.cbr))
        #expect(system.targets(for: .pdf).contains(.cbz))
        #expect(system.targets(for: .md).contains(.epub))
        #expect(system.targets(for: .cbr) == [.pdf, .cbz, .gz, .bz2, .xz])
        #expect(system.possibleLosses(from: .epub, to: .pdf) == [.bookLayoutReflowed])
        #expect(system.possibleLosses(from: .epub, to: .txt) == [.formattingRemoved])
        #expect(system.possibleLosses(from: .md, to: .epub).isEmpty)
        #expect(system.possibleLosses(from: .pdf, to: .cbz) == [.pagesBecamePictures])
    }

    @Test func neverOffersFormatsThisMacCantWrite() {
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        // MP3 needs the bundled FFmpeg helper (LAME); plain `swift test` runs have none unless AMEYA_FFMPEG is set.
        #expect(system.targets(for: .wav).contains(.mp3) == FFmpegAvailability.isAvailable)
        #expect(!system.targets(for: .mp4).contains(.flv)) // read-only
        #expect(!system.targets(for: .wav).contains(.wav))
        #expect(system.targets(for: .wav).contains(.flac))
    }

    @Test func warnsAboutMediaAndDocumentLosses() {
        #expect(matrix.possibleLosses(from: .pdf, to: .docx) == [.onlyTextKept])
        #expect(matrix.possibleLosses(from: .docx, to: .txt) == [.formattingRemoved])
        #expect(matrix.possibleLosses(from: .mov, to: .wav) == [.onlySoundKept])
        #expect(matrix.possibleLosses(from: .wav, to: .m4a) == [.lossyAudio])
        #expect(matrix.possibleLosses(from: .wav, to: .flac).isEmpty)
        #expect(matrix.possibleLosses(from: .vtt, to: .srt) == [.subtitleStylingRemoved])
    }

    @Test func routesDataFormats() {
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(system.targets(for: .csv) == [.html, .md, .tsv, .json, .plist, .xml, .yaml, .xlsx, .vcf, .gz, .bz2, .xz]) // vCard: contacts
        #expect(system.targets(for: .xml).contains(.json))
        #expect(system.targets(for: .plist).contains(.json))
        #expect(system.targets(for: .yaml).isEmpty)
        #expect(system.targets(for: .xlsx).isEmpty)
        #expect(!ConversionMatrix.canConvert(from: .json, to: .pdf))
        #expect(!ConversionMatrix.canConvert(from: .html, to: .csv))
        #expect(!ConversionMatrix.canConvert(from: .json, to: .json))
    }

    @Test func warnsAboutDataLosses() {
        #expect(matrix.possibleLosses(from: .json, to: .csv) == [.nestedDataFlattened])
        #expect(matrix.possibleLosses(from: .csv, to: .json) == [.tableValuesTyped])
        #expect(matrix.possibleLosses(from: .csv, to: .xlsx).isEmpty)
        #expect(matrix.possibleLosses(from: .xml, to: .json) == [.xmlStructureMapped])
        #expect(matrix.possibleLosses(from: .json, to: .plist) == [.nullsRemoved])
        #expect(matrix.possibleLosses(from: .plist, to: .yaml) == [.datesAndDataAsText])
    }

    @Test func requestRoundTripsThroughTheWorkerProtocol() throws {
        let request = ConversionRequest(target: .heic, options: ConversionOptions(quality: 0.7))
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
    }
}
