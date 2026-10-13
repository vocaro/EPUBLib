#if os(macOS)
import AppKit

/// TRIAL, not for main: what an assistive client asks of the scroll view's text, its links and
/// its table cells, and what the reader does about it, written to `reader-probe.log` in the
/// reader's temporary directory when it is launched with `-ReaderProbeLog YES`.
@MainActor enum ReaderProbe {
    static let isOn = UserDefaults.standard.bool(forKey: "ReaderProbeLog")
    /// A change tried at launch, by name.
    static let fix = UserDefaults.standard.string(forKey: "ReaderProbeFix") ?? ""
    private static let path = FileManager.default.temporaryDirectory.appendingPathComponent("reader-probe.log").path
    private static var started = false
    /// What an observer asks for hundreds of times over to read the lines of a text.
    private static let bulk: Set<String> = ["AXRangeForLine", "AXStringForRange", "RangeForLine", "StringForRange",
                                            "AXAttributedStringForRange", "AttributedStringForRange"]
    private static var bulkSeen: Set<String> = []
    private static var bulkCount = 0
    private static var lastLine = ""
    private static var sameCount = 0

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes a line. A run of the questions an observer asks to read a text's lines is the
    /// first of each and a count, and a line said again straight away is a count.
    static func log(_ text: @autoclosure () -> String, kind: String? = nil, stack: Bool = false) {
        guard isOn else { return }
        if !started {
            started = true
            write("START pid \(ProcessInfo.processInfo.processIdentifier) \(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))")
        }
        if let kind, bulk.contains(kind) {
            if bulkSeen.contains(kind) {
                bulkCount += 1
                return
            }
            bulkSeen.insert(kind)
        } else {
            if bulkCount > 0 { write("  and \(bulkCount) more of \(bulkSeen.sorted().joined(separator: ", "))") }
            bulkCount = 0
            bulkSeen = []
        }
        var line = text()
        if line == lastLine {
            sameCount += 1
            return
        }
        if sameCount > 0 { write("  the same \(sameCount) more times") }
        sameCount = 0
        lastLine = line
        if stack {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(18).map { frame -> String in
                let parts = frame.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                return parts.count == 4 ? String(parts[3]).replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression) : frame
            }
            line += "\n    | " + frames.joined(separator: "\n    | ")
        }
        write(line)
    }

    private static func write(_ text: String) {
        let line = "\(stamp.string(from: Date())) READER \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    nonisolated static func short(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let range = (value as? NSValue), String(cString: range.objCType).contains("NSRange") { return "\(range.rangeValue.location),\(range.rangeValue.length)" }
        return String(String(describing: value).replacingOccurrences(of: "\n", with: " ").prefix(70))
    }
}

extension ReaderTextView {
    /// TRIAL, not for main: a line of the scroll view's log.
    func probe(_ text: @autoclosure () -> String, kind: String? = nil, stack: Bool = false) {
        if ReaderProbe.isOn, !isPageColumn, canvas != nil { ReaderProbe.log(text(), kind: kind, stack: stack) }
    }

    /// TRIAL, not for main: where the view stands and what it holds.
    var probeState: String {
        let rows = Set((tableInteraction?.cells ?? [:]).keys.map(\.location)).sorted()
        return "sel \(selectedRange.location),\(selectedRange.length) clip \(Int(visibleRect.minY))+\(Int(visibleRect.height)) height \(Int(frame.height))"
            + " kept \(tableInteraction?.keptRow.map(String.init) ?? "none") rows \(rows)"
    }
}
#endif
