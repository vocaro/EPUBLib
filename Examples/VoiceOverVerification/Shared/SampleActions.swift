#if os(iOS)
import Observation
import UIKit

/// `-SampleActions PLAN` performs accessibility actions of the reader's items with nothing
/// activated: the change VoiceOver makes when an action is chosen from its rotor, made by the
/// host instead, as `-SampleStepAfter` turns a page (doc/testing.md, "Simulators"). A
/// simulator's VoiceOver does not perform what its rotor offers; a device's does.
///
/// The plan is a list of stops separated by `;`, each the first words of an item and the
/// actions to perform on it, separated by `+`, with `_` for a space, since the probe's launch
/// arguments are separated by spaces: `Begin_Consider=Select_Line+Unselect_First_Word`. When
/// VoiceOver's cursor first comes to an item whose label begins with a stop's words, or holds
/// them where they follow a `*` (`*world_began=Copy`), its actions are performed one by one,
/// `-SampleActionsEvery` seconds apart (6 by default), on whatever item the cursor is on by
/// then. `done` says what became of each, for the sample's selection line.
@MainActor @Observable final class SampleActions: NSObject {
    @ObservationIgnored private var stops: [(words: String, actions: [String])]
    @ObservationIgnored private let every: Double
    @ObservationIgnored private var running = false
    /// Each action performed so far, and whether the item had it: "Select Line performed".
    private(set) var done: [String] = []

    init?(defaults: UserDefaults = .standard) {
        guard let plan = defaults.string(forKey: "SampleActions"), !plan.isEmpty else { return nil }
        stops = plan.split(separator: ";").compactMap { stop in
            let parts = stop.replacingOccurrences(of: "_", with: " ").split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1].split(separator: "+").map(String.init))
        }
        every = defaults.double(forKey: "SampleActionsEvery") > 0 ? defaults.double(forKey: "SampleActionsEvery") : 6
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(focused(_:)), name: UIAccessibility.elementFocusedNotification, object: nil)
    }

    @objc private func focused(_ notification: Notification) {
        guard !running, let label = (notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject)?.accessibilityLabel,
              let index = stops.firstIndex(where: { $0.words.hasPrefix("*") ? label.contains($0.words.dropFirst()) : label.hasPrefix($0.words) })
        else { return }
        let stop = stops.remove(at: index)
        running = true
        Task { @MainActor in
            for name in stop.actions {
                try? await Task.sleep(for: .seconds(every))
                perform(name)
            }
            running = false
        }
    }

    /// Performs the action named so of the item under VoiceOver's cursor, as VoiceOver does.
    private func perform(_ name: String) {
        let item = UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject
        guard let action = item?.accessibilityCustomActions?.first(where: { $0.name == name }) else {
            done.append("\(name) not offered")
            return
        }
        done.append("\(name) \(action.actionHandler?(action) == true ? "performed" : "failed")")
    }
}
#endif
