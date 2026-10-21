import Foundation
import Testing
@testable import AmeyaCore

@Suite("Output naming")
struct OutputPlannerTests {
    let directory = URL(fileURLWithPath: "/out", isDirectory: true)

    @Test func swapsExtension() {
        let url = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/photo.png"), target: .jpeg, in: directory) { _ in false }
        #expect(url.path == "/out/photo.jpg")
    }

    @Test func neverReusesATakenName() {
        let taken: Set<String> = ["/out/photo.jpg", "/out/photo 2.jpg"]
        let url = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/photo.png"), target: .jpeg, in: directory) {
            taken.contains($0.path)
        }
        #expect(url.path == "/out/photo 3.jpg")
    }

    @Test func sameNameAsSourceIsTaken() {
        // Converting /out/a.jpg to JPEG-in-the-same-folder would collide with the original.
        let source = URL(fileURLWithPath: "/out/a.jpg")
        let url = OutputPlanner.destination(for: source, target: .jpeg, in: directory) { $0 == source }
        #expect(url.path == "/out/a 2.jpg")
    }

    @Test func keepsInnerDotsAndStripsLeadingDots() {
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/v1.2.final.png")) == "v1.2.final")
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/.hidden.png")) == "hidden")
        // ".png" is a hidden file named "png" with no extension.
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/.png")) == "png")
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/...")) == "Converted")
    }

    @Test func addsASuffixAndStillAvoidsTakenNames() {
        let source = URL(fileURLWithPath: "/in/photo.jpg")
        let first = OutputPlanner.destination(for: source, target: .jpeg, in: directory, suffix: "(rotated)") { _ in false }
        #expect(first.path == "/out/photo (rotated).jpg")
        let second = OutputPlanner.destination(for: source, target: .jpeg, in: directory, suffix: "(rotated)") {
            $0.path == "/out/photo (rotated).jpg"
        }
        #expect(second.path == "/out/photo (rotated) 2.jpg")
        let merged = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/report.pdf"), target: .pdf, in: directory, suffix: "(merged)") { _ in false }
        #expect(merged.lastPathComponent == "report (merged).pdf")
    }

    @Test func plansFoldersForSeveralOutputs() {
        let source = URL(fileURLWithPath: "/in/report.pdf")
        let folder = OutputPlanner.folderDestination(for: source, suffix: "(pages)", in: directory) { _ in false }
        #expect(folder.path == "/out/report (pages)")
        #expect(folder.hasDirectoryPath)
        let next = OutputPlanner.folderDestination(for: source, suffix: "(pages)", in: directory) { $0.path == "/out/report (pages)" }
        #expect(next.path == "/out/report (pages) 2")
    }
}
