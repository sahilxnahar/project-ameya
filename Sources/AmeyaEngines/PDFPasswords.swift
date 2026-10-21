import AmeyaCore
import CoreGraphics
import Foundation
import PDFKit

/// Adds and removes PDF passwords. Passwords reach the worker on stdin (WorkerSecret) and are
/// never written anywhere but into the PDF's own encryption.
@MainActor
enum PDFPasswords {
    /// PDF passwords are limited to one byte per character; printable ASCII keeps every reader happy.
    static func isUsable(_ password: String) -> Bool {
        !password.isEmpty && password.count <= 127 && password.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// Writes an AES-128 encrypted copy (the strongest the system PDF writer offers) that needs
    /// `password` to open. Pages are redrawn as they look, so their content stays vector; links,
    /// notes and form fields are burned into the page first and bookmarks are not kept.
    static func protect(_ input: URL, password: String, scratch: URL,
                        progress: (Double) -> Void) throws -> (output: URL, notes: [ConversionNote]) {
        guard isUsable(password) else {
            throw ConversionError.refused("Use letters, numbers and symbols from a standard keyboard for the password (no accents or emoji).")
        }
        var document = try PDFTools.open(input) // refuses PDFs that already have a password
        let hasAnnotations = (0..<document.pageCount).contains { !(document.page(at: $0)?.annotations.isEmpty ?? true) }
        if hasAnnotations {
            let burned = scratch.appendingPathComponent("burned.pdf")
            guard document.write(to: burned, withOptions: [.burnInAnnotationsOption: true]),
                  let flattened = PDFDocument(url: burned) else { throw ConversionError.encodeFailed(.pdf) }
            document = flattened
        }

        let output = scratch.appendingPathComponent("output.pdf")
        var info: [CFString: Any] = [
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password,
            kCGPDFContextEncryptionKeyLength: 128, // with a 128-bit key CoreGraphics uses AES (AESV2)
        ]
        let attributes = document.documentAttributes ?? [:]
        for (key, cgKey) in [(PDFDocumentAttribute.titleAttribute, kCGPDFContextTitle),
                             (.authorAttribute, kCGPDFContextAuthor), (.subjectAttribute, kCGPDFContextSubject),
                             (.creatorAttribute, kCGPDFContextCreator)] {
            if let value = attributes[key] as? String { info[cgKey] = value }
        }
        guard let context = CGContext(output as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef else { throw ConversionError.unreadable }
            // Drawn upright inside its crop box, so the page looks exactly as before.
            let (size, uprightToPage) = PDFToolbox.upright(page)
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.clip(to: box)
            context.concatenate(uprightToPage.inverted())
            context.drawPDFPage(page)
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount) * 0.9)
        }
        context.closePDF()

        guard let check = PDFDocument(url: output), check.isLocked, check.unlock(withPassword: password),
              check.pageCount == document.pageCount else {
            throw ConversionError.encodeFailed(.pdf)
        }
        progress(1)
        return (output, [.keepPasswordSafe])
    }

    /// Writes an unencrypted copy. Needs the password that opens the PDF (or its owner password).
    static func remove(_ input: URL, password: String, scratch: URL) throws -> URL {
        guard let document = PDFDocument(url: input) else { throw ConversionError.unreadable }
        guard document.isEncrypted else { throw ConversionError.refused("This PDF has no password to remove.") }
        guard document.unlock(withPassword: password) else { throw ConversionError.wrongPassword }
        guard document.pageCount > 0 else { throw ConversionError.unreadable }
        // PDFKit keeps a document's encryption when saving it, so the pages (with their links and
        // notes) move into a fresh document, along with its bookmarks and details.
        let plain = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ConversionError.unreadable }
            plain.insert(page, at: index)
        }
        plain.outlineRoot = document.outlineRoot
        plain.documentAttributes = document.documentAttributes
        let output = scratch.appendingPathComponent("output.pdf")
        guard plain.write(to: output), let check = PDFDocument(url: output), !check.isEncrypted, !check.isLocked else {
            throw ConversionError.encodeFailed(.pdf)
        }
        return output
    }
}
