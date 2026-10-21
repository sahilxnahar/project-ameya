@testable import AmeyaCore
import Foundation
import Testing

@Suite("Drag wheel geometry")
struct WheelGeometryTests {
    let six = WheelGeometry(count: 6, innerRadius: 50, outerRadius: 140)

    @Test func anglesRunClockwiseFromTop() {
        #expect(WheelGeometry.angle(dx: 0, dy: 10) == 0)
        #expect(abs(WheelGeometry.angle(dx: 10, dy: 0) - .pi / 2) < 1e-9)
        #expect(abs(WheelGeometry.angle(dx: 0, dy: -10) - .pi) < 1e-9)
        #expect(abs(WheelGeometry.angle(dx: -10, dy: 0) - 3 * .pi / 2) < 1e-9)
    }

    @Test func wedgeZeroStraddlesTheTop() {
        #expect(six.wedge(dx: 0, dy: 100) == 0)
        #expect(six.wedge(dx: -20, dy: 100) == 0) // just left of 12 o'clock
        #expect(six.wedge(dx: 20, dy: 100) == 0)
    }

    @Test func wedgesFollowClockwise() {
        #expect(six.wedge(atAngle: .pi / 3) == 1)
        #expect(six.wedge(atAngle: 2 * .pi / 3) == 2)
        #expect(six.wedge(atAngle: .pi) == 3)
        #expect(six.wedge(atAngle: 4 * .pi / 3) == 4)
        #expect(six.wedge(atAngle: 5 * .pi / 3) == 5)
        #expect(six.wedge(atAngle: 2 * .pi - 0.01) == 0)
        #expect(six.wedge(atAngle: -0.01) == 0)
        #expect(six.wedge(atAngle: 4 * .pi + .pi) == 3)
    }

    @Test func boundariesBelongToTheNextWedge() {
        let edge = six.span / 2
        #expect(six.wedge(atAngle: edge - 1e-6) == 0)
        #expect(six.wedge(atAngle: edge + 1e-6) == 1)
    }

    @Test func middleAndFarOutsideHitNothing() {
        #expect(six.wedge(dx: 0, dy: 0) == nil)
        #expect(six.wedge(dx: 10, dy: 30) == nil) // inside the dead middle
        #expect(six.wedge(dx: 0, dy: 140 + 20) == 0) // a little past the edge still counts
        #expect(six.wedge(dx: 0, dy: 140 + 40) == nil)
    }

    @Test func everyWedgeIsHitAtItsLabel() {
        for count in 1...8 {
            let geometry = WheelGeometry(count: count, innerRadius: 40, outerRadius: 120)
            for index in 0..<count {
                let label = geometry.labelCenter(of: index)
                #expect(geometry.wedge(dx: label.x, dy: label.y) == index, "count \(count), wedge \(index)")
            }
        }
    }

    @Test func labelsSitMidRing() {
        let label = six.labelCenter(of: 0)
        #expect(abs(label.x) < 1e-9)
        #expect(abs(label.y - 95) < 1e-9)
        let right = WheelGeometry(count: 4, innerRadius: 40, outerRadius: 120).labelCenter(of: 1)
        #expect(abs(right.x - 80) < 1e-9 && abs(right.y) < 1e-9)
    }

    @Test func wedgeAnglesCoverTheCircle() {
        let (start, end) = six.angles(of: 0)
        #expect(abs(start - (2 * .pi - six.span / 2)) < 1e-9)
        #expect(abs(end - start - six.span) < 1e-9)
    }

    @Test func emptyWheelHitsNothing() {
        let empty = WheelGeometry(count: 0, innerRadius: 40, outerRadius: 120)
        #expect(empty.wedge(dx: 0, dy: 80) == nil)
    }

    @Test func labelsFitTheirWedge() {
        let eight = WheelSize.medium.geometry(count: 8)
        #expect(eight.maxLabelWidth > 40 && eight.maxLabelWidth < 90)
        #expect(WheelSize.large.outerRadius > WheelSize.small.outerRadius)
    }
}

@Suite("Drag wheel choices")
struct WheelChoiceTests {
    let matrix = ConversionMatrix(writable: Set(FileFormat.allCases).subtracting([.rar, .cbr, .sqlite, .abc, .other]))

    @Test func photosLeadWithJPEGAndPNG() {
        let sources: [FileFormat] = [.heic]
        let top = WheelTargetRanker.top(matrix.commonTargets(for: sources), for: sources, limit: 6)
        #expect(Array(top.prefix(3)) == [.jpeg, .png, .pdf])
        #expect(top.count == 6)
    }

    @Test func neverOffersTheSourceItself() {
        let top = WheelTargetRanker.top(matrix.commonTargets(for: [.jpeg]), for: [.jpeg])
        #expect(!top.contains(.jpeg))
        #expect(top.first == .png)
    }

