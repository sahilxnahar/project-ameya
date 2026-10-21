import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import AmeyaEngines

/// Files full of hidden details, made in memory for the privacy tests.
enum PrivacyFixtures {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A JPEG taken "in London" by "Jane Doe" on a camera with a serial number.
    static func photo(in directory: URL, date: String = "2024:05:01 10:30:00") throws -> URL {
        let url = directory.appendingPathComponent("photo.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSDateStamp: "2024:05:01", kCGImagePropertyGPSTimeStamp: "09:30:00",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifDateTimeDigitized: date,
                kCGImagePropertyExifBodySerialNumber: "SN-4815162342", kCGImagePropertyExifCameraOwnerName: "Jane Doe",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5",
                kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFSoftware: "PhotoFixer 2",
                kCGImagePropertyTIFFDateTime: date,
            ],
        ]
        CGImageDestinationAddImage(destination, Fixtures.frames(1)[0], properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A PDF with an Info dictionary and an XMP packet naming its author.
    static func pdf(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("plans.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [kCGPDFContextAuthor: "Jane Doe", kCGPDFContextCreator: "SecretApp 1.0",
                                     kCGPDFContextTitle: "Plans"]
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.featureUnsupported) }
        context.addDocumentMetadata(Data("""
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="XMP Tool 9">\
        <dc:creator><rdf:Seq><rdf:li>Jane XMP</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>\
        <?xpacket end="w"?>
        """.utf8) as CFData)
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A Word document with an author, company, custom property, a comment and revision ids.
    static func docx(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("letter.docx")
        var zip = try ZipWriter(url: url)
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        try zip.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        <Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/>\
        </Types>
        """.utf8))
        try zip.add("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/>\
        </Relationships>
        """.utf8))
        try zip.add("word/document.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document \(w)><w:body><w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3">\
        <w:commentRangeStart w:id="0"/><w:r><w:t>Hello</w:t></w:r><w:commentRangeEnd w:id="0"/>\
        <w:r><w:commentReference w:id="0"/></w:r></w:p></w:body></w:document>
        """.utf8))
        try zip.add("word/_rels/document.xml.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/>\
        </Relationships>
        """.utf8))
        try zip.add("word/comments.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:comments \(w)><w:comment w:id="0" w:author="Bob Reviewer" w:initials="BR">\
        <w:p><w:r><w:t>Fix this</w:t></w:r></w:p></w:comment></w:comments>
        """.utf8))
        try zip.add("word/settings.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:settings \(w)><w:rsids><w:rsidRoot w:val="00A1B2C3"/>\
        <w:rsid w:val="00A1B2C3"/><w:rsid w:val="00D4E5F6"/></w:rsids></w:settings>
        """.utf8))
        try zip.add("docProps/core.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><cp:coreProperties \
        xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/">\
        <dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>John Smith</cp:lastModifiedBy>\
        <cp:revision>7</cp:revision><dcterms:created>2024-05-01T10:00:00Z</dcterms:created></cp:coreProperties>
        """.utf8))
        try zip.add("docProps/app.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
        <Application>Microsoft Office Word</Application><Company>Acme Secret Labs</Company><TotalTime>42</TotalTime></Properties>
        """.utf8))
        try zip.add("docProps/custom.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Properties \
        xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="ClientName"><vt:lpwstr>Megacorp</vt:lpwstr></property>\
        </Properties>
        """.utf8))
        try zip.finish()
        return url
    }

    /// A short clip "recorded" at the Eiffel Tower on an iPhone. (MP4 keeps only the location.)
    static func video(in directory: URL, as fileType: AVFileType = .mp4) async throws -> URL {
        let url = directory.appendingPathComponent(fileType == .mov ? "clip.mov" : "clip.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+48.8584+002.2945+035.000/"),
            item(.quickTimeMetadataMake, "Apple"),
            item(.quickTimeMetadataModel, "iPhone 15 Pro"),
            item(.quickTimeMetadataSoftware, "17.4"),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw CocoaError(.featureUnsupported)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
