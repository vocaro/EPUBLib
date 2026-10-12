import XCTest
import XCUIAutomation

/// Operates the qualification host one step at a time and records what the accessibility tree
/// and the screen show after each step. It asserts nothing: a run that completes is not a
/// result. Read its log and screenshots; see doc/issue-49-51-controls-qualification.md.
///
/// `TEST_RUNNER_QUALIFICATION_OUT` names a directory holding `args.txt` (launch arguments, one
/// per line) and `steps.txt` (one step per line); the log, tree dumps and screenshots go there.
@MainActor final class ControlsProbe: XCTestCase {
    private var app: XCUIApplication!
    private var out: URL!
    private var step = 0
    private var autoshot = true
    private let clock = Date()

    func testOperate() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["QUALIFICATION_OUT"] else {
            throw XCTSkip("Set TEST_RUNNER_QUALIFICATION_OUT; see doc/issue-49-51-controls-qualification.md")
        }
        out = URL(fileURLWithPath: path)
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        }
        #if os(macOS)
        app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.controlsqualification.mac")
        #else
        app = XCUIApplication(bundleIdentifier: "org.epubreaderlib.controlsqualification")
        #endif
        app.launchArguments = lines("args.txt")
        app.launch()
        note("launch", app.launchArguments.joined(separator: " "))
        #if os(iOS)
        // A simulator keeps the way up the last scenario left it: every scenario starts upright.
        let found = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        if found != .portrait { RunLoop.current.run(until: Date().addingTimeInterval(2)) }
        let name = Self.orientations.first { $0.value == found }?.key ?? "unknown (\(found.rawValue))"
        note("orientation", "portrait, found \(name), window \(frame(app.windows.firstMatch.frame))")
        #endif
        let status = app.descendants(matching: .any)["qualification.status"]
        note("ready", status.waitForExistence(timeout: 60) ? statusLine() : "NO STATUS LINE")
        for line in lines("steps.txt") {
            step += 1
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            perform(parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    private func perform(_ command: String, _ argument: String) {
        #if os(macOS)
        // Synthesized keys and clicks go to whatever is in front. Another session's window or a
        // system dialog there must not receive them: stop acting until the host is frontmost again.
        if ["tap", "forcetap", "tapbegins", "tapcontains", "tapxy", "type", "key", "swipe", "scrolllist", "resize"].contains(command),
           app.state != .runningForeground {
            return note(command, "SKIPPED \(argument): the host is not the frontmost application")
        }
        #endif
        switch command {
        case "tap", "forcetap":
            // `forcetap` touches the element's centre even when XCTest calls it unhittable.
            guard let element = find(argument) else { return note(command, "\(argument): MISSING") }
            let before = describe(element)
            guard element.isHittable || command == "forcetap" else { return note(command, "NOT HITTABLE \(before)") }
            #if os(macOS)
            element.click()
            #else
            if element.isHittable { element.tap() } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            #endif
            note(command, before)
            settle()
        case "tapbegins", "tapcontains":
            // The first element whose label begins with TEXT, such as a result named "Match 6 of 14, …";
            // or whose label, title or identifier contains it, for a system control of unknown name.
            let format = command == "tapbegins" ? "label BEGINSWITH %@"
                : "label CONTAINS[c] %@ OR title CONTAINS[c] %@ OR identifier CONTAINS[c] %@"
            let element = app.descendants(matching: .any)
                .matching(NSPredicate(format: format, argumentArray: Array(repeating: argument, count: command == "tapbegins" ? 1 : 3))).firstMatch
            guard element.waitForExistence(timeout: 5) else { return note(command, "\(argument): MISSING") }
            let before = describe(element)
            guard element.isHittable else { return note(command, "NOT HITTABLE \(before)") }
            #if os(macOS)
            element.click()
            #else
            element.tap()
            #endif
            note(command, before)
            settle()
        case "tapxy":
            // A touch at a fraction of the window, such as outside a popover.
            let point = argument.split(separator: ",").compactMap { Double($0) }
            guard point.count == 2 else { return note(command, "BAD POINT") }
            let target = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: point[0], dy: point[1]))
            #if os(macOS)
            target.click()
            #else
            target.tap()
            #endif
            note(command, argument)
            settle()
        case "drag":
            // A finger drag from one fraction of the window to another, as `0.5,0.36,0.5,0.28`:
            // for what scrolls but is not the first list, such as the search sheet under its field.
            #if os(iOS)
            let points = argument.split(separator: ",").compactMap { Double($0) }
            guard points.count == 4 else { return note(command, "BAD POINTS") }
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: points[0], dy: points[1]))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: points[2], dy: points[3])))
            note(command, argument)
            settle()
            #else
            note(command, "iOS only")
            #endif
        case "type":
            // `\n` presses Return on the keyboard that is showing.
            app.typeText(argument.replacingOccurrences(of: "\\n", with: "\n"))
            note(command, argument)
            settle()
        case "key":
            // A hardware key, with modifiers as in `shift+tab` or `command+f`.
            var flags: XCUIElement.KeyModifierFlags = []
            var key = argument
            for (name, flag) in [("shift+", XCUIElement.KeyModifierFlags.shift), ("command+", .command), ("option+", .option), ("control+", .control)]
            where key.hasPrefix(name) {
                flags.insert(flag); key.removeFirst(name.count)
            }
            let keys: [String: XCUIKeyboardKey] = ["return": .return, "tab": .tab, "escape": .escape, "space": .space, "delete": .delete,
                                                   "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
                                                   "pageup": .pageUp, "pagedown": .pageDown]
            app.typeKey(keys[key]?.rawValue ?? key, modifierFlags: flags)
            note(command, argument + " -> focus: " + focused())
            settle()
        case "swipe":
            #if os(iOS)
            let reader = app.windows.firstMatch
            switch argument {
            case "left": reader.swipeLeft()
            case "right": reader.swipeRight()
            case "up": reader.swipeUp()
            default: reader.swipeDown()
            }
            #else
            app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: argument == "up" ? -200 : 200)
            #endif
            note(command, argument)
            settle()
        case "resize":
            // Mac only: drags the window's lower right corner to WIDTHxHEIGHT points.
            #if os(macOS)
            let size = argument.split(separator: "x").compactMap { Double($0) }
            let window = app.windows.firstMatch
            guard size.count == 2, window.exists else { return note(command, "BAD SIZE OR NO WINDOW") }
            let frame = window.frame
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
            let target = corner.withOffset(CGVector(dx: size[0] - frame.width, dy: size[1] - frame.height))
            corner.press(forDuration: 0.2, thenDragTo: target)
            note(command, "\(argument): window now \(self.frame(app.windows.firstMatch.frame))")
            settle()
            #else
            note(command, "Mac only")
            #endif
        case "scrolllist":
            // Drags the first list on screen, as a finger would: `up` shows later rows.
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            guard list.exists else { return note(command, "NO LIST") }
            #if os(iOS)
            if argument == "down" { list.swipeDown() } else { list.swipeUp() }
            #else
            list.scroll(byDeltaX: 0, deltaY: argument == "down" ? 200 : -200)
            #endif
            note(command, argument)
            settle()
        case "rotate":
            #if os(iOS)
            XCUIDevice.shared.orientation = Self.orientations[argument] ?? .portrait
            #endif
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            note(command, "\(argument), window \(frame(app.windows.firstMatch.frame))")
            settle()
        case "wait":
            RunLoop.current.run(until: Date().addingTimeInterval(Double(argument) ?? 1))
        case "waitfor", "waitgone":
            let element = app.descendants(matching: .any).matching(predicate(argument)).firstMatch
            let found = command == "waitfor" ? element.waitForExistence(timeout: 30) : element.waitForNonExistence(timeout: 30)
            note(command, "\(argument): \(found ? "yes" : "TIMED OUT")")
        case "watch":
            // When LABEL is on screen during the next SECONDS, for states too brief to tap after.
            let parts = argument.split(separator: ",", maxSplits: 1).map(String.init)
            let element = app.descendants(matching: .any).matching(predicate(parts[0])).firstMatch
            let deadline = Date().addingTimeInterval(Double(parts.last ?? "") ?? 5)
            var shown: Bool?
            while Date() < deadline {
                let exists = element.exists
                if exists != shown {
                    shown = exists
                    note(command, "\(parts[0]) \(exists ? "ON SCREEN \(describe(element))" : "not on screen")")
                    if exists { screenshot("watch") }
                }
            }
        case "find":
            // Every element named LABEL, in tree order.
            let matches = app.descendants(matching: .any).matching(predicate(argument)).allElementsBoundByIndex
            note(command, "\(argument): \(matches.count) match(es)")
            for (index, element) in matches.enumerated() { note(command, "  @\(index) \(describe(element))") }
        case "containing":
            // Every element whose label contains TEXT, with whether it lies inside the window.
            let window = app.windows.firstMatch.frame
            let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", argument)).allElementsBoundByIndex
            note(command, "\(argument): \(matches.count) element(s), window \(frame(window))")
            for element in matches {
                let visible = window.contains(element.frame) ? "inside window" : window.intersects(element.frame) ? "PARTLY inside" : "OUTSIDE window"
                note(command, "  \(visible) \(describe(element))")
            }
        case "status":
            note(command, statusLine())
        case "focus":
            note(command, focused())
        case "dump":
            dump(argument.isEmpty ? "tree" : argument)
        case "shot":
            screenshot(argument.isEmpty ? "screen" : argument)
        case "auto":
            autoshot = argument != "off"
        case "audit":
            // The system's accessibility audit of what is on screen. Every issue is recorded.
            do {
                var count = 0
                try app.performAccessibilityAudit { issue in
                    count += 1
                    let element = issue.element.map { self.describe($0) } ?? "no element"
                    self.note(command, "\(issue.compactDescription) | \(issue.detailedDescription) | \(element)")
                    return true
                }
                note(command, "\(count) issue(s)")
            } catch { note(command, "FAILED \(error)") }
        case "voiceover":
            // XCTest's VoiceOver service: `on`, `off`, `forward`, `backward`, `speech`, or `read`,
            // which moves forward until VoiceOver repeats itself.
            let service = XCUIDevice.shared.voiceOverService
            do {
                switch argument {
                case "on": try service.enable(); note(command, "on: \(service.isEnabled)")
                case "off": try service.disable(); note(command, "on: \(service.isEnabled)")
                case "forward": note(command, try service.moveForward().utterance)
                case "hint":
                    // What VoiceOver adds after a pause on the item it is on.
                    RunLoop.current.run(until: Date().addingTimeInterval(3))
                    note(command, "after 3 s: " + (try service.currentSpeech().utterance))
                case "backward": note(command, try service.moveBackward().utterance)
                case "read":
                    var last = "", repeated = 0
                    for _ in 0..<120 where repeated < 3 {
                        let heard = try service.moveForward().utterance
                        repeated = heard == last ? repeated + 1 : 0
                        last = heard
                        note(command, heard)
                    }
                default: note(command, try service.currentSpeech().utterance)
                }
            } catch { note(command, "\(argument) FAILED \(error)") }
        case "votouch", "voactivate":
            // Under VoiceOver a touch moves its cursor to the item; a double tap then activates it.
            #if os(iOS)
            guard let element = find(argument) else { return note(command, "\(argument): MISSING") }
            let service = XCUIDevice.shared.voiceOverService
            element.tap()
            note(command, "touched: " + ((try? service.currentSpeech().utterance) ?? "no speech"))
            if command == "voactivate" {
                element.doubleTap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                note(command, "activated: " + ((try? service.currentSpeech().utterance) ?? "no speech"))
            }
            settle()
            #else
            note(command, "iOS only; on the Mac use scripts/run-voiceover-mac.py")
            #endif
        case "signal":
            // Hand over to the host-side runner, for what only it can do: a fold, a text size.
            let name = argument.replacingOccurrences(of: " ", with: "_")
            try? Data().write(to: out.appendingPathComponent("signal-\(name)"))
            let acknowledged = out.appendingPathComponent("ack-\(name)").path
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: acknowledged), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            note(command, "\(argument): \(FileManager.default.fileExists(atPath: acknowledged) ? "done" : "NOT ACKNOWLEDGED")")
            settle()
        default:
            note(command, "UNKNOWN STEP")
        }
    }

    // MARK: Elements

    private func predicate(_ label: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR identifier == %@ OR placeholderValue == %@ OR title == %@", label, label, label, label)
    }

    /// `Label`, or `Label@2` for the third element of that name in tree order. Without an index,
    /// the first hittable element of that name.
    private func find(_ specification: String) -> XCUIElement? {
        var label = specification
        var index: Int?
        if let at = specification.lastIndex(of: "@"), let number = Int(specification[specification.index(after: at)...]) {
            label = String(specification[..<at]); index = number
        }
        let query = app.descendants(matching: .any).matching(predicate(label))
        guard query.firstMatch.waitForExistence(timeout: 5) else { return nil }
        let matches = query.allElementsBoundByIndex
        if let index { return index < matches.count ? matches[index] : nil }
        return matches.first { $0.isHittable } ?? matches.first
    }

    /// The host's line of reader state. AppKit gives a text's words as its value.
    private func statusLine() -> String {
        let status = app.descendants(matching: .any)["qualification.status"]
        return status.label.isEmpty ? "\(status.value ?? "")" : status.label
    }

    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "gone" }
        var parts = [Self.name(element.elementType), "\"\(element.label)\""]
        if element.label.isEmpty, !element.title.isEmpty { parts.append("title=\"\(element.title)\"") }
        if let value = element.value, !"\(value)".isEmpty { parts.append("value=\"\(value)\"") }
        if !element.isEnabled { parts.append("DISABLED") }
        if element.isSelected { parts.append("SELECTED") }
        if !element.isHittable { parts.append("unhittable") }
        parts.append(frame(element.frame))
        return parts.joined(separator: " ")
    }

    private func focused() -> String {
        #if os(iOS)
        guard let tree = try? app.snapshot() else { return "SNAPSHOT FAILED" }
        return keyboardAndFocus(tree)
        #else
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? describe(element) : "nothing reports focus"
        #endif
    }

    #if os(iOS)
    private static let orientations: [String: UIDeviceOrientation] = ["portrait": .portrait, "landscape": .landscapeLeft,
                                                                      "landscapeRight": .landscapeRight, "upsideDown": .portraitUpsideDown]

    /// Whether the keyboard is on screen and what has keyboard focus: two readings of one tree,
    /// because the keyboard can be down under a field that still has focus (issue 307). The
    /// keyboard is up when its `inputView` lies inside the first window.
    private func keyboardAndFocus(_ tree: any XCUIElementSnapshot) -> String {
        var window: CGRect?
        var keyboard = "keyboard down", focus = "nothing has keyboard focus"
        func walk(_ element: any XCUIElementSnapshot) {
            if window == nil, element.elementType == .window { window = element.frame.insetBy(dx: -0.5, dy: -0.5) }
            if element.identifier == "inputView", !element.frame.isEmpty, window?.contains(element.frame) == true {
                keyboard = "keyboard up \(frame(element.frame))"
            }
            switch Self.keyboardFocus(element) {
            case true?:
                var parts = ["keyboard focus on", Self.name(element.elementType), "\"\(element.label)\""]
                if let value = element.value, !"\(value)".isEmpty { parts.append("value=\"\(value)\"") }
                focus = (parts + [frame(element.frame)]).joined(separator: " ")
            case nil: focus = "KEYBOARD FOCUS NOT READABLE"
            default: break
            }
            element.children.forEach(walk)
        }
        walk(tree)
        return keyboard + ", " + focus
    }

    /// XCTest's own mark on the element being typed into, the "Keyboard Focused" of its raw tree.
    /// `hasFocus` reports nothing on iOS. Nil when this XCTest's snapshots do not carry the mark.
    private static func keyboardFocus(_ element: any XCUIElementSnapshot) -> Bool? {
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString("hasKeyboardFocus")) else { return nil }
        return object.value(forKey: "hasKeyboardFocus") as? Bool
    }
    #endif

    private func frame(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    // MARK: Records

    private func note(_ command: String, _ text: String) {
        let line = String(format: "%7.2f %02d %@: %@", Date().timeIntervalSince(clock), step, command, text)
        print("QUALIFICATION \(line)")
        let url = out.appendingPathComponent("log.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    /// Lets the interface come to rest, then keeps what is on the glass.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        if autoshot { screenshot("auto") }
    }

    private func screenshot(_ name: String) {
        let file = String(format: "%02d-%@.png", step, name.replacingOccurrences(of: " ", with: "_"))
        let shot = XCUIScreen.main.screenshot()
        guard (try? shot.pngRepresentation.write(to: out.appendingPathComponent(file))) == nil else { return }
        // The Mac's test runner is sandboxed out of the folder: the result bundle keeps the image.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The accessibility tree in its own order: type, label, value, identifier and state of every
    /// element that has any of them, with XCTest's raw description (traits included) beside it.
    private func dump(_ name: String) {
        var lines: [String] = []
        func walk(_ element: any XCUIElementSnapshot, _ depth: Int) {
            var parts = [Self.name(element.elementType)]
            if !element.label.isEmpty { parts.append("label=\"\(element.label)\"") }
            if let value = element.value, !"\(value)".isEmpty { parts.append("value=\"\(value)\"") }
            if let placeholder = element.placeholderValue, !placeholder.isEmpty { parts.append("placeholder=\"\(placeholder)\"") }
            if !element.title.isEmpty { parts.append("title=\"\(element.title)\"") }
            if !element.identifier.isEmpty { parts.append("id=\"\(element.identifier)\"") }
            if !element.isEnabled { parts.append("DISABLED") }
            if element.isSelected { parts.append("SELECTED") }
            #if os(iOS)
            if element.hasFocus || Self.keyboardFocus(element) == true { parts.append("FOCUS") }
            #endif
            parts.append(frame(element.frame))
            let named = parts.count > 2 || ![.other, .group].contains(element.elementType)
            if named { lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " ")) }
            element.children.forEach { walk($0, depth + (named ? 1 : 0)) }
        }
        var readings = ""
        do {
            let tree = try app.snapshot()
            walk(tree, 0)
            #if os(iOS)
            readings = ", " + keyboardAndFocus(tree)
            #endif
        } catch { lines.append("SNAPSHOT FAILED \(error)") }
        let file = String(format: "%02d-%@", step, name.replacingOccurrences(of: " ", with: "_"))
        if (try? Data(lines.joined(separator: "\n").utf8).write(to: out.appendingPathComponent(file + ".tree.txt"))) == nil {
            // Sandboxed out of the folder (the Mac): the runner takes the tree from the test log.
            for line in lines { print("QUALIFICATION-TREE \(file) | \(line)") }
        }
        try? Data(app.debugDescription.utf8).write(to: out.appendingPathComponent(file + ".raw.txt"))
        note("dump", "\(file): \(lines.count) elements\(readings)")
        screenshot(name)
    }

    private static func name(_ type: XCUIElement.ElementType) -> String {
        let names: [XCUIElement.ElementType: String] = [
            .other: "other", .application: "application", .group: "group", .window: "window", .sheet: "sheet", .alert: "alert",
            .dialog: "dialog", .button: "button", .radioButton: "radioButton", .radioGroup: "radioGroup", .checkBox: "checkBox",
            .popUpButton: "popUpButton", .menuButton: "menuButton", .toolbarButton: "toolbarButton", .popover: "popover",
            .keyboard: "keyboard", .key: "key", .navigationBar: "navigationBar", .tabBar: "tabBar", .toolbar: "toolbar",
            .statusBar: "statusBar", .table: "table", .tableRow: "tableRow", .outline: "outline", .outlineRow: "outlineRow",
            .collectionView: "collectionView", .progressIndicator: "progressIndicator", .activityIndicator: "activityIndicator",
            .segmentedControl: "segmentedControl", .picker: "picker", .switch: "switch", .toggle: "toggle", .link: "link",
            .image: "image", .icon: "icon", .searchField: "searchField", .scrollView: "scrollView", .scrollBar: "scrollBar",
            .staticText: "staticText", .textField: "textField", .textView: "textView", .menu: "menu", .menuItem: "menuItem",
            .menuBar: "menuBar", .menuBarItem: "menuBarItem", .cell: "cell", .splitGroup: "splitGroup", .tab: "tab",
        ]
        return names[type] ?? "type\(type.rawValue)"
    }
}
