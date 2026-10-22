import Foundation
import Testing
@testable import AmeyaCore

@Suite("Drag wheel key combinations, timing and items")
struct WheelTriggerTests {
    @Test func combinationsStoreAndParse() throws {
        let trigger = try #require(WheelTrigger([.option, .shift]))
        #expect(trigger.storageValue == "option+shift")
        #expect(trigger.symbols == "⌥⇧")
        #expect(WheelTrigger(storageValue: "shift+option") == trigger)
        #expect(WheelTrigger(storageValue: "shift") == WheelTrigger(.shift))
        #expect(WheelTrigger(storageValue: "shift+banana") == nil)
        #expect(WheelTrigger([]) == nil)
    }

    @Test func theMostSpecificTriggerWins() throws {
        let mapping = WheelModifierMapping.standard.assigning(trigger: try #require(WheelTrigger([.shift, .option])), to: .tools)
        #expect(mapping.ring(for: [.shift]) == .convert)
        #expect(mapping.ring(for: [.shift, .option]) == .tools)
        #expect(mapping.ring(for: [.option]) == nil)
        #expect(mapping.conflicts.contains(.overlap(shorter: .convert, longer: .tools)))
    }

    @Test func fnCanOpenAWheel() {
        let mapping = WheelModifierMapping.standard.assigning(.function, to: .actions)
        #expect(mapping.ring(for: [.function]) == .actions)
        #expect(mapping.conflicts.contains { if case .systemMeaning(.actions, _) = $0 { true } else { false } })
    }

    @Test func atDragStartIgnoresKeysPressedLater() {
        var machine = WheelStateMachine(settings: WheelSettings(activation: .atDragStart))
        let plain = WheelDragSnapshot(hasFiles: true, sourceBundleID: nil, isInternal: false)
        #expect(machine.handle(.dragStarted(plain)).isEmpty)
        #expect(machine.state == .suppressed)
        #expect(machine.handle(.modifiersChanged([.shift])).isEmpty)
        _ = machine.handle(.mouseUp)
        let held = WheelDragSnapshot(hasFiles: true, sourceBundleID: nil, isInternal: false, modifiers: [.shift])
        #expect(machine.handle(.dragStarted(held)) == [.show(.convert)])
    }

    @Test func settingsWithCombinationsDelayAndItemsRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "wheel-trigger-\(UUID().uuidString)"))
        var settings = WheelSettings()
        settings.mapping = settings.mapping.assigning(trigger: try #require(WheelTrigger([.shift, .option])), to: .actions)
        settings.activation = .atDragStart
        settings.showDelay = 0.3
        settings.items = [.convert: ["convert.png", "convert.jpeg"]]
        settings.save(to: defaults)
        #expect(WheelSettings.load(from: defaults) == settings)
        #expect(WheelSettings(showDelay: 9).showDelay == WheelSettings.maxDelay)
    }

    @Test func olderSingleKeyValuesStillLoad() throws {
        let defaults = try #require(UserDefaults(suiteName: "wheel-old-\(UUID().uuidString)"))
        defaults.set("option", forKey: WheelSettings.keyKey(.tools))
        #expect(WheelSettings.load(from: defaults).mapping.key(for: .tools) == .option)
    }
}
