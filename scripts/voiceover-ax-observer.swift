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
    fputs("Usage: voiceover-ax-observer PID [seconds] [next|previous|press=LABEL|larger|smaller|width=POINTS|focus[=COLUMN|=COLUMN.CELL|=search]|lines|links|actions[=all]|action=NAME|caret=WORDS|follow=WORDS|wait=SECONDS ...]\n"
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
/// Whether a text area is a table cell: a text view of its own inside a column's.
func isCell(_ text: AXUIElement) -> Bool {
    guard let parent = attribute(text, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
    return string(parent as! AXUIElement, kAXRoleAttribute) == kAXTextAreaRole
}
/// The reading columns, left to right.
func columns() -> [AXUIElement] { elements(kAXTextAreaRole).filter { !isCell($0) }.sorted { minX($0) < minX($1) } }
func lines(_ text: AXUIElement) -> [(range: CFRange, text: String)] {
    var result: [(CFRange, String)] = []
    while result.count < 500, let line = range(parameterized(text, kAXRangeForLineParameterizedAttribute, result.count as CFNumber)) {
        var copy = line
        let value = AXValueCreate(.cfRange, &copy).flatMap { parameterized(text, kAXStringForRangeParameterizedAttribute, $0) }
        result.append((line, (value as? String ?? "<no string>").trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return result
}

/// An element's actions as the accessibility API lists them.
func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return names as? [String] ?? []
}
/// The name of an action an application gives an element itself, which VoiceOver offers in
/// its Actions menu. AppKit lists one as "Name:NAME", a line break, and its target and selector.
func named(_ action: String) -> String? {
    action.hasPrefix("Name:") ? String(action.dropFirst(5).prefix { !$0.isNewline }) : nil
}
/// An element's actions on one line, a named one as its name in quotation marks.
func actions(_ element: AXUIElement) -> String {
    let names = actionNames(element).map { action in named(action).map { "\"\($0)\"" } ?? action }
    return names.isEmpty ? "none" : names.joined(separator: ",")
}
/// What an element embedded in text says of itself: a link, or an attachment's own element.
func embedded(_ element: AXUIElement) -> String {
    let said = [("TITLE", kAXTitleAttribute), ("LABEL", kAXDescriptionAttribute), ("VALUE", kAXValueAttribute), ("HELP", kAXHelpAttribute)]
        .compactMap { name, key in (attribute(element, key) as? String).flatMap { $0.isEmpty ? nil : "\(name) \"\($0)\"" } }
    let url = (attribute(element, kAXURLAttribute) as? URL).map { " URL \($0.absoluteString)" } ?? ""
    let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { string($0, kAXRoleAttribute) }
    return ([string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute)].filter { !$0.isEmpty } + said).joined(separator: " ")
        + url + " ACTIONS \(actions(element))"
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
/// The cells of a column's table rows on screen, in reading order. A row is one character of
/// the column's text, whose attachment element holds a text area for each of its cells.
func cells(_ column: AXUIElement) -> [AXUIElement] {
    embeddedRuns(column).flatMap { run in
        (run.attachment.flatMap { attribute($0, kAXChildrenAttribute) as? [AXUIElement] } ?? [])
            .filter { string($0, kAXRoleAttribute) == kAXTextAreaRole }
    }
}
/// Every column with its number, each followed by its cells, numbered within it.
func texts() -> [(name: String, text: AXUIElement, isCell: Bool)] {
    columns().enumerated().flatMap { index, column in
        [("\(index)", column, false)] + cells(column).enumerated().map { ("\(index).\($0.offset)", $0.element, true) }
    }
}
/// The links and attachments of every column and of every cell in it: the text's own children,
/// then the runs of its accessibility string. A cell's lines begin with CELL.
func links() {
    for (name, text, isCell) in texts() {
        let kind = isCell ? "CELL " : ""
        if isCell { log("CELL \(name) VALUE \"\(string(text, kAXValueAttribute).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "<attachment>").prefix(60))\"") }
        let children = attribute(text, kAXChildrenAttribute) as? [AXUIElement] ?? []
        log("\(kind)CHILDREN \(name) COUNT \(children.count)")
        for (number, child) in children.prefix(40).enumerated() { log("\(kind)CHILD \(name).\(number) \(embedded(child))") }
        let runs = embeddedRuns(text)
        log("\(kind)LINKS \(name) RUNS \(runs.count) OF \(runs.filter { $0.link != nil }.count) LINKS")
        for run in runs.prefix(60) {
            let words = run.words.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "<attachment>")
            log("\(kind)LINK \(name) RANGE \(run.range.location),\(run.range.length) TEXT \"\(words.prefix(60))\""
                + " LINK \(run.link.map(embedded) ?? "none") ATTACHMENT \(run.attachment.map(embedded) ?? "none")")
        }
    }
}
/// The first link or attachment element, of a column's or a cell's children or runs, that
/// names `words`.
func embeddedElement(naming words: String) -> AXUIElement? {
    func names(_ element: AXUIElement) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { (attribute(element, $0) as? String)?.contains(words) ?? false }
    }
    for (_, text, _) in texts() {
        if let child = (attribute(text, kAXChildrenAttribute) as? [AXUIElement] ?? []).first(where: { string($0, kAXRoleAttribute) == "AXLink" && names($0) }) { return child }
        for run in embeddedRuns(text) {
            // A link over a picture is the picture's link, whichever of the two has its words.
            if let link = run.link, names(link) || run.words.contains(words) || run.attachment.map(names) ?? false { return link }
            // A table row off screen is an image named by all its cells' words, and no link.
            if let attachment = run.attachment, string(attachment, kAXRoleAttribute) == "AXLink", names(attachment) { return attachment }
        }
    }
    return nil
}

/// A column, whatever holds it up to the window, and any other element with a named action,
/// each with its depth: where a named action is, and so what VoiceOver's cursor must be on
/// for its Actions menu to hold it. With `everything`, each element of the window.
func holders(everything: Bool = false) -> [(depth: Int, element: AXUIElement)] {
    var visited = 0
    func walk(_ element: AXUIElement, depth: Int) -> [(Int, AXUIElement)] {
        guard depth < 20, visited < 400 else { return [] }
        visited += 1
        // A column's own children are its links and attachments, which `links` prints.
        let column = string(element, kAXRoleAttribute) == kAXTextAreaRole
        let below = column ? [] : (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { walk($0, depth: depth + 1) }
        return everything || column || !below.isEmpty || actionNames(element).contains { named($0) != nil } ? [(depth, element)] + below : []
    }
    return (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap { walk($0, depth: 0) }
}
func called(_ element: AXUIElement) -> String {
    let said = [("TITLE", kAXTitleAttribute), ("LABEL", kAXDescriptionAttribute)]
        .compactMap { name, key in (attribute(element, key) as? String).flatMap { $0.isEmpty ? nil : "\(name) \"\($0)\"" } }
    return ([string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute)].filter { !$0.isEmpty } + said).joined(separator: " ")
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
func press(_ roles: [String], _ labels: String...) -> Bool {
    // Identify controls by label or help; indexes change with the layout.
    for label in labels {
        guard let element = roles.lazy.flatMap(elements).first(where: {
            string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label || string($0, kAXHelpAttribute).hasPrefix(label)
        }) else { continue }
        log("PRESS \(label) STATUS \(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue)")
        return true
    }
    log("MISSING \(roles.joined(separator: " or ")) \(labels.joined(separator: " or "))")
    return false
}
func perform(_ step: String) {
    log("STEP \(step)")
    let parts = step.split(separator: "=").map(String.init)
    var pause = 3.0 // A resize or typography change repaginates after it ends.
    switch parts.first {
    // In continuous scroll the page buttons step a screen and are named for that.
    case "next": _ = press([kAXButtonRole], "Next Page", "Scroll Forward")
    case "previous": _ = press([kAXButtonRole], "Previous Page", "Scroll Backward")
    // Any other button, such as the sample's Use Toolbar, which moves its controls out of the reader's group,
    // or a segment of its Reading Mode control, Continuous Scroll or Paging.
    case "press": _ = press([kAXButtonRole, kAXRadioButtonRole], parts.dropFirst().joined(separator: "="))
    case "larger", "smaller":
        // The menu tracks events until an item is chosen, so its press may report a timeout.
        if press([kAXMenuButtonRole], "Appearance") {
            settle(1)
            _ = press([kAXMenuItemRole], parts[0] == "larger" ? "Larger Text" : "Smaller Text")
        }
    case "width":
        guard let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first, let width = parts.last.flatMap(Double.init) else { break }
        var target = CGSize(width: width, height: size(window).height)
        let status = AXValueCreate(.cgSize, &target).map { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, $0) }
        log("RESIZE \(Int(width)) STATUS \(status?.rawValue ?? -1)")
    case "focus":
        // Keyboard focus without a click, which would move the insertion point VoiceOver enters at.
        // `focus=search` leaves the columns, as VoiceOver's own navigation to the page buttons does.
        // `focus=0.2` is a cell, by the name `links` prints for it: the first column's third.
        if parts.count > 1, parts[1].contains(".") {
            guard let cell = texts().first(where: { $0.name == parts[1] })?.text else { log("MISSING \(step)"); break }
            NSRunningApplication(processIdentifier: pid)?.activate()
            log("FOCUS \(parts[1]) STATUS \(AXUIElementSetAttributeValue(cell, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
            pause = 1
            break
        }
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
        // The insertion point before the first of these words, in a column or in a cell:
        // VoiceOver enters a text there.
        let words = parts.dropFirst().joined(separator: "=")
        guard let (index, text, offset) = texts().lazy.compactMap({ name, text, _ -> (String, AXUIElement, Int)? in
            let found = (string(text, kAXValueAttribute) as NSString).range(of: words)
            return found.location == NSNotFound ? nil : (name, text, found.location)
        }).first else { log("MISSING \(step)"); break }
        var place = CFRange(location: offset, length: 0)
        let status = AXValueCreate(.cfRange, &place).map { AXUIElementSetAttributeValue(text, kAXSelectedTextRangeAttribute as CFString, $0) }
        log("CARET \(index) AT \(offset) STATUS \(status?.rawValue ?? -1)")
        pause = 1
    case "actions":
        // Numbered, because a transcript sorts its lines and several of these share a millisecond.
        for (number, holder) in holders(everything: parts.last == "all").enumerated() {
            log("ELEMENT \(String(format: "%03d", number)) DEPTH \(holder.depth) \(called(holder.element)) ACTIONS \(actions(holder.element))")
        }
        pause = 0
    case "action":
        // A named action's own performance, without VoiceOver, on the first element that has it.
        let name = parts.dropFirst().joined(separator: "=")
        guard let (element, action) = holders().lazy.compactMap({ holder in
            actionNames(holder.element).first { named($0) == name }.map { (holder.element, $0) }
        }).first else { log("MISSING \(step)"); break }
        log("ACTION \(name) ON \(called(element)) STATUS \(AXUIElementPerformAction(element, action as CFString).rawValue)")
    case "follow":
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
