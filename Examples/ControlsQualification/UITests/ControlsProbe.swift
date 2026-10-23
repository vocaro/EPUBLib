import XCTest
import XCUIAutomation

/// Operates the qualification host one step at a time and records what the accessibility tree
/// and the screen show after each step. It asserts nothing: a run that completes is not a
/// result. Read its log and screenshots; see "Reader controls probe" in doc/testing.md.
///
/// `TEST_RUNNER_QUALIFICATION_OUT` names a directory holding `args.txt` (launch arguments, one
/// per line) and `steps.txt` (one step per line); the log, tree dumps and screenshots go there.
@MainActor final class ControlsProbe: XCTestCase {
    private var app: XCUIApplication!
    /// The host's bundle identifier and launch arguments, which `target=host` operates again and
    /// `target=relaunch` launches again.
    private var host = ""
    private var hostArguments: [String] = []
    private var out: URL!
    private var step = 0
    private var autoshot = true
    private let clock = Date()

    func testOperate() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["QUALIFICATION_OUT"] else {
            throw XCTSkip("Set TEST_RUNNER_QUALIFICATION_OUT; see \"Reader controls probe\" in doc/testing.md")
        }
        out = URL(fileURLWithPath: path)
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        }
        #if os(macOS)
        host = "org.epubreaderlib.controlsqualification.mac"
        #else
        host = "org.epubreaderlib.controlsqualification"
        #endif
        app = XCUIApplication(bundleIdentifier: host)
        app.launchArguments = lines("args.txt")
        hostArguments = app.launchArguments
        app.launch()
        note("launch", app.launchArguments.joined(separator: " "))
        #if os(iOS)
        // A simulator keeps the way up the last scenario left it, and the host has launched that
        // way: turn it upright before the first step, and say what was found.
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
        if ["tap", "forcetap", "tapbegins", "tapcontains", "keyboard", "tapxy", "type", "key", "swipe", "scrolllist", "resize"].contains(command),
           app.state != .runningForeground {
            return note(command, "SKIPPED \(argument): the host is not the frontmost application")
        }
        #endif
        switch command {
        case "tap", "forcetap", "tapbegins", "tapcontains", "keyboard":
            // `tap=WORD` touches the one element WORD names (see `find`); `forcetap` touches its
            // centre even when XCTest calls it unhittable. `tapbegins` names by a label that begins
            // with TEXT, such as a result named "Match 6 of 14, …"; `tapcontains` by a label,
            // identifier or title that contains it, for a system control of unknown name.
            // `keyboard=search` touches the on-screen keyboard's own key, here the Return of a field
            // whose submit label is Search; no other step touches the keyboard (issue 366).
            let element = switch command {
            case "tapbegins": find(command, argument, by: ["label"], "%K BEGINSWITH %@")
            case "tapcontains": find(command, argument, by: ["label", "identifier", "title"], "%K CONTAINS[c] %@")
            default: find(command, argument, onKeyboard: command == "keyboard")
            }
            guard let element else { return }
            let before = describe(element)
            guard element.isHittable || command == "forcetap" else { return note(command, "NOT HITTABLE \(before)") }
            #if os(macOS)
            element.click()
            #else
            if element.isHittable { element.tap() } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
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
            // The touch rests a tenth of a second before it moves. Two more numbers set the rest
            // in seconds and the speed in points a second: `0.5,0.36,0.5,0.28,0,1500` is a flick.
            // How long a touch rests decides whether a scroll view or the control under it has it.
            // A seventh is the seconds it stays down at the end, which leaves a scroll view where
            // the touch took it and not where a fling would.
            #if os(iOS)
            let points = argument.split(separator: ",").compactMap { Double($0) }
            guard [4, 6, 7].contains(points.count) else { return note(command, "BAD POINTS") }
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: points[0], dy: points[1]))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: points[2], dy: points[3]))
            if points.count > 4 {
                start.press(forDuration: points[4], thenDragTo: end, withVelocity: XCUIGestureVelocity(points[5]),
                            thenHoldForDuration: points.count == 7 ? points[6] : 0)
            } else {
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            note(command, argument)
            settle()
            #else
            note(command, "iOS only")
            #endif
        case "type":
            // `\n` is Return as a hardware keyboard sends it, which can put the keyboard away under
            // a field that keeps focus (issue 307). `keyboard=search` touches the keyboard's own key.
            app.typeText(argument.replacingOccurrences(of: "\\n", with: "\n"))
            note(command, argument)
            settle()
        case "key":
            // A hardware key, with modifiers as in `shift+tab` or `command+f`. On an iOS 27 iPad
            // simulator `home`, `end`, `pageup` and `pagedown` reached the host as no press at all,
            // with `function+` or without, where `right` and `space` did (issue 681).
            var flags: XCUIElement.KeyModifierFlags = []
            var key = argument
            for (name, flag) in [("shift+", XCUIElement.KeyModifierFlags.shift), ("command+", .command), ("option+", .option), ("control+", .control),
                                 ("function+", .function)]
            where key.hasPrefix(name) {
                flags.insert(flag); key.removeFirst(name.count)
            }
            let keys: [String: XCUIKeyboardKey] = ["return": .return, "tab": .tab, "escape": .escape, "space": .space, "delete": .delete,
                                                   "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
                                                   "pageup": .pageUp, "pagedown": .pageDown, "home": .home, "end": .end]
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
        case "target":
            // `target=com.apple.Preferences` operates another application of the simulator, such
            // as Settings for a setting no simctl command makes; the steps after it touch, read
            // and dump that application. `target=host` comes back to the host, which kept running,
            // and `target=relaunch` launches the host again with its arguments, as a setting a
            // running application does not follow needs.
            #if os(iOS)
            app = XCUIApplication(bundleIdentifier: ["host", "relaunch"].contains(argument) ? host : argument)
            if argument == "relaunch" {
                app.launchArguments = hostArguments
                app.launch()
            } else {
                app.activate()
            }
            note(command, "\(argument): \(app.state == .runningForeground ? "in front" : "NOT IN FRONT")")
            settle()
            #else
            note(command, "iOS only")
            #endif
        case "slider":
            // `slider=0.25` moves the first slider on screen to that fraction of its track, and
            // `slider=Name@0.25` the slider WORD names (see `find`); the line gives its value
            // before and after.
            #if os(iOS)
            let parts = argument.split(separator: "@").map(String.init)
            guard let position = Double(parts.last ?? "") else { return note(command, "BAD POSITION") }
            let slider = parts.count == 2 ? app.sliders[parts[0]].firstMatch : app.sliders.firstMatch
            guard slider.exists else { return note(command, "NO SLIDER") }
            let before = slider.value as? String ?? "?"
            slider.adjust(toNormalizedSliderPosition: position)
            note(command, "\(describe(slider)): \(before) -> \(slider.value as? String ?? "?")")
            settle()
            #else
            note(command, "iOS only")
            #endif
        case "wait":
            RunLoop.current.run(until: Date().addingTimeInterval(Double(argument) ?? 1))
        case "waitfor", "waitgone":
            // Until WORD names an element, or names none, as `find` reads it.
            let deadline = Date().addingTimeInterval(30)
            var shown = !naming(argument).elements.isEmpty
            while shown != (command == "waitfor"), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                shown = !naming(argument).elements.isEmpty
            }
            note(command, "\(argument): \(shown == (command == "waitfor") ? "yes" : "TIMED OUT")")
        case "watch":
            // When WORD names an element during the next SECONDS, for states too brief to tap after.
            let parts = argument.split(separator: ",", maxSplits: 1).map(String.init)
            let deadline = Date().addingTimeInterval(Double(parts.last ?? "") ?? 5)
            var shown: Bool?
            while Date() < deadline {
                let element = naming(parts[0]).elements.first
                if (element != nil) != shown {
                    shown = element != nil
                    note(command, "\(parts[0]) \(element.map { "ON SCREEN \(describe($0))" } ?? "not on screen")")
                    if element != nil { screenshot("watch") }
                }
            }
        case "find":
            // Every element WORD names, numbered as `tap=WORD@N` takes them, then what else carries
            // the word and is passed over: the keyboard's keys, and other attributes' matches.
            let named = naming(argument)
            note(command, "\(argument): \(named.elements.count) match(es)" + (named.elements.isEmpty ? "" : " by \(named.attribute)"))
            for (index, element) in named.elements.enumerated() { note(command, "  @\(index) \(describe(element))") }
            for other in named.passedOver {
                note(command, "  passed over, by \(other.attribute)\(other.onKeyboard ? " on the keyboard" : ""): \(describe(other.element))")
            }
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
            // On iOS, whether the keyboard is on screen and what has keyboard focus.
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
            guard let element = find(command, argument) else { return }
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

    /// What a step's word is compared with, in this order. The first attribute that carries the
    /// word decides, and the later ones are passed over: `Search` names a button labelled Search
    /// before anything whose identifier is Search.
    private static let attributes = ["label", "identifier", "placeholderValue", "title"]

    /// What WORD names: the elements that carry it in the earliest attribute any of them carries it
    /// in, numbered as XCTest's query numbers them, and what else carries the word.
    /// Only the application's own elements are named, or with `onKeyboard` only the keyboard's:
    /// everything in the window that holds it, its predictions, Emoji and Dictate as well as its
    /// keys. With the keyboard up, `Search` was the search field's button and, by its identifier,
    /// the keyboard's Search key (issue 366). `format` compares an attribute (`%K`) with the word.
    private func naming(_ word: String, onKeyboard: Bool = false, by attributes: [String] = ControlsProbe.attributes,
                        _ format: String = "%K == %@") -> Naming {
        guard let tree = try? app.snapshot() else { return Naming(failed: true) }
        let predicates = attributes.map { NSPredicate(format: format, $0, word) }
        func holdsKeyboard(_ element: any XCUIElementSnapshot) -> Bool {
            element.elementType == .keyboard || element.children.contains(where: holdsKeyboard)
        }
        // XCTest's query takes descendants breadth first: the keyboard's Search key, eight levels
        // down, came before the field's button, thirteen down. Each element that carries the word
        // keeps its place among each attribute's matches, its frame, and whether it is the keyboard's.
        var carriers: [(onKeyboard: Bool, places: [Int?], frame: CGRect)] = []
        var counts = attributes.map { _ in 0 }
        var queue = tree.children.map { ($0, holdsKeyboard($0)) }
        var next = 0
        while next < queue.count {
            let (element, keyboard) = queue[next]
            next += 1
            let values = ["label": element.label, "identifier": element.identifier,
                          "placeholderValue": element.placeholderValue ?? "", "title": element.title]
            var places: [Int?] = []
            for (n, predicate) in predicates.enumerated() {
                if predicate.evaluate(with: values) { places.append(counts[n]); counts[n] += 1 } else { places.append(nil) }
            }
            if places.contains(where: { $0 != nil }) { carriers.append((keyboard, places, element.frame)) }
            queue += element.children.map { ($0, keyboard) }
        }
        var named = Naming()
        let query = { (n: Int) in self.app.descendants(matching: .any).matching(predicates[n]) }
        let chosen = predicates.indices.first { n in carriers.contains { $0.onKeyboard == onKeyboard && $0.places[n] != nil } }
        if let chosen { named.attribute = attributes[chosen] }
        for carrier in carriers {
            if let chosen, carrier.onKeyboard == onKeyboard, let place = carrier.places[chosen] {
                named.elements.append(query(chosen).element(boundBy: place))
                named.frames.append(carrier.frame)
            } else if let n = carrier.places.firstIndex(where: { $0 != nil }), let place = carrier.places[n] {
                named.passedOver.append((attributes[n], carrier.onKeyboard, query(n).element(boundBy: place)))
            }
        }
        return named
    }

    private struct Naming {
        var failed = false
        var attribute = ""
        var elements: [XCUIElement] = []
        var frames: [CGRect] = []
        var passedOver: [(attribute: String, onKeyboard: Bool, element: XCUIElement)] = []
    }

    /// The one element SPECIFICATION names, after noting why there is none if there is not.
    /// `Word@2` takes the third that `find=Word` lists. Without an index, Word must name one
    /// element or one hittable element: a step never takes the first of several it could touch.
    private func find(_ command: String, _ specification: String, onKeyboard: Bool = false,
                      by attributes: [String] = ControlsProbe.attributes, _ format: String = "%K == %@") -> XCUIElement? {
        var word = specification
        var index: Int?
        if let at = specification.lastIndex(of: "@"), let number = Int(specification[specification.index(after: at)...]) {
            word = String(specification[..<at]); index = number
        }
        let deadline = Date().addingTimeInterval(5)
        var named = naming(word, onKeyboard: onKeyboard, by: attributes, format)
        while named.elements.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            named = naming(word, onKeyboard: onKeyboard, by: attributes, format)
        }
        if named.failed { note(command, "\(specification): SNAPSHOT FAILED"); return nil }
        guard !named.elements.isEmpty else {
            // What the word names elsewhere, such as the keyboard's key `tap` passes over.
            let other = named.passedOver.first.map { other in
                "; " + (other.onKeyboard ? "on the keyboard, for keyboard=\(word): " : "not on the keyboard, for tap=\(word): ")
                    + describe(other.element)
            }
            note(command, "\(specification): MISSING" + (other ?? ""))
            return nil
        }
        let hittable = index == nil && named.elements.count > 1 ? named.elements.indices.filter { named.elements[$0].isHittable } : []
        let chosen = index ?? (named.elements.count == 1 ? 0 : hittable.count == 1 ? hittable[0] : nil)
        guard let chosen, chosen < named.elements.count else {
            note(command, index == nil
                 ? "\(word): AMBIGUOUS, \(named.elements.count) by \(named.attribute), \(hittable.count) hittable; take one as \(word)@N"
                 : "\(specification): MISSING, \(named.elements.count) by \(named.attribute)")
            for (n, element) in named.elements.enumerated() { note(command, "  @\(n) \(describe(element))") }
            return nil
        }
        // The query is read again when the element is used: refuse if the tree has moved since. A
        // field that had not moved was 34.0 high in the tree and 34.000000000000014 as an element.
        let element = named.elements[chosen], was = named.frames[chosen], now = element.frame
        guard element.exists, [now.minX - was.minX, now.minY - was.minY, now.width - was.width, now.height - was.height].allSatisfy({ abs($0) < 0.5 }) else {
            note(command, "\(specification): MOVED, \(was) is now \(now): \(describe(element))")
            return nil
        }
        return element
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
        var tree: (any XCUIElementSnapshot)?
        do { tree = try app.snapshot() } catch { lines.append("SNAPSHOT FAILED \(error)") }
        if let tree { walk(tree, 0) }
        let file = String(format: "%02d-%@", step, name.replacingOccurrences(of: " ", with: "_"))
        if (try? Data(lines.joined(separator: "\n").utf8).write(to: out.appendingPathComponent(file + ".tree.txt"))) == nil {
            // Sandboxed out of the folder (the Mac): the runner takes the tree from the test log.
            for line in lines { print("QUALIFICATION-TREE \(file) | \(line)") }
        }
        try? Data(app.debugDescription.utf8).write(to: out.appendingPathComponent(file + ".raw.txt"))
        #if os(iOS)
        note("dump", "\(file): \(lines.count) elements, " + (tree.map(keyboardAndFocus) ?? "no tree"))
        #else
        note("dump", "\(file): \(lines.count) elements")
        #endif
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