    @Test func mixedPicturesAndPDFsFavourPDF() {
        let sources: [FileFormat] = [.png, .pdf]
        let available = matrix.commonTargets(for: sources)
        let top = WheelTargetRanker.top(available, for: sources, limit: 4)
        #expect(top.allSatisfy(available.contains))
        #expect(top.first == .jpeg || top.first == .png)
        // Every result must suit both files.
        for target in top {
            #expect(ConversionMatrix.canConvert(from: .png, to: target, ffmpeg: true))
            #expect(ConversionMatrix.canConvert(from: .pdf, to: target, ffmpeg: true))
        }
    }

    @Test func picturesAndDocumentsTogetherGetPDF() {
        let top = WheelTargetRanker.top([.txt, .pdf, .png], for: [.jpeg, .docx], limit: 3)
        #expect(top.first == .pdf)
    }

    @Test func unrelatedFilesOnlyShareCompression() {
        let sources: [FileFormat] = [.mp3, .vcf]
        let top = WheelTargetRanker.top(matrix.commonTargets(for: sources), for: sources)
        #expect(top.allSatisfy { $0.family == .compressed || $0.family == .archive })
        #expect(WheelTargetRanker.top([], for: sources).isEmpty)
    }

    @Test func respectsTheLimitAndKeepsUnrankedOrder() {
        let top = WheelTargetRanker.top([.bmp, .tga, .jpeg], for: [.png], limit: 2)
        #expect(top == [.jpeg, .bmp])
        #expect(WheelTargetRanker.top([.jpeg], for: [.png], limit: 0).isEmpty)
        #expect(WheelTargetRanker.top(matrix.targets(for: .png), for: [.png]).count == WheelTargetRanker.maxWedges)
    }

    @Test func predictsFormatsFromNames() {
        let names = ["IMG_0001.HEIC", "report.pdf", "README", "song.mp3"]
        #expect(WheelTargetRanker.predictedFormats(forFileNames: names) == [.heic, .pdf, .other, .mp3])
    }
}

@Suite("Drag wheel keys and settings")
struct WheelSettingsTests {
    @Test func standardKeys() {
        let mapping = WheelModifierMapping.standard
        #expect(mapping.ring(for: [.shift]) == .convert)
        #expect(mapping.ring(for: [.command]) == .tools)
        #expect(mapping.ring(for: [.control]) == .actions)
        #expect(mapping.ring(for: [.option]) == nil)
        #expect(mapping.ring(for: []) == nil)
    }

    @Test func severalKeysPickTheFirstWheel() {
        #expect(WheelModifierMapping.standard.ring(for: [.control, .command]) == .tools)
        #expect(WheelModifierMapping.standard.ring(for: [.option, .control]) == .actions)
    }

    @Test func assigningATakenKeySwaps() {
        let swapped = WheelModifierMapping.standard.assigning(.command, to: .convert)
        #expect(swapped.key(for: .convert) == .command)
        #expect(swapped.key(for: .tools) == .shift)
        #expect(swapped.key(for: .actions) == .control)
    }

    @Test func aWheelCanHaveNoKey() {
        let mapping = WheelModifierMapping.standard.assigning(nil, to: .actions)
        #expect(mapping.key(for: .actions) == nil)
        #expect(mapping.ring(for: [.control]) == nil)
        let option = mapping.assigning(.option, to: .actions)
        #expect(option.ring(for: [.option]) == .actions)
    }

    @Test func duplicatesAreDropped() {
        let mapping = WheelModifierMapping(keys: [.convert: .shift, .tools: .shift])
        #expect(mapping.key(for: .convert) == .shift)
        #expect(mapping.key(for: .tools) == nil)
    }

    @Test func exclusionsMatchBundleIDsIgnoringCase() {
        let excluded = WheelExclusions(["com.adobe.Photoshop", " com.figma.Desktop ", "com.adobe.photoshop", ""])
        #expect(excluded.bundleIDs == ["com.adobe.Photoshop", "com.figma.Desktop"])
        #expect(excluded.excludes("com.adobe.photoshop"))
        #expect(excluded.excludes("COM.FIGMA.DESKTOP"))
        #expect(!excluded.excludes("com.apple.finder"))
        #expect(!excluded.excludes(nil))
        #expect(!excluded.removing("COM.adobe.photoshop").excludes("com.adobe.Photoshop"))
        #expect(excluded.adding("com.apple.Preview").bundleIDs.count == 3)
    }

    @Test func settingsRoundTripThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "wheel-test-\(UUID().uuidString)"))
        #expect(WheelSettings.load(from: defaults) == WheelSettings())
        var settings = WheelSettings()
        settings.isEnabled = false
        settings.size = .large
        settings.mapping = settings.mapping.assigning(nil, to: .actions).assigning(.option, to: .tools)
        settings.exclusions = WheelExclusions(["com.example.cad"])
        settings.save(to: defaults)
        #expect(WheelSettings.load(from: defaults) == settings)
    }

    @Test func announcements() {
        #expect(WheelRing.convert.announcement(choices: 6) == "Convert wheel, 6 choices")
        #expect(WheelRing.actions.announcement(choices: 1) == "Actions wheel, 1 choice")
    }
}

