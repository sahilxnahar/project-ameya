import Foundation
import Testing
@testable import AmeyaCore

/// Records what a fake worker was asked to do.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(number: Int, input: URL, output: URL)] = []
    func add(_ number: Int, _ input: URL, _ output: URL) { lock.withLock { entries.append((number, input, output)) } }
    var all: [(number: Int, input: URL, output: URL)] { lock.withLock { entries } }
}

@Suite("Recipe runner")
struct RecipeRunnerTests {
    let dir: URL
    let steps: [PlannedRecipeStep]

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-recipe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recipe = Recipe(name: "Photo", steps: [.tool("image.smaller"), .convert(.jpeg), .tool("image.removeLocation")])
        steps = try #require(FakeTools.planner.plan(recipe, for: .png))
    }

    /// A worker that appends its step number to the file and reports one note per step.
    func fake(_ log: StepLog, failAt: Int? = nil, error: Error = WorkerError.failed("The picture is damaged.")) -> RecipeRunner.Execute {
        { step, input, output, progress in
            log.add(step.number, input, output)
            if step.number == failAt { throw error }
            var data = try Data(contentsOf: input)
            data.append(Data(" \(step.number)".utf8))
            try data.write(to: output)
            progress(1)
            let note: ConversionNote = step.number == 3 ? .locationRemoved : .resized
            return ConversionResult(outputBytes: data.count, frames: 1, notes: [note])
        }
    }

    @Test("Each step reads the last one's file; only the final file reaches the destination")
    func runsInOrder() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png"), output = dir.appendingPathComponent("out.jpg")
        try Data("png".utf8).write(to: input)
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        let log = StepLog()
        let result = try await RecipeRunner.run(steps, input: input, destination: output, temporaryDirectory: scratch,
                                                execute: fake(log))
        let entries = log.all
        #expect(entries.map(\.number) == [1, 2, 3])
        #expect(entries[0].input == input)
        #expect(entries[1].input == entries[0].output && entries[2].input == entries[1].output)
        #expect(entries[0].output.path.hasPrefix(scratch.path) && entries[2].output == output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "png 1 2 3")
        #expect(result.notes == [.resized, .locationRemoved])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try String(contentsOf: input, encoding: .utf8) == "png")
    }

    @Test("A failing step is named, nothing is left behind, and the original is untouched")
    func failure() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png"), output = dir.appendingPathComponent("out.jpg")
        try Data("png".utf8).write(to: input)
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        let log = StepLog()
        do {
            _ = try await RecipeRunner.run(steps, input: input, destination: output, temporaryDirectory: scratch,
                                           execute: fake(log, failAt: 2))
            Issue.record("expected a failure")
        } catch let error as RecipeRunError {
            #expect(error.step == 2 && error.of == 3 && error.title == "Convert to JPEG")
            #expect(error.errorDescription == "Step 2 of 3 (Convert to JPEG) didn't work: The picture is damaged.")
        }
        #expect(log.all.map(\.number) == [1, 2])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try String(contentsOf: input, encoding: .utf8) == "png")
    }

    @Test("Cancelling stays a cancellation, not a failed step")
    func cancelled() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png")
        try Data("png".utf8).write(to: input)
        do {
            _ = try await RecipeRunner.run(steps, input: input, destination: dir.appendingPathComponent("out.jpg"),
                                           temporaryDirectory: dir, execute: fake(StepLog(), failAt: 1, error: WorkerError.cancelled))
            Issue.record("expected cancellation")
        } catch WorkerError.cancelled {
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("With nothing to do, the result is a copy and never replaces a file")
    func emptyPlan() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.jpg"), output = dir.appendingPathComponent("out.jpg")
        try Data("jpeg".utf8).write(to: input)
        _ = try await RecipeRunner.run([], input: input, destination: output, temporaryDirectory: dir, execute: fake(StepLog()))
        #expect(try String(contentsOf: output, encoding: .utf8) == "jpeg")
        await #expect(throws: WorkerError.self) {
            _ = try await RecipeRunner.run([], input: input, destination: output, temporaryDirectory: dir, execute: fake(StepLog()))
        }
    }
}

