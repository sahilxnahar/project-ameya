import Foundation

/// The keys that open one wheel: a single modifier (⇧) or a combination held together (⇧⌥).
public struct WheelTrigger: Sendable, Hashable, Codable, Comparable {
    public let modifiers: Set<WheelModifier>

    /// `nil` for an empty set: a wheel with no keys is simply off.
    public init?(_ modifiers: Set<WheelModifier>) {
        guard !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
    }

    public init(_ modifier: WheelModifier) {
        modifiers = [modifier]
    }

    private var sorted: [WheelModifier] { modifiers.sorted() }

    /// "⇧⌥", in the order macOS menus use.
    public var symbols: String { sorted.map(\.symbol).joined() }
    /// "Shift Option", for VoiceOver and Settings.
    public var title: String { sorted.map(\.title).joined(separator: " + ") }

    /// Stored in UserDefaults as "shift+option"; a single key is just "shift", as before.
    public var storageValue: String { sorted.map(\.rawValue).joined(separator: "+") }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "+").map(String.init)
        let keys = parts.compactMap(WheelModifier.init(rawValue:))
        guard keys.count == parts.count else { return nil }
        self.init(Set(keys))
    }

    /// True when holding `held` should open this wheel: every one of its keys is down.
    public func isSatisfied(by held: Set<WheelModifier>) -> Bool { modifiers.isSubset(of: held) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.storageValue < rhs.storageValue }
}

/// Which keys open which wheel. Each trigger opens at most one wheel; a wheel may have none.
public struct WheelModifierMapping: Sendable, Equatable, Codable {
    public private(set) var triggers: [WheelRing: WheelTrigger]

    public static let standard = WheelModifierMapping(keys: [.convert: .shift, .tools: .command, .actions: .control])

    public init(triggers: [WheelRing: WheelTrigger]) {
        // Drop exact duplicates, keeping the first ring (in display order) that claimed them.
        var used: Set<WheelTrigger> = []
        var clean: [WheelRing: WheelTrigger] = [:]
        for ring in WheelRing.allCases {
            if let trigger = triggers[ring], used.insert(trigger).inserted { clean[ring] = trigger }
        }
        self.triggers = clean
    }

    /// Single keys, as in earlier versions.
    public init(keys: [WheelRing: WheelModifier]) {
        self.init(triggers: keys.mapValues(WheelTrigger.init))
    }

    /// Wheels opened by a single key, keyed by ring (combinations are left out).
    public var keys: [WheelRing: WheelModifier] {
        triggers.compactMapValues { $0.modifiers.count == 1 ? $0.modifiers.first : nil }
    }

    public func trigger(for ring: WheelRing) -> WheelTrigger? { triggers[ring] }

    /// The single key for `ring`, or nil when it has none or a combination.
    public func key(for ring: WheelRing) -> WheelModifier? { keys[ring] }

    /// Gives `ring` the trigger. If another wheel had exactly that trigger, the two wheels swap,
    /// so a choice in Settings never silently disables another wheel.
    public func assigning(trigger: WheelTrigger?, to ring: WheelRing) -> WheelModifierMapping {
        var triggers = self.triggers
        let previous = triggers[ring]
        if let trigger, let other = triggers.first(where: { $0.value == trigger && $0.key != ring })?.key {
            triggers[other] = previous
        }
        triggers[ring] = trigger
        return WheelModifierMapping(triggers: triggers)
    }

    public func assigning(_ modifier: WheelModifier?, to ring: WheelRing) -> WheelModifierMapping {
        assigning(trigger: modifier.map(WheelTrigger.init), to: ring)
    }

    /// The wheel for the keys currently held, or `nil` if none matches. The most specific
    /// trigger wins (holding ⇧⌥ opens the ⇧⌥ wheel, not the ⇧ one); among equally specific
    /// ones, the first wheel in display order (Convert, Tools, Actions).
    public func ring(for held: Set<WheelModifier>) -> WheelRing? {
        let matching = WheelRing.allCases.filter { triggers[$0]?.isSatisfied(by: held) ?? false }
        let most = matching.map { triggers[$0]!.modifiers.count }.max()
        return matching.first { triggers[$0]!.modifiers.count == most }
    }

    /// Plain-language problems with these keys, for Settings to show next to the pickers.
    public var conflicts: [WheelKeyConflict] {
        var found: [WheelKeyConflict] = []
        let rings = WheelRing.allCases.filter { triggers[$0] != nil }
        for (index, ring) in rings.enumerated() {
            let trigger = triggers[ring]!
            for other in rings[(index + 1)...] {
                let otherTrigger = triggers[other]!
                if trigger.modifiers.isStrictSubset(of: otherTrigger.modifiers) || otherTrigger.modifiers.isStrictSubset(of: trigger.modifiers) {
                    let (small, big) = trigger.modifiers.count < otherTrigger.modifiers.count ? (ring, other) : (other, ring)
                    found.append(.overlap(shorter: small, longer: big))
                }
            }
            if trigger.modifiers.contains(.command) && trigger.modifiers.count == 1 {
                found.append(.systemMeaning(ring, "Finder uses ⌘ while dragging to move files between disks instead of copying them."))
            }
            if trigger.modifiers == [.option] {
                found.append(.systemMeaning(ring, "Finder uses ⌥ while dragging to copy files instead of moving them."))
            }
            if trigger.modifiers.contains(.function) {
                found.append(.systemMeaning(ring, "Pressing Fn (Globe) on its own may also show the emoji picker or switch keyboards, depending on System Settings › Keyboard."))
            }
        }
        return found
    }
}