@Suite("Drag wheel state machine")
struct WheelStateMachineTests {
    func finderDrag(_ modifiers: Set<WheelModifier> = []) -> WheelDragSnapshot {
        WheelDragSnapshot(hasFiles: true, sourceBundleID: "com.apple.finder", isInternal: false, modifiers: modifiers)
    }

    @Test func fullConvertGesture() {
        var machine = WheelStateMachine()
        #expect(machine.handle(.dragStarted(finderDrag())) == [])
        #expect(machine.state == .dragging)
        #expect(machine.handle(.modifiersChanged([.shift])) == [.show(.convert)])
        #expect(machine.handle(.hover(2)) == [.highlight(2), .haptic])
        #expect(machine.handle(.hover(2)) == [])
        #expect(machine.handle(.dropped(2)) == [.perform(.convert, wedge: 2), .hide])
        #expect(machine.state == .idle)
    }

    @Test func keyHeldAtStartShowsAtOnce() {
        var machine = WheelStateMachine()
        #expect(machine.handle(.dragStarted(finderDrag([.command]))) == [.show(.tools)])
    }

    @Test func releasingTheKeyKeepsTheWheel() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag([.shift])))
        #expect(machine.handle(.modifiersChanged([])) == [])
        #expect(machine.isWheelVisible)
        #expect(machine.handle(.modifiersChanged([.control])) == [.switchRing(.actions)])
        #expect(machine.state == .showing(.actions, hovered: nil))
    }

    @Test func plainDragNeverShows() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag()))
        machine.handle(.modifiersChanged([.option]))
        #expect(!machine.isWheelVisible)
        #expect(machine.handle(.mouseUp) == [])
        #expect(machine.state == .idle)
    }

    @Test func noFilesInternalExcludedOrDisabledAreIgnored() {
        var settings = WheelSettings()
        settings.exclusions = WheelExclusions(["com.example.cad"])
        let cases = [
            WheelDragSnapshot(hasFiles: false, sourceBundleID: "com.apple.Safari", isInternal: false, modifiers: [.shift]),
            WheelDragSnapshot(hasFiles: true, sourceBundleID: "io.github.sahilxnahar.ameya", isInternal: true, modifiers: [.shift]),
            WheelDragSnapshot(hasFiles: true, sourceBundleID: "com.example.CAD", isInternal: false, modifiers: [.shift]),
        ]
        for snapshot in cases {
            var machine = WheelStateMachine(settings: settings)
            #expect(machine.handle(.dragStarted(snapshot)) == [])
            #expect(machine.state == .suppressed)
            #expect(machine.handle(.modifiersChanged([.shift])) == [])
            #expect(machine.handle(.mouseUp) == [])
            #expect(machine.state == .idle)
        }
        settings.isEnabled = false
        var off = WheelStateMachine(settings: settings)
        #expect(off.handle(.dragStarted(finderDrag([.shift]))) == [])
        #expect(off.state == .suppressed)
    }

    @Test func escapeCancelsForTheRestOfTheDrag() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag([.shift])))
        #expect(machine.handle(.escape) == [.hide])
        #expect(machine.handle(.modifiersChanged([.shift])) == [])
        #expect(machine.handle(.dropped(1)) == [])
        machine.handle(.mouseUp)
        #expect(machine.state == .idle)

        var early = WheelStateMachine()
        early.handle(.dragStarted(finderDrag()))
        early.handle(.escape)
        #expect(early.handle(.modifiersChanged([.shift])) == [])
    }

    @Test func dropAfterMouseUpStillRuns() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag([.shift])))
        machine.handle(.hover(0))
        #expect(machine.handle(.mouseUp) == [.awaitDrop])
        #expect(machine.state == .finishing(.convert))
        #expect(machine.handle(.dropped(0)) == [.perform(.convert, wedge: 0), .hide])
    }

    @Test func droppingElsewhereCancels() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag([.control])))
        machine.handle(.hover(1))
        #expect(machine.handle(.hover(nil)) == [.highlight(nil)])
        machine.handle(.mouseUp)
        #expect(machine.handle(.finishTimeout) == [.hide])
        #expect(machine.state == .idle)
        #expect(!machine.isTracking)
    }

    @Test func aNewDragWhileFinishingStartsFresh() {
        var machine = WheelStateMachine()
        machine.handle(.dragStarted(finderDrag([.shift])))
        machine.handle(.mouseUp)
        #expect(machine.handle(.dragStarted(finderDrag([.command]))) == [.hide, .show(.tools)])
    }

    @Test func strayEventsWhileIdleDoNothing() {
        var machine = WheelStateMachine()
        for event: WheelStateMachine.Event in [.modifiersChanged([.shift]), .hover(1), .dropped(0), .mouseUp, .escape, .finishTimeout] {
            #expect(machine.handle(event) == [])
            #expect(machine.state == .idle)
        }
    }
}