@Suite("Watch rules")
struct WatchRuleTests {
    @Test("The old HEIC setting becomes a Downloads rule, keeping the user's choices")
    func migration() throws {
        let on = WatchRules.load(saved: nil, legacyEnabled: true, legacyOriginal: "trash")
        #expect(on.count == 1)
        #expect(on[0].id == WatchRules.downloadsHEICRuleID && on[0].folder == .downloads)
        #expect(on[0].isEnabled && on[0].original == .trash)
        #expect(on[0].action == .convert(.jpeg) && on[0].fileTypes == [.heic] && on[0].output == .nextToOriginals)

        let fresh = WatchRules.load(saved: nil, legacyEnabled: false, legacyOriginal: nil)
        #expect(fresh == [WatchRules.downloadsHEICRule()])
        #expect(!fresh[0].isEnabled && fresh[0].original == .keep)

        // Garbage keeps the safe default rather than losing the folder list silently.
        #expect(WatchRules.load(saved: Data("{".utf8), legacyEnabled: false, legacyOriginal: "bogus") == fresh)
    }

    @Test("Saved rules win over the old setting, and survive a round trip")
    func savedRules() throws {
        let rules = [
            WatchRule(isEnabled: true, folder: .picked(bookmark: Data([1, 2, 3]), name: "Scans"),
                      fileTypes: [.pdf, .jpeg], action: .recipe(Recipe.starters[1].id), output: .ameyaFolder),
            WatchRules.downloadsHEICRule(enabled: true),
        ]
        let data = try JSONEncoder().encode(rules)
        #expect(WatchRules.load(saved: data, legacyEnabled: false, legacyOriginal: nil) == rules)

        let defaults = try #require(UserDefaults(suiteName: "ameya-watch-test-\(UUID().uuidString)"))
        defaults.set(true, forKey: WatchRules.legacyEnabledKey)
        #expect(WatchRules.load(from: defaults)[0].isEnabled)
        WatchRules.save(rules, to: defaults)
        #expect(WatchRules.load(from: defaults) == rules)
    }

    @Test("Rules match the file types they list, and never convert a file to its own format")
    func matching() {
        let heic = WatchRules.downloadsHEICRule(enabled: true)
        #expect(heic.applies(to: .heic) && !heic.applies(to: .jpeg) && !heic.applies(to: .png))
        let sameFormat = WatchRule(folder: .downloads, fileTypes: [.jpeg, .png], action: .convert(.jpeg))
        #expect(!sameFormat.applies(to: .jpeg) && sameFormat.applies(to: .png))
        let recipe = WatchRule(folder: .downloads, fileTypes: [.jpeg], action: .recipe(UUID()))
        #expect(recipe.applies(to: .jpeg))

        let off = WatchRules.downloadsHEICRule(enabled: false)
        #expect(WatchRules.matching([off, heic, sameFormat], format: .heic) == [heic])
        #expect(WatchRules.matching([off, sameFormat], format: .png).isEmpty) // sameFormat is off by default
    }

    @Test("A rule's tracker only waits for files it handles, and skips its own outputs")
    func tracker() {
        let rule = WatchRules.downloadsHEICRule(enabled: true)
        #expect(rule.extensions.isSuperset(of: ["heic"]))
        var tracker = rule.makeTracker(stableFor: 1)
        let start = Date()
        let photo = URL(fileURLWithPath: "/tmp/watch/IMG_1.HEIC"), made = URL(fileURLWithPath: "/tmp/watch/IMG_1.heic.jpg")
        let other = URL(fileURLWithPath: "/tmp/watch/notes.txt")
        tracker.setBaseline([])
        tracker.markProduced(made)
        let files = [WatchedFile(url: photo, size: 10), WatchedFile(url: other, size: 5), WatchedFile(url: made, size: 5)]
        #expect(tracker.update(files, now: start).isEmpty)
        #expect(tracker.update(files, now: start.addingTimeInterval(1.5)) == [photo])
        #expect(tracker.update(files, now: start.addingTimeInterval(3)).isEmpty)
    }
}
