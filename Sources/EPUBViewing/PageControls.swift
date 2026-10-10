import CoreGraphics
import SwiftUI

/// Direct page input for the bundled native reader. Change this value on a mounted view
/// with `epubReaderPageControls(_:)`; no book reload or change of reading state is needed.
public struct EPUBPageControls: Equatable, Sendable {
    public var edgeTapsEnabled: Bool
    public var touchSwipesEnabled: Bool
    public var wheelEnabled: Bool
    /// Physical edge widths in points. Zero, negative and non-finite values disable that
    /// edge; positive widths are clipped to the reader width. In an overlap the right edge
    /// wins. A reserved vertical division never receives an edge turn.
    public var leftTapWidth: CGFloat
    public var rightTapWidth: CGFloat
    /// Replaces the defaults; an empty array disables built-in page shortcuts. Modifiers
    /// match exactly. The first binding for a key/modifier pair wins. Other shortcuts are
    /// left to the host/system, including selection chords unless explicitly assigned.
    public var keyboardBindings: [EPUBPageKeyBinding]

    public init(edgeTapsEnabled: Bool = true, touchSwipesEnabled: Bool = true,
                wheelEnabled: Bool = true, leftTapWidth: CGFloat = 56, rightTapWidth: CGFloat = 56,
                keyboardBindings: [EPUBPageKeyBinding] = EPUBPageKeyBinding.defaults) {
        self.edgeTapsEnabled = edgeTapsEnabled
        self.touchSwipesEnabled = touchSwipesEnabled
        self.wheelEnabled = wheelEnabled
        self.leftTapWidth = leftTapWidth
        self.rightTapWidth = rightTapWidth
        self.keyboardBindings = keyboardBindings
    }

    /// Only host commands and accessibility actions turn pages.
    public static let hostOnly = Self(edgeTapsEnabled: false, touchSwipesEnabled: false,
                                      wheelEnabled: false, keyboardBindings: [])
}

/// A logical page action: independent of the publication's visual reading direction.
public enum EPUBPageAction: Equatable, Sendable { case next, previous }

/// Portable hardware keys. Character bindings accept ASCII letters and digits (letters
/// are case-insensitive; use the Shift modifier to distinguish chords). Other characters
/// are ignored. System-reserved shortcuts may be consumed before reaching the reader.
public enum EPUBPageKey: Hashable, Sendable {
    case leftArrow, rightArrow, upArrow, downArrow, pageUp, pageDown, home, end, space
    case character(Character)

    var normalized: Self? {
        guard case .character(let character) = self else { return self }
        let value = String(character).lowercased()
        guard value.utf8.count == 1, let byte = value.utf8.first,
              (97...122).contains(byte) || (48...57).contains(byte), let first = value.first else { return nil }
        return .character(first)
    }
}

public struct EPUBPageKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let command = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
    static let supported: Self = [.shift, .command, .option, .control]
}

public struct EPUBPageKeyBinding: Equatable, Sendable {
    public var key: EPUBPageKey
    public var modifiers: EPUBPageKeyModifiers
    public var action: EPUBPageAction
    public init(_ key: EPUBPageKey, modifiers: EPUBPageKeyModifiers = [], action: EPUBPageAction) {
        self.key = key; self.modifiers = modifiers; self.action = action
    }
    public static let defaults: [Self] = [
        .init(.leftArrow, action: .previous), .init(.rightArrow, action: .next),
        .init(.pageUp, action: .previous), .init(.pageDown, action: .next),
        .init(.space, action: .next), .init(.space, modifiers: .shift, action: .previous),
    ]
}

public extension View {
    /// Configures built-in direct page input for the native reader, including live updates.
    /// Visual controls mirror in RTL books; left/right widths still name physical edges.
    /// Host commands and VoiceOver page actions remain available with `.hostOnly`.
    func epubReaderPageControls(_ controls: EPUBPageControls) -> some View {
        environment(\.epubReaderPageControls, controls)
    }
}

extension EnvironmentValues {
    @Entry var epubReaderPageControls = EPUBPageControls()
}

extension EPUBPageControls {
    var effectiveBindings: [EPUBPageKeyBinding] {
        var seen: [EPUBPageKey: Set<EPUBPageKeyModifiers>] = [:]
        return keyboardBindings.compactMap { binding in
            guard let key = binding.key.normalized,
                  binding.modifiers.subtracting(.supported).isEmpty,
                  seen[key, default: []].insert(binding.modifiers).inserted else { return nil }
            return EPUBPageKeyBinding(key, modifiers: binding.modifiers, action: binding.action)
        }
    }

    func direction(for key: EPUBPageKey, modifiers: EPUBPageKeyModifiers) -> Bool? {
        guard let key = key.normalized,
              let binding = effectiveBindings.first(where: { $0.key == key && $0.modifiers == modifiers }) else { return nil }
        return binding.action == .next
    }
}
