import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func range(_ value: CFTypeRef?) -> CFRange? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    // AppKit reports a missing range as NSNotFound, not kCFNotFound.
    return AXValueGetValue(value as! AXValue, .cfRange, &range) && range.location >= 0 && range.location != NSNotFound ? range : nil
}
func size(_ element: AXUIElement) -> CGSize {
    var size = CGSize.zero
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return size
}
func minX(_ element: AXUIElement) -> CGFloat {
    var point = CGPoint.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
    return point.x
}
/// The opening characters of a text value and the span of its numbered fixture words.
func describe(_ text: String) -> String {
    let words = text.split { !$0.isLetter && !$0.isNumber }.filter { $0.count == 8 && $0.hasPrefix("word") }
    let span = words.isEmpty ? "" : " WORDS \(words.first!)–\(words.last!) COUNT \(words.count)"
    return String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ") + span
}
func shortValue(_ element: AXUIElement) -> String { describe(string(element, kAXValueAttribute)) }

let steps = Array(CommandLine.arguments.dropFirst(3))
guard CommandLine.arguments.count >= 2,
      let pid = pid_t(CommandLine.arguments[1]), pid > 0 else {
    fputs("Usage: voiceover-ax-observer PID [seconds] [next|previous|larger|smaller|width=POINTS|focus[=COLUMN|=search]|lines|links|caret=TEXT|press=TEXT|wait=SECONDS ...]\n"
        + "A single step of - reads one step per line from standard input.\n", stderr)
    exit(1)
}
let duration = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0 : 20
guard duration > 0, duration <= 300,
      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.epubreaderlib.voiceoververify.mac" else {
    fputs("Use the isolated verification reader PID and a duration of 1–300 seconds.\n", stderr)
    exit(1)
}
let clock = ISO8601DateFormatter()
clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
/// Every line carries its time, so events, steps and recorded speech merge into one transcript.
func log(_ text: String) {
    print("\(clock.string(from: Date())) \(text)")
    fflush(stdout)
}
log("TRUSTED \(AXIsProcessTrusted()) PID \(pid)")
guard AXIsProcessTrusted() else { exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)

/// A fresh traversal: every call reads the application's current hierarchy.
func elements(_ role: String) -> [AXUIElement] {
    var result: [AXUIElement] = [], visited = 0
    func collect(_ element: AXUIElement, depth: Int) {
        guard depth < 20, visited < 400 else { return }
        visited += 1
        if string(element, kAXRoleAttribute) == role { result.append(element) }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) { collect(child, depth: depth + 1) }
    }
    for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) { collect(window, depth: 0) }
    return result
}
/// The reading columns, left to right.
func columns() -> [AXUIElement] { elements(kAXTextAreaRole).sorted { minX($0) < minX($1) } }
func lines(_ text: AXUIElement) -> [(range: CFRange, text: String)] {
    var result: [(CFRange, String)] = []
    while result.count < 500, let line = range(parameterized(text, kAXRangeForLineParameterizedAttribute, result.count as CFNumber)) {
        var copy = line
        let value = AXValueCreate(.cfRange, &copy).flatMap { parameterized(text, kAXStringForRangeParameterizedAttribute, $0) }
        result.append((line, (value as? String ?? "<no string>").trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return result
}

/// What an element embedded in text says of itself: a link, or an attachment's own element.
func embedded(_ element: AXUIElement) -> String {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    let said = [("TITLE", kAXTitleAttribute), ("LABEL", kAXDescriptionAttribute), ("VALUE", kAXValueAttribute), ("HELP", kAXHelpAttribute)]
        .compactMap { name, key in (attribute(element, key) as? String).flatMap { $0.isEmpty ? nil : "\(name) \"\($0)\"" } }
    let url = (attribute(element, kAXURLAttribute) as? URL).map { " URL \($0.absoluteString)" } ?? ""
    let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { string($0, kAXRoleAttribute) }
    return ([string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute)].filter { !$0.isEmpty } + said).joined(separator: " ")
        + url + " ACTIONS \((names as? [String] ?? []).joined(separator: ",").isEmpty ? "none" : (names as? [String] ?? []).joined(separator: ","))"
        + (children.isEmpty ? "" : " CHILDREN \(children.joined(separator: ","))")
}
/// Each run of a text's accessibility string that holds a link or an attachment, with the
/// element the text gives for it: what VoiceOver is told at those characters.
func embeddedRuns(_ text: AXUIElement) -> [(range: NSRange, words: String, link: AXUIElement?, attachment: AXUIElement?)] {
    var whole = CFRange(location: 0, length: attribute(text, kAXNumberOfCharactersAttribute) as? Int ?? 0)
    guard whole.length > 0, let value = AXValueCreate(.cfRange, &whole),
          let found = parameterized(text, kAXAttributedStringForRangeParameterizedAttribute, value),
          CFGetTypeID(found) == CFAttributedStringGetTypeID() else { return [] }
    let attributed = found as! NSAttributedString
    var result: [(NSRange, String, AXUIElement?, AXUIElement?)] = []
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
        func element(_ key: String) -> AXUIElement? {
            guard let value = attributes[NSAttributedString.Key(key)], CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let link = element("AXLink"), attachment = element("AXAttachment")
        guard link != nil || attachment != nil else { return }
        func same(_ one: AXUIElement?, _ other: AXUIElement?) -> Bool {
            if let one, let other { return CFEqual(one, other) }
            return one == nil && other == nil
        }
        // A run of one link or attachment can be split by its font or colour.
        if let last = result.last, NSMaxRange(last.0) == range.location, same(last.2, link), same(last.3, attachment) {
            result[result.count - 1].0.length += range.length
            result[result.count - 1].1 += (attributed.string as NSString).substring(with: range)
        } else {
            result.append((range, (attributed.string as NSString).substring(with: range), link, attachment))
        }
    }
    return result
}
/// The links and attachments of every column: the text's own children, then the runs of its
/// accessibility string.
func links() {
    for (index, text) in columns().enumerated() {
        let children = attribute(text, kAXChildrenAttribute) as? [AXUIElement] ?? []
        log("CHILDREN \(index) COUNT \(children.count)")
        for (number, child) in children.prefix(40).enumerated() { log("CHILD \(index).\(number) \(embedded(child))") }
        let runs = embeddedRuns(text)
        log("LINKS \(index) RUNS \(runs.count) OF \(runs.filter { $0.link != nil }.count) LINKS")
        for run in runs.prefix(60) {
            let words = run.words.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "<attachment>")
            log("LINK \(index) RANGE \(run.range.location),\(run.range.length) TEXT \"\(words.prefix(60))\""
                + " LINK \(run.link.map(embedded) ?? "none") ATTACHMENT \(run.attachment.map(embedded) ?? "none")")
        }
    }
}
/// The first link or attachment element, of a column's children or its runs, that names `words`.
func embeddedElement(naming words: String) -> AXUIElement? {
    func names(_ element: AXUIElement) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { (attribute(element, $0) as? String)?.contains(words) ?? false }
    }
    for text in columns() {
        if let child = (attribute(text, kAXChildrenAttribute) as? [AXUIElement] ?? []).first(where: names) { return child }
        for run in embeddedRuns(text) {
            if let link = run.link, names(link) || run.words.contains(words) { return link }
            if let attachment = run.attachment, names(attachment) { return attachment }
        }
    }
    return nil
}

