#if os(macOS)
import AppKit

/// PROBE, not for merge: what an assistive client asks of the scroll view's text and what the
/// reader does about it, written to the file `-ReaderProbeLog` names, and switches for what
/// the reader does after a step of its own in continuous scroll.
@MainActor enum ReaderProbe {
    private static let defaults = UserDefaults.standard
    private static let path = defaults.string(forKey: "ReaderProbeLog")
    /// Which element posts the layout change after the reader's own move: `window` as on main,
    /// `none`, `text`, `scroll` (the text view's unignored ancestor) or `ancestor` (the canvas's).
    static let layout = defaults.string(forKey: "ReaderProbeLayout") ?? "window"
    /// `layoutFirst` posts the layout change before the insertion point is moved.
    static let order = defaults.string(forKey: "ReaderProbeOrder") ?? ""
    /// `beforeScroll` puts the insertion point on the step's first line before the view scrolls.
    static let caret = defaults.string(forKey: "ReaderProbeCaret") ?? ""
    /// `selection` posts a selection change by the text view after the layout change.
    static let after = defaults.string(forKey: "ReaderProbeAfter") ?? ""
    /// `follow` is main: an insertion point the reader placed follows any scroll. `byHand`
    /// keeps it where it is through a scroll an assistive client made.
    static let follow = defaults.string(forKey: "ReaderProbeFollow") ?? "follow"
    /// `selection` refuses an insertion point an assistive client sets off screen straight
    /// after the reader's own move; `scroll` puts the view back after it too.
    static let hold = defaults.string(forKey: "ReaderProbeHold") ?? ""

    static var isOn: Bool { path != nil }
    /// Set while an accessibility setter or action of the text view runs.
    static var client = 0

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ text: @autoclosure () -> String, stack: Bool = false) {
        guard let path else { return }
        var line = "\(stamp.string(from: Date())) READER \(text())"
        if stack {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(22).map { frame -> String in
                let parts = frame.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                return parts.count == 4 ? String(parts[3]).replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression) : frame
            }
            line += "\n    | " + frames.joined(separator: "\n    | ")
        }
        line += "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