/// Something worth knowing about the wheel's keys.
public enum WheelKeyConflict: Sendable, Equatable {
    /// One trigger is part of another: the longer one opens its wheel once all its keys are down.
    case overlap(shorter: WheelRing, longer: WheelRing)
    /// The keys already mean something to macOS while dragging; still allowed.
    case systemMeaning(WheelRing, String)

    public var message: String {
        switch self {
        case let .overlap(shorter, longer):
            "\(shorter.title) opens first while you press the keys for \(longer.title); press all of \(longer.title)'s keys together to switch."
        case let .systemMeaning(_, text):
            text
        }
    }
}

/// When the keys count.
public enum WheelActivation: String, CaseIterable, Sendable, Codable {
    /// Press the keys at any time during the drag (the default).
    case anyTime
    /// Only when the keys are already held as the drag starts; drags without them are left alone.
    case atDragStart

    public var title: String {
        switch self {
        case .anyTime: "Any time while dragging"
        case .atDragStart: "Only if held when the drag starts"
        }
    }
}

/// Everything the wheel reads from Settings, with the UserDefaults keys it is stored under.
public struct WheelSettings: Sendable, Equatable {
    public static let enabledKey = "wheel.enabled"
    public static let sizeKey = "wheel.size"
    public static let excludedKey = "wheel.excludedApps"
    public static let activationKey = "wheel.activation"
    public static let delayKey = "wheel.delay"
    public static func keyKey(_ ring: WheelRing) -> String { "wheel.key.\(ring.rawValue)" }
    public static func itemsKey(_ ring: WheelRing) -> String { "wheel.items.\(ring.rawValue)" }
    /// Stored for a wheel deliberately set to "No key".
    public static let noKey = "none"
    /// The longest wait before the wheel appears, in seconds.
    public static let maxDelay = 1.0

    public var isEnabled: Bool
    public var mapping: WheelModifierMapping
    public var size: WheelSize
    public var exclusions: WheelExclusions
    public var activation: WheelActivation
    /// Seconds to wait, with the keys held, before the wheel appears (0 = at once).
    public var showDelay: Double
    /// Each wheel's wedges chosen in Settings, in order (`WheelChoice` ids such as
    /// "convert.jpeg", "tool.image.removeLocation", "action.copyPath"). Missing or empty: Ameya picks.
    public var items: [WheelRing: [String]]

    public init(isEnabled: Bool = true, mapping: WheelModifierMapping = .standard,
                size: WheelSize = .medium, exclusions: WheelExclusions = WheelExclusions(),
                activation: WheelActivation = .anyTime, showDelay: Double = 0, items: [WheelRing: [String]] = [:]) {
        self.isEnabled = isEnabled
        self.mapping = mapping
        self.size = size
        self.exclusions = exclusions
        self.activation = activation
        self.showDelay = min(max(showDelay, 0), Self.maxDelay)
        self.items = items.filter { !$0.value.isEmpty }
    }

    /// Reads settings, falling back to the defaults (wheel on, ⇧ ⌘ ⌃, medium) for anything unset.
    public static func load(from defaults: UserDefaults) -> WheelSettings {
        var triggers: [WheelRing: WheelTrigger] = [:]
        var items: [WheelRing: [String]] = [:]
        for ring in WheelRing.allCases {
            switch defaults.string(forKey: keyKey(ring)) {
            case nil: triggers[ring] = WheelModifierMapping.standard.trigger(for: ring)
            case noKey?: break
            case let raw?: triggers[ring] = WheelTrigger(storageValue: raw)
            }
            items[ring] = defaults.stringArray(forKey: itemsKey(ring))
        }
        return WheelSettings(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            mapping: WheelModifierMapping(triggers: triggers),
            size: defaults.string(forKey: sizeKey).flatMap(WheelSize.init(rawValue:)) ?? .medium,
            exclusions: WheelExclusions(defaults.stringArray(forKey: excludedKey) ?? []),
            activation: defaults.string(forKey: activationKey).flatMap(WheelActivation.init(rawValue:)) ?? .anyTime,
            showDelay: defaults.object(forKey: delayKey) as? Double ?? 0,
            items: items.compactMapValues { $0 }
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(size.rawValue, forKey: Self.sizeKey)
        defaults.set(exclusions.bundleIDs, forKey: Self.excludedKey)
        defaults.set(activation.rawValue, forKey: Self.activationKey)
        defaults.set(showDelay, forKey: Self.delayKey)
        for ring in WheelRing.allCases {
            defaults.set(mapping.trigger(for: ring)?.storageValue ?? Self.noKey, forKey: Self.keyKey(ring))
            if let chosen = items[ring], !chosen.isEmpty {
                defaults.set(chosen, forKey: Self.itemsKey(ring))
            } else {
                defaults.removeObject(forKey: Self.itemsKey(ring))
            }
        }
    }
}