var registered: [AXUIElement] = []
var observer: AXObserver?
let result = AXObserverCreate(pid, { _, element, notification, source in
    let selection = range(attribute(element, kAXSelectedTextRangeAttribute)).map { " SELECTION \($0.location),\($0.length)" } ?? ""
    log("EVENT \(notification) VIA \(source.map { "TEXT \(Int(bitPattern: $0) - 1)" } ?? "APP")\(selection) VALUE \(shortValue(element))")
}, &observer)
guard let observer else { log("OBSERVER \(result.rawValue)"); exit(3) }
/// Text areas come and go with the column count; the application registration covers the gaps.
func registerTexts() {
    for element in columns() where !registered.contains(where: { CFEqual($0, element) }) {
        registered.append(element)
        log("TEXT \(registered.count - 1) VALUE \(shortValue(element))")
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification] {
            let status = AXObserverAddNotification(observer, element, name as CFString, UnsafeMutableRawPointer(bitPattern: registered.count))
            log("REGISTER \(registered.count - 1) \(name) STATUS \(status.rawValue)")
        }
    }
}
/// Fresh external reads, independent of any XCTest snapshot.
func state(showLines: Bool = false) {
    let texts = columns()
    let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first.map(size) ?? .zero
    log("STATE WINDOW \(Int(window.width))x\(Int(window.height)) TEXTCOUNT \(texts.count)")
    for (index, text) in texts.enumerated() {
        let all = lines(text), selection = range(attribute(text, kAXSelectedTextRangeAttribute))
        // The line VoiceOver enters at is the insertion point's, by the text's own account.
        let entry = (attribute(text, kAXInsertionPointLineNumberAttribute) as? Int).flatMap { all.indices.contains($0) ? all[$0].text : nil }
        let visible = range(attribute(text, kAXVisibleCharacterRangeAttribute))
        log("STATE TEXT \(index) WIDTH \(Int(size(text).width)) CHARS \(attribute(text, kAXNumberOfCharactersAttribute) as? Int ?? -1)"
            + " LINES \(all.count) SELECTION \(selection.map { "\($0.location),\($0.length)" } ?? "none")"
            + " VISIBLE \(visible.map { "\($0.location),\($0.length)" } ?? "none") ENTRY \(entry.map { String($0.prefix(40)) } ?? "none") VALUE \(shortValue(text))")
        guard showLines else { continue }
        for (line, entry) in all.enumerated() { log("LINE \(index).\(line) RANGE \(entry.range.location),\(entry.range.length) TEXT \(entry.text)") }
    }
}
func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func press(_ role: String, _ labels: String...) -> Bool {
    // Identify controls by label or help; indexes change with the layout.
    for label in labels {
        guard let element = elements(role).first(where: {
            string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label || string($0, kAXHelpAttribute).hasPrefix(label)
        }) else { continue }
        log("PRESS \(label) STATUS \(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue)")
        return true
    }
    log("MISSING \(role) \(labels.joined(separator: " or "))")
    return false
}
func perform(_ step: String) {
    log("STEP \(step)")
    let parts = step.split(separator: "=").map(String.init)
    var pause = 3.0 // A resize or typography change repaginates after it ends.
    switch parts.first {
    // In continuous scroll the page buttons step a screen and are named for that.
    case "next": _ = press(kAXButtonRole, "Next Page", "Scroll Forward")
    case "previous": _ = press(kAXButtonRole, "Previous Page", "Scroll Backward")
    case "larger", "smaller":
        // The menu tracks events until an item is chosen, so its press may report a timeout.
        if press(kAXMenuButtonRole, "Appearance") {
            settle(1)
            _ = press(kAXMenuItemRole, parts[0] == "larger" ? "Larger Text" : "Smaller Text")
        }
    case "width":
        guard let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first, let width = parts.last.flatMap(Double.init) else { break }
        var target = CGSize(width: width, height: size(window).height)
        let status = AXValueCreate(.cgSize, &target).map { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, $0) }
        log("RESIZE \(Int(width)) STATUS \(status?.rawValue ?? -1)")
    case "focus":
        // Keyboard focus without a click, which would move the insertion point VoiceOver enters at.
        // `focus=search` leaves the columns, as VoiceOver's own navigation to the page buttons does.
        let texts = parts.last == "search" ? elements(kAXTextFieldRole) : columns()
        let index = parts.count > 1 ? Int(parts[1]) ?? 0 : texts.count - 1
        guard texts.indices.contains(index) else { log("MISSING \(step)"); break }
        NSRunningApplication(processIdentifier: pid)?.activate()
        log("FOCUS \(parts.last == "search" ? "search" : "\(index)") STATUS \(AXUIElementSetAttributeValue(texts[index], kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
        pause = 1
    case "wait": pause = parts.last.flatMap(Double.init) ?? 0
    case "lines": pause = 0
    case "links":
        links()
        pause = 0
    case "caret":
        // The insertion point before the first of these words: VoiceOver enters a text there.
        let words = parts.dropFirst().joined(separator: "=")
        guard let (index, text, offset) = columns().enumerated().lazy.compactMap({ index, text -> (Int, AXUIElement, Int)? in
            let found = (string(text, kAXValueAttribute) as NSString).range(of: words)
            return found.location == NSNotFound ? nil : (index, text, found.location)
        }).first else { log("MISSING \(step)"); break }
        var place = CFRange(location: offset, length: 0)
        let status = AXValueCreate(.cfRange, &place).map { AXUIElementSetAttributeValue(text, kAXSelectedTextRangeAttribute as CFString, $0) }
        log("CARET \(index) AT \(offset) STATUS \(status?.rawValue ?? -1)")
        pause = 1
    case "press":
        // A link's own press, without VoiceOver: what the reader does when an assistive client follows it.
        let words = parts.dropFirst().joined(separator: "=")
        guard let element = embeddedElement(naming: words) else { log("MISSING \(step)"); break }
        log("PRESS \(words) ON \(embedded(element)) STATUS \(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue)")
    default: log("UNKNOWN STEP \(step)"); pause = 0
    }
    settle(pause)
    registerTexts()
    state(showLines: parts.first == "lines")
    log("STEPPED \(step)")
}

registerTexts()
log("OBSERVER \(result.rawValue) TEXTCOUNT \(registered.count)")
for name in [kAXLayoutChangedNotification, kAXValueChangedNotification] {
    log("REGISTER APP \(name) STATUS \(AXObserverAddNotification(observer, app, name as CFString, nil).rawValue)")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
log("READY")
let deadline = Date().addingTimeInterval(duration)
if steps == ["-"] {
    // One step per line, for a runner that interleaves VoiceOver commands while this observes.
    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { handle.readabilityHandler = nil; return }
        let received = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        DispatchQueue.main.async { for step in received where Date() < deadline { perform(step) } }
    }
}
if steps.isEmpty || steps == ["-"] {
    RunLoop.current.run(until: deadline)
} else {
    state()
    for step in steps where Date() < deadline { perform(step) }
}
for (index, element) in registered.enumerated() { log("FINAL \(index) VALUE \(shortValue(element))") }
log("DONE")
