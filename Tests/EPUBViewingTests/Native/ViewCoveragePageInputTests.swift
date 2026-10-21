import CoreGraphics
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
import Carbon
#else
import UIKit
#endif

/// The default page input of doc/native-viewer.md "Input and accessibility" on a mounted canvas:
/// the 56-point tap zones, the six default keys, and what an image or its inspector does to them.
@MainActor final class ViewCoveragePageInputTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(_ sections: [NSAttributedString?], size: CGSize = CGSize(width: 600, height: 700),
                      flow: EPUBReadingFlow = .paginated, rtl: Bool = false) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        configuration.isRightToLeft = rtl
        let host = CanvasHost(FakeCanvasSource(sections), size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    // MARK: Tap zones

    func testDefaultTapZonesAre56PointsAtEitherEdgeOfTheWholeCanvas() {
        let host = host([CanvasText.section(0, paragraphs: 20)])
        let canvas = host.canvas, bounds = canvas.bounds
        XCTAssertEqual(canvas.configuration.pageControls, EPUBPageControls())
        for rtl in [false, true] {
            canvas.configuration.isRightToLeft = rtl
            for y in [bounds.minY + 1, bounds.midY, bounds.maxY - 1] { // The margins above and below the text too.
                for x in [0, 30, 55, 55.9] as [CGFloat] {
                    XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: bounds.minX + x, y: y)), rtl, "\(x) from the left, rtl \(rtl)")
                    XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - x - 0.01, y: y)), !rtl, "\(x) from the right, rtl \(rtl)")
                }
                for x in [56, 57, 100, bounds.width / 2] as [CGFloat] {
                    XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.minX + x, y: y)), "\(x) from the left")
                    XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - x, y: y)), "\(x) from the right")
                }
            }
            XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.minX - 1, y: bounds.midY)), "outside the canvas")
            XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.maxX, y: bounds.midY)))
            XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.minX + 10, y: bounds.minY - 1)))
            XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.minX + 10, y: bounds.maxY)))
        }
    }

    func testATapOnAnImageInAZoneIsTheImages() throws {
        // The column starts 21 points in, so an image opening its first line lies inside the left zone.
        let image = try ViewCoverage.readerImage(width: 120, height: 120, shownWidth: 30, alt: "Ornament")
        let text = ViewCoverage.joined([ViewCoverage.imageText(image), CanvasText.body(" " + CanvasText.sentence(900, seed: 2))])
        let host = host([text])
        let canvas = host.canvas
        let column = try XCTUnwrap(canvas.textViews.first)
        let frame = try XCTUnwrap(column.segmentFrames(for: NSRange(location: 0, length: 1)).first)
        let origin = column.containerOrigin
        let onImage = column.convert(CGPoint(x: frame.midX + origin.x, y: frame.midY + origin.y), to: canvas)
        XCTAssertLessThan(onImage.x, 56)
        XCTAssertTrue(column.image(at: canvas.convert(onImage, to: column)) === image)
        XCTAssertNil(canvas.edgeTurn(at: onImage), "the image keeps its tap")
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: onImage.x, y: onImage.y + 200)), false, "text below it in the zone turns back")
        canvas.configuration.isRightToLeft = true
        XCTAssertNil(canvas.edgeTurn(at: onImage))
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: onImage.x, y: onImage.y + 200)), true)
    }

    // MARK: Keys

    func testDefaultKeyBindingsAreTheSixDocumentedOnes() {
        let controls = EPUBPageControls()
        XCTAssertEqual(controls.effectiveBindings.count, 6)
        let keys: [EPUBPageKey] = [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown, .home, .end, .space,
                                   .character("n"), .character("j"), .character("1")]
        let modifiers: [EPUBPageKeyModifiers] = [[], .shift, .command, .option, .control, [.shift, .command], [.shift, .option],
                                                 [.command, .option], [.shift, .command, .option, .control]]
        for key in keys {
            for modifier in modifiers {
                let expected: Bool?
                switch (key, modifier) {
                case (.rightArrow, []), (.pageDown, []), (.space, []): expected = true
                case (.leftArrow, []), (.pageUp, []), (.space, .shift): expected = false
                default: expected = nil
                }
                XCTAssertEqual(controls.direction(for: key, modifiers: modifier), expected, "\(key) with \(modifier.rawValue)")
            }
        }
    }

    #if os(macOS)
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in host: CanvasHost) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: host.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testDefaultKeysTurnLogicallyInBothFlowsAndReadingDirections() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            for rtl in [false, true] {
                let host = host([CanvasText.section(0, paragraphs: 30)], flow: flow, rtl: rtl)
                let canvas = host.canvas, label = "\(flow) rtl \(rtl)"
                let first = try XCTUnwrap(canvas.visibleRange?.start)
                // Right, Page Down and Space read on; Left, Page Up and Shift-Space go back, also right to left.
                let pairs: [((UInt16, String, NSEvent.ModifierFlags), (UInt16, String, NSEvent.ModifierFlags))] = [
                    ((124, "\u{F703}", [.function, .numericPad]), (123, "\u{F702}", [.function, .numericPad])),
                    ((121, "\u{F72D}", [.function]), (116, "\u{F72C}", [.function])),
                    ((49, " ", []), (49, " ", [.shift])),
                    ((124, "\u{F703}", [.function, .numericPad, .capsLock]), (49, " ", [.shift, .capsLock])),
                ]
                for (next, previous) in pairs {
                    try XCTUnwrap(canvas.textViews.first).keyDown(with: key(next.0, next.1, next.2, in: host))
                    XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), first, "\(label): key \(next.0) reads on")
                    canvas.keyDown(with: key(previous.0, previous.1, previous.2, in: host))
                    XCTAssertEqual(canvas.visibleRange?.start, first, "\(label): key \(previous.0) with \(previous.2.rawValue) goes back")
                }
            }
        }
    }

    func testKeyEventsMapToBindingsIgnoringCapsLockFunctionAndNumericPadFlags() {
        let host = host([CanvasText.body("Keys")])
        func direction(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> Bool? {
            ReaderTextView.pageTurnDirection(for: key(code, characters, flags, in: host))
        }
        XCTAssertEqual(direction(124, "\u{F703}"), true)
        XCTAssertEqual(direction(124, "\u{F703}", [.capsLock, .function, .numericPad]), true)
        XCTAssertEqual(direction(123, "\u{F702}", [.function, .numericPad]), false)
        XCTAssertEqual(direction(116, "\u{F72C}", [.function]), false)
        XCTAssertEqual(direction(121, "\u{F72D}", [.function, .capsLock]), true)
        XCTAssertEqual(direction(49, " "), true)
        XCTAssertEqual(direction(49, " ", [.shift]), false)
        XCTAssertEqual(direction(49, " ", [.capsLock]), true, "Caps Lock is not Shift")
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, [.shift, .command], [.option, .control]] {
            XCTAssertNil(direction(124, "\u{F703}", flags.union([.function, .numericPad])), "Right with \(flags.rawValue)")
            XCTAssertNil(direction(49, " ", flags), "Space with \(flags.rawValue)")
            XCTAssertNil(direction(121, "\u{F72D}", flags.union(.function)), "Page Down with \(flags.rawValue)")
        }
        XCTAssertNil(direction(124, "\u{F703}", [.shift, .function, .numericPad]), "Shift-Right extends a selection")
        XCTAssertNil(direction(125, "\u{F701}", [.function, .numericPad]), "Down is not a default page key")
        XCTAssertNil(direction(126, "\u{F700}", [.function, .numericPad]))
        XCTAssertNil(direction(115, "\u{F729}", [.function]), "Home")
        XCTAssertNil(direction(119, "\u{F72B}", [.function]), "End")
        XCTAssertNil(direction(45, "n"))
        XCTAssertNil(direction(36, "\r"))
        // A custom letter binding follows the character typed, whatever its case or key code.
        let custom = EPUBPageControls(keyboardBindings: [.init(.character("n"), action: .next), .init(.end, action: .next)])
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(45, "N", [.capsLock], in: host), controls: custom), true)
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(38, "n", [], in: host), controls: custom), true)
        XCTAssertNil(ReaderTextView.pageTurnDirection(for: key(45, "N", [.shift], in: host), controls: custom))
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(119, "\u{F72B}", [.function], in: host), controls: custom), true)
        XCTAssertNil(ReaderTextView.pageTurnDirection(for: key(124, "\u{F703}", [.function, .numericPad], in: host), controls: custom))
        // Digits with modifiers that leave the key's character alone.
        let digits = EPUBPageControls(keyboardBindings: [.init(.character("1"), action: .previous), .init(.character("2"), modifiers: .option, action: .next),
                                                        .init(.character("3"), modifiers: .command, action: .next)])
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(18, "1", in: host), controls: digits), false)
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(19, "2", .option, in: host), controls: digits), true)
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(20, "3", .command, in: host), controls: digits), true)
        XCTAssertNil(ReaderTextView.pageTurnDirection(for: key(20, "3", in: host), controls: digits))
    }

    /// doc/integration.md: keys support "ASCII letters/digits" and modifiers "(`shift`, `command`,
    /// `option`, `control`) match exactly". AppKit's `charactersIgnoringModifiers` ignores every
    /// modifier except Shift, so Shift-1 on a US keyboard arrives as "!" (#163). The key's
    /// character without Shift comes from the layout in use, here a Mac's whose 1 is key 18.
    func testADigitBoundWithShiftTurnsThePageWhenItsKeyIsPressedWithShift() {
        let host = host([CanvasText.body("Keys")])
        let controls = EPUBPageControls(keyboardBindings: [.init(.character("1"), modifiers: .shift, action: .next),
                                                          .init(.character("2"), modifiers: [.command, .shift], action: .previous)])
        XCTAssertEqual(controls.effectiveBindings.count, 2, "both bindings are valid")
        XCTAssertEqual(controls.helpHints(for: .next, paginated: false, isRightToLeft: false, platform: .mouse), ["With reader focus: Shift-1"],
                       "and advertised to the reader")
        XCTAssertEqual(controls.direction(for: .character("1"), modifiers: .shift), true)
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(18, "!", .shift, in: host), controls: controls), true, "Shift-1")
        XCTAssertEqual(ReaderTextView.pageTurnDirection(for: key(19, "@", [.command, .shift], in: host), controls: controls), false, "Command-Shift-2")
    }

    /// A digit bound with Shift is the key that carries the digit, pressed with Shift, whatever
    /// the layout: on a US, German or Russian keyboard the key that types the digit, where Shift
    /// types a symbol, and on a French or Czech one the key whose Shift types it (#163). Each
    /// event is the one the layout's own data makes, whichever layout this Mac has in use.
    func testADigitBoundWithShiftIsTheKeyThatCarriesItInEachLayout() throws {
        let host = host([CanvasText.body("Keys")])
        for identifier in ["US", "German", "Russian", "Dvorak", "French", "Czech"] {
            let layout = try XCTUnwrap(MacKeyboardLayout("com.apple.keylayout." + identifier), identifier)
            func direction(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ controls: EPUBPageControls) -> Bool? {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: host.window.windowNumber, context: nil,
                                             characters: layout.characters(code, shift: flags.contains(.shift)),
                                             charactersIgnoringModifiers: layout.characters(code, shift: flags.contains(.shift)),
                                             isARepeat: false, keyCode: code)!
                return ReaderTextView.pageTurnDirection(for: event, controls: controls,
                                                        unshifted: { layout.characters($0.keyCode, shift: false) })
            }
            for digit in "0123456789" {
                let code = try XCTUnwrap(MacKeyboardLayout.digitRow.first { layout.characters($0, shift: false) == String(digit)
                                                                             || layout.characters($0, shift: true) == String(digit) },
                                         "\(identifier) has a key for \(digit)")
                let label = "\(identifier) key \(code) for \(digit)"
                let shifted = EPUBPageControls(keyboardBindings: [.init(.character(digit), modifiers: .shift, action: .next),
                                                                  .init(.character(digit), modifiers: [.command, .shift], action: .previous)])
                XCTAssertEqual(direction(code, .shift, shifted), true, "\(label): Shift")
                XCTAssertEqual(direction(code, [.shift, .capsLock], shifted), true, "\(label): Shift with Caps Lock")
                XCTAssertEqual(direction(code, [.command, .shift], shifted), false, "\(label): Command-Shift")
                XCTAssertNil(direction(code, [.option, .shift], shifted), "\(label): modifiers match exactly")
                XCTAssertNil(direction(code, [], shifted), "\(label): without Shift")
                // Where the key types the digit without Shift, a binding without Shift is that key alone.
                guard layout.characters(code, shift: false) == String(digit) else { continue }
                let plain = EPUBPageControls(keyboardBindings: [.init(.character(digit), action: .next)])
                XCTAssertEqual(direction(code, [], plain), true, "\(label): alone")
                XCTAssertNil(direction(code, .shift, plain), "\(label): Shift is a modifier of its own")
            }
            // Letters stay the layout's: a French keyboard's A is where a US keyboard's Q is.
            guard let a = MacKeyboardLayout.letterKeys.first(where: { layout.characters($0, shift: false) == "a" }) else { continue }
            let letters = EPUBPageControls(keyboardBindings: [.init(.character("a"), modifiers: .shift, action: .next)])
            XCTAssertEqual(direction(a, .shift, letters), true, "\(identifier): Shift-A")
            XCTAssertNil(direction(a, [], letters), "\(identifier): A")
        }
    }

    /// The match above has one answer on every layout that comes with macOS: no key types two
    /// different letters or digits with and without Shift, as Shift-a types "A".
    func testNoKeyOfAMacLayoutTypesTwoLettersOrDigitsWithAndWithoutShift() throws {
        let layouts = MacKeyboardLayout.installed()
        XCTAssertGreaterThan(layouts.count, 100, "the layouts that come with macOS")
        func letterOrDigit(_ characters: String) -> EPUBPageKey? {
            characters.count == 1 ? EPUBPageKey.character(characters.first!).normalized : nil
        }
        var keys = 0
        for layout in layouts {
            for code in UInt16(0)..<128 {
                guard let plain = letterOrDigit(layout.characters(code, shift: false)),
                      let shifted = letterOrDigit(layout.characters(code, shift: true)) else { continue }
                keys += 1
                XCTAssertEqual(plain, shifted, "\(layout.identifier) key \(code)")
            }
        }
        XCTAssertGreaterThan(keys, layouts.count, "keys that type a letter or digit both ways, as A does")
    }

    // MARK: Wheel

    /// A wheel event as a notched mouse sends it: line-based, without phases, its integer delta one
    /// notch and its fixed-point delta `lines`, which is what `deltaY` and `scrollingDeltaY` report.
    private func wheelNotch(lines: Double, horizontal: Bool = false) throws -> NSEvent {
        let notch: Int32 = lines < 0 ? -1 : 1
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: horizontal ? 0 : notch,
                                          wheel2: horizontal ? notch : 0, wheel3: 0))
        event.setDoubleValueField(horizontal ? .scrollWheelEventFixedPtDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis1, value: lines)
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertFalse(wheel.hasPreciseScrollingDeltas)
        XCTAssertTrue(wheel.phase.isEmpty && wheel.momentumPhase.isEmpty)
        XCTAssertEqual(horizontal ? wheel.scrollingDeltaX : wheel.scrollingDeltaY, lines, accuracy: 0.001)
        return wheel
    }

    func testALineBasedWheelEventOfAWholeLineTurnsThePage() throws {
        for rtl in [false, true] {
            let host = host([CanvasText.section(0, paragraphs: 30)], rtl: rtl)
            let canvas = host.canvas
            let first = try XCTUnwrap(canvas.visibleRange?.start)
            canvas.scrollWheel(with: try wheelNotch(lines: -1)) // Scrolling down.
            let second = try XCTUnwrap(canvas.visibleRange?.start)
            XCTAssertGreaterThan(second, first, "rtl \(rtl): down reads on")
            canvas.wheelTurner = ReaderWheelPageTurner()
            canvas.scrollWheel(with: try wheelNotch(lines: 1))
            XCTAssertEqual(canvas.visibleRange?.start, first, "rtl \(rtl): up goes back")
            // Sideways it mirrors: scrolling right reads on, and back in a right-to-left book.
            canvas.wheelTurner = ReaderWheelPageTurner()
            canvas.scrollWheel(with: try wheelNotch(lines: rtl ? 1 : -1, horizontal: true))
            XCTAssertEqual(canvas.visibleRange?.start, second, "rtl \(rtl): sideways")
        }
    }

    /// "On macOS a trackpad gesture or wheel tick turns a page." One slow notch of a notched wheel
    /// is a tenth of a line (Chromium's `web_input_event_builders_mac.mm`, "Of Mice and Men");
    /// WebKit and Chromium make 4 pixels of it (40 a line), the 4 points the reader asks for.
    func testOneSlowNotchOfAMouseWheelTurnsThePage() throws {
        let host = host([CanvasText.section(0, paragraphs: 30)])
        let canvas = host.canvas
        let first = try XCTUnwrap(canvas.visibleRange?.start)
        canvas.scrollWheel(with: try wheelNotch(lines: -0.1))
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), first, "one notch down reads on")
        // Back up, and sideways, one notch at a time (#163).
        canvas.wheelTurner = ReaderWheelPageTurner()
        canvas.scrollWheel(with: try wheelNotch(lines: 0.1))
        XCTAssertEqual(canvas.visibleRange?.start, first, "one notch up goes back")
        canvas.wheelTurner = ReaderWheelPageTurner()
        canvas.scrollWheel(with: try wheelNotch(lines: -0.1, horizontal: true))
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), first, "one notch right reads on")
    }

    func testATrackpadGestureTurnsOnePageAndItsMomentumNone() throws {
        let host = host([CanvasText.section(0, paragraphs: 30)])
        let canvas = host.canvas
        // CGScrollPhase: began 1, changed 2, ended 4, cancelled 8, may begin 128. Momentum: begin 1, continue 2, end 3.
        func scroll(_ points: Int32, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        XCTAssertEqual(try scroll(1, phase: 1).phase, .began, "the fixture's phases reach AppKit")
        XCTAssertEqual(try scroll(1, phase: 2).phase, .changed)
        XCTAssertEqual(try scroll(1, momentum: 2).momentumPhase, .changed)
        let first = try XCTUnwrap(canvas.visibleRange)
        canvas.scrollWheel(with: try scroll(1, phase: 1))
        canvas.scrollWheel(with: try scroll(2, phase: 2))
        XCTAssertEqual(canvas.visibleRange, first, "3 points of travel")
        canvas.scrollWheel(with: try scroll(2, phase: 2))
        let second = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(second.start, first.end, "5 points: one page")
        for _ in 0..<20 { canvas.scrollWheel(with: try scroll(30, phase: 2)) }
        canvas.scrollWheel(with: try scroll(0, phase: 4))
        for phase: Int64 in [1, 2, 2, 2, 3] { canvas.scrollWheel(with: try scroll(40, momentum: phase)) }
        XCTAssertEqual(canvas.visibleRange, second, "the rest of the gesture and its momentum turn nothing")
        // Fingers resting and lifting (may begin, cancelled) are no gesture.
        canvas.scrollWheel(with: try scroll(0, phase: 128))
        canvas.scrollWheel(with: try scroll(0, phase: 8))
        XCTAssertEqual(canvas.visibleRange, second)
        canvas.scrollWheel(with: try scroll(-9, phase: 1))
        XCTAssertEqual(canvas.visibleRange, first, "a new gesture the other way turns back at once")
        // In continuous scroll the wheel is the scroll view's.
        canvas.configuration.flow = .scrolled
        host.layOut()
        let receiver = ViewCoverageWheelReceiver()
        let original = canvas.nextResponder
        canvas.nextResponder = receiver
        defer { canvas.nextResponder = original }
        canvas.scrollWheel(with: try scroll(30))
        XCTAssertEqual(receiver.events, 1, "the canvas passes it on")
    }

    func testChangingPageControlsForgetsAPendingEdgeClick() throws {
        let host = host([CanvasText.section(0, paragraphs: 30)])
        let canvas = host.canvas
        let margin = CGPoint(x: canvas.bounds.maxX - 5, y: canvas.bounds.midY)
        func click(_ type: NSEvent.EventType) -> NSEvent { mouse(type, at: margin, in: canvas, host: host) }
        let receiver = ViewCoverageWheelReceiver()
        let original = canvas.nextResponder
        canvas.nextResponder = receiver // Takes the events the canvas passes on.
        defer { canvas.nextResponder = original }
        let first = try XCTUnwrap(canvas.visibleRange)
        canvas.mouseDown(with: click(.leftMouseDown))
        XCTAssertNotNil(canvas.pointerDown)
        canvas.configuration.pageControls.rightTapWidth = 80
        XCTAssertNil(canvas.pointerDown, "a press made under the old zones is forgotten")
        canvas.mouseUp(with: click(.leftMouseUp))
        XCTAssertEqual(canvas.visibleRange, first)
        // A whole click under the new zones turns.
        canvas.mouseDown(with: click(.leftMouseDown))
        canvas.mouseUp(with: click(.leftMouseUp))
        XCTAssertEqual(canvas.visibleRange?.start, first.end)
        // A press that moves away before it lifts is a drag, not a click.
        canvas.mouseDown(with: click(.leftMouseDown))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: margin.x - 4, y: margin.y), in: canvas, host: host))
        XCTAssertEqual(canvas.visibleRange?.start, first.end)
        XCTAssertNil(canvas.pointerDown)
    }
    #else
    func testKeyInputsMapToBindingsIgnoringCapsLockAndNumericPadFlags() {
        func direction(_ input: String, _ flags: UIKeyModifierFlags = []) -> Bool? { ReaderTextView.pageTurnDirection(input: input, flags: flags) }
        XCTAssertEqual(direction(UIKeyCommand.inputRightArrow), true)
        XCTAssertEqual(direction(UIKeyCommand.inputRightArrow, [.alphaShift, .numericPad]), true)
        XCTAssertEqual(direction(UIKeyCommand.inputLeftArrow, [.numericPad]), false)
        XCTAssertEqual(direction(UIKeyCommand.inputPageUp), false)
        XCTAssertEqual(direction(UIKeyCommand.inputPageDown, [.alphaShift]), true)
        XCTAssertEqual(direction(" "), true)
        XCTAssertEqual(direction(" ", [.shift]), false)
        XCTAssertEqual(direction(" ", [.alphaShift]), true, "Caps Lock is not Shift")
        for flags: UIKeyModifierFlags in [.command, .alternate, .control, [.shift, .command], [.alternate, .control]] {
            XCTAssertNil(direction(UIKeyCommand.inputRightArrow, flags))
            XCTAssertNil(direction(" ", flags))
            XCTAssertNil(direction(UIKeyCommand.inputPageDown, flags))
        }
        XCTAssertNil(direction(UIKeyCommand.inputRightArrow, [.shift]), "Shift-Right extends a selection")
        XCTAssertNil(direction(UIKeyCommand.inputDownArrow))
        XCTAssertNil(direction(UIKeyCommand.inputUpArrow))
        XCTAssertNil(direction(UIKeyCommand.inputHome))
        XCTAssertNil(direction(UIKeyCommand.inputEnd))
        XCTAssertNil(direction("n"))
        XCTAssertNil(direction("\r"))
        XCTAssertNil(ReaderTextView.pageTurnDirection(input: nil, flags: []))
        let custom = EPUBPageControls(keyboardBindings: [.init(.character("n"), action: .next), .init(.end, action: .next)])
        XCTAssertEqual(ReaderTextView.pageTurnDirection(input: "N", flags: [.alphaShift], controls: custom), true)
        XCTAssertNil(ReaderTextView.pageTurnDirection(input: "N", flags: [.shift], controls: custom))
        XCTAssertEqual(ReaderTextView.pageTurnDirection(input: UIKeyCommand.inputEnd, flags: [], controls: custom), true)
        XCTAssertNil(ReaderTextView.pageTurnDirection(input: UIKeyCommand.inputRightArrow, flags: [], controls: custom))
    }

    func testDefaultKeyCommandsTurnLogicallyInBothFlowsAndReadingDirections() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            for rtl in [false, true] {
                let host = host([CanvasText.section(0, paragraphs: 30)], flow: flow, rtl: rtl)
                let canvas = host.canvas, label = "\(flow) rtl \(rtl)"
                let commands = canvas.pageKeyCommands
                XCTAssertEqual(commands.count, 6, label)
                func command(_ input: String, _ flags: UIKeyModifierFlags = []) throws -> UIKeyCommand {
                    try XCTUnwrap(commands.first { $0.input == input && $0.modifierFlags == flags }, "\(label): \(input)")
                }
                let first = try XCTUnwrap(canvas.visibleRange?.start)
                let pairs: [(UIKeyCommand, UIKeyCommand)] = try [
                    (command(UIKeyCommand.inputRightArrow), command(UIKeyCommand.inputLeftArrow)),
                    (command(UIKeyCommand.inputPageDown), command(UIKeyCommand.inputPageUp)),
                    (command(" "), command(" ", .shift)),
                ]
                for (next, previous) in pairs {
                    try XCTUnwrap(canvas.textViews.first).pageTurnKeyCommand(next)
                    XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), first, "\(label): \(next.input ?? "") reads on")
                    canvas.pageTurnKeyCommand(previous)
                    XCTAssertEqual(canvas.visibleRange?.start, first, "\(label): \(previous.input ?? "") goes back")
                }
            }
        }
    }

    func testVoiceOverScrollsMirrorRightToLeftAndStopAtTheBooksEnds() throws {
        for rtl in [false, true] {
            let host = host([CanvasText.section(0, paragraphs: 20)], rtl: rtl)
            let canvas = host.canvas, label = "rtl \(rtl)"
            let first = try XCTUnwrap(canvas.visibleRange)
            let onward: UIAccessibilityScrollDirection = rtl ? .right : .left, back: UIAccessibilityScrollDirection = rtl ? .left : .right
            for direction in [back, .down, .previous] {
                XCTAssertFalse(canvas.accessibilityScroll(direction), "\(label): nothing before the book's first page")
                XCTAssertEqual(canvas.visibleRange, first)
            }
            XCTAssertTrue(canvas.accessibilityScroll(onward), label)
            let second = try XCTUnwrap(canvas.visibleRange)
            XCTAssertEqual(second.start, first.end, label)
            XCTAssertTrue(canvas.accessibilityScroll(back), label)
            XCTAssertEqual(canvas.visibleRange, first, label)
            // Up and down are never mirrored; a column and its line elements pass theirs on.
            XCTAssertTrue(canvas.accessibilityScroll(.up), label)
            XCTAssertEqual(canvas.visibleRange, second, label)
            XCTAssertTrue(canvas.accessibilityScroll(.down), label)
            XCTAssertEqual(canvas.visibleRange, first, label)
            let column = try XCTUnwrap(canvas.textViews.first)
            XCTAssertTrue(column.accessibilityScroll(.next), label)
            XCTAssertEqual(canvas.visibleRange, second, label)
            let element = try XCTUnwrap(try XCTUnwrap(canvas.textViews.first).accessibilityElements?.first as? UIAccessibilityElement)
            XCTAssertTrue(element.accessibilityScroll(.previous), label)
            XCTAssertEqual(canvas.visibleRange, first, label)
            // To the book's last page and no further.
            var turns = 0
            while canvas.accessibilityScroll(.next), turns < 200 { turns += 1 }
            XCTAssertGreaterThan(turns, 3)
            XCTAssertEqual(canvas.visibleRange?.end.offset, host.source.sections[0]?.length, label)
            XCTAssertFalse(canvas.accessibilityScroll(onward), label)
            // Continuous scroll scrolls natively: the canvas declines.
            canvas.configuration.flow = .scrolled
            host.layOut()
            XCTAssertFalse(canvas.accessibilityScroll(.previous), label)
        }
    }
    #endif

    // MARK: Images

    /// A page whose second paragraph is a tall image, and where it is.
    private func imagePage(linked: Bool = false) throws -> (host: CanvasHost, image: ReaderImageAttachment, point: CGPoint) {
        let image = try ViewCoverage.readerImage(width: 1_200, height: 1_600, shownWidth: 150, alt: "Tall diagram")
        let picture = NSMutableAttributedString(attributedString: ViewCoverage.imageText(image))
        if linked {
            picture.addAttribute(.link, value: ReaderLink.internal(href: "OPS/two.xhtml#figure").url, range: NSRange(location: 0, length: 1))
        }
        let before = CanvasText.body("Before the diagram.\n")
        let text = ViewCoverage.joined([before, picture, CanvasText.body("\n" + CanvasText.sentence(400, seed: 4))])
        let host = host([text])
        let column = try XCTUnwrap(host.canvas.textViews.first)
        let frame = try XCTUnwrap(column.segmentFrames(for: NSRange(location: before.length, length: 1)).first)
        let point = CGPoint(x: frame.midX + column.containerOrigin.x, y: frame.midY + column.containerOrigin.y)
        XCTAssertTrue(column.image(at: point) === image)
        return (host, image, point)
    }

    func testPageInputIsSuspendedWhileAnImageIsInspectedAndResumesAfter() throws {
        let (host, image, _) = try imagePage()
        let canvas = host.canvas
        let shown = try XCTUnwrap(canvas.visibleRange), anchor = canvas.anchor
        canvas.inspectImage(image)
        let inspector = try XCTUnwrap(canvas.imageInspector)
        XCTAssertTrue(inspector.superview === canvas)
        XCTAssertEqual(inspector.frame, canvas.bounds)
        canvas.turnPageFromInput(forward: true)
        XCTAssertEqual(canvas.visibleRange, shown, "keys, swipes, wheel and taps do nothing under the inspector")
        XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: canvas.bounds.maxX - 5, y: canvas.bounds.midY)))
        #if os(macOS)
        XCTAssertFalse(canvas.handlePageKeyEquivalent(key(124, "\u{F703}", [.function, .numericPad], in: host)))
        canvas.keyDown(with: key(49, " ", in: host))
        XCTAssertEqual(canvas.visibleRange, shown)
        #else
        XCTAssertTrue(canvas.pageKeyCommands.isEmpty)
        XCTAssertFalse(canvas.accessibilityScroll(.next))
        XCTAssertEqual(canvas.visibleRange, shown)
        #endif
        // The reader resizes under the inspector, which follows it.
        host.resize(to: CGSize(width: 640, height: 720))
        XCTAssertEqual(inspector.frame, canvas.bounds)
        XCTAssertTrue(canvas.subviews.last === inspector, "still on top after the relayout")
        host.resize(to: CGSize(width: 600, height: 700))
        inspector.close()
        XCTAssertNil(canvas.imageInspector)
        XCTAssertNil(inspector.superview)
        XCTAssertEqual(canvas.visibleRange, shown)
        XCTAssertEqual(canvas.anchor, anchor)
        canvas.turnPageFromInput(forward: true)
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), shown.start, "input turns pages again")
    }

    #if os(macOS)
    func testInspectorKeysZoomPanFitAndClose() throws {
        let (host, image, _) = try imagePage()
        let canvas = host.canvas
        canvas.inspectImage(image)
        host.layOut()
        let inspector = try XCTUnwrap(canvas.imageInspector)
        let scrollView = inspector.scrollView
        // The fit follows the viewport, which a legacy scroller narrows while the image is magnified.
        func fit() -> CGFloat { host.layOut(); return scrollView.minMagnification }
        func magnification() -> CGFloat { scrollView.magnification }
        XCTAssertEqual(magnification(), fit(), accuracy: 0.0001, "opens fitted")
        XCTAssertLessThan(fit(), 1, "the fixture is larger than the reader")
        // Command-plus, Command-minus and Command-zero.
        var before = magnification()
        XCTAssertTrue(inspector.performKeyEquivalent(with: key(24, "=", .command, in: host)))
        XCTAssertEqual(magnification(), before * 2, accuracy: 0.0001)
        XCTAssertTrue(inspector.performKeyEquivalent(with: key(24, "+", [.command, .shift], in: host)))
        XCTAssertEqual(magnification(), before * 4, accuracy: 0.0001)
        XCTAssertTrue(inspector.performKeyEquivalent(with: key(27, "-", .command, in: host)))
        XCTAssertEqual(magnification(), before * 2, accuracy: 0.0001)
        _ = fit()
        XCTAssertTrue(inspector.performKeyEquivalent(with: key(29, "0", .command, in: host)))
        XCTAssertEqual(magnification(), fit(), accuracy: 0.0001)
        XCTAssertTrue(inspector.performKeyEquivalent(with: key(27, "-", .command, in: host)))
        XCTAssertEqual(magnification(), fit(), accuracy: 0.0001, "never smaller than the fit")
        before = magnification()
        XCTAssertFalse(inspector.performKeyEquivalent(with: key(24, "=", in: host)), "not an equivalent without Command")
        XCTAssertEqual(magnification(), before, accuracy: 0.0001)
        // The same keys unmodified, with the inspector focused.
        XCTAssertTrue(inspector.acceptsFirstResponder)
        inspector.keyDown(with: key(24, "+", .shift, in: host))
        inspector.keyDown(with: key(24, "=", in: host))
        XCTAssertEqual(magnification(), before * 4, accuracy: 0.0001)
        inspector.keyDown(with: key(27, "-", in: host))
        XCTAssertEqual(magnification(), before * 2, accuracy: 0.0001)
        host.layOut()
        // Arrows pan the magnified image 40 points of screen at a time.
        let clip = scrollView.contentView
        let origin = clip.bounds.origin, step = 40 / scrollView.magnification
        inspector.keyDown(with: key(124, "\u{F703}", [.function, .numericPad], in: host))
        XCTAssertEqual(clip.bounds.minX, origin.x + step, accuracy: 0.5, "Right")
        inspector.keyDown(with: key(123, "\u{F702}", [.function, .numericPad], in: host))
        XCTAssertEqual(clip.bounds.minX, origin.x, accuracy: 0.5, "Left")
        inspector.keyDown(with: key(125, "\u{F701}", [.function, .numericPad], in: host))
        XCTAssertEqual(abs(clip.bounds.minY - origin.y), step, accuracy: 0.5, "Down")
        inspector.keyDown(with: key(126, "\u{F700}", [.function, .numericPad], in: host))
        XCTAssertEqual(clip.bounds.minY, origin.y, accuracy: 0.5, "Up")
        inspector.keyDown(with: key(121, "\u{F72D}", [.function], in: host))
        let paged = clip.bounds.minY
        XCTAssertGreaterThan(abs(paged - origin.y), step, "Page Down moves most of a screen")
        inspector.keyDown(with: key(116, "\u{F72C}", [.function], in: host))
        XCTAssertGreaterThan(abs(clip.bounds.minY - paged), step, "Page Up moves back")
        XCTAssertEqual(clip.bounds.minY > paged, origin.y > paged, "the other way")
        _ = fit()
        inspector.keyDown(with: key(29, "0", in: host))
        XCTAssertEqual(magnification(), fit(), accuracy: 0.0001)
        // Escape closes; so does Command-W.
        inspector.keyDown(with: key(53, "\u{1B}", in: host))
        XCTAssertNil(canvas.imageInspector)
        canvas.inspectImage(image)
        let again = try XCTUnwrap(canvas.imageInspector)
        XCTAssertFalse(again === inspector)
        XCTAssertTrue(again.performKeyEquivalent(with: key(13, "w", .command, in: host)))
        XCTAssertNil(canvas.imageInspector)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1, host: CanvasHost) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testADoubleClickOrTheContextMenuInspectsAnImage() throws {
        let (host, image, point) = try imagePage()
        let canvas = host.canvas
        let column = try XCTUnwrap(canvas.textViews.first)
        column.mouseDown(with: mouse(.leftMouseDown, at: point, in: column, clicks: 2, host: host))
        let inspector = try XCTUnwrap(canvas.imageInspector, "a double-click on an unlinked image inspects it")
        XCTAssertEqual(inspector.imageView.accessibilityLabel(), "Tall diagram")
        inspector.close()
        // The context menu on the image leads with Inspect Image; elsewhere it has none.
        let menu = try XCTUnwrap(column.menu(for: mouse(.rightMouseDown, at: point, in: column, host: host)))
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(item.title, "Inspect Image")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(canvas.imageInspector)
        canvas.imageInspector?.close()
        let text = CGPoint(x: point.x, y: point.y + 400)
        XCTAssertNil(column.image(at: text))
        let plain = column.menu(for: mouse(.rightMouseDown, at: text, in: column, host: host))
        XCTAssertFalse(plain?.items.contains { $0.title == "Inspect Image" } ?? false)
        // Quick Look on the image inspects it rather than looking a word up.
        column.quickLook(with: mouse(.leftMouseDown, at: point, in: column, host: host))
        XCTAssertEqual(canvas.imageInspector?.imageView.accessibilityLabel(), image.alt)
    }

    func testALinkedImageOffersInspectionThroughItsMenuOnly() throws {
        let (host, _, point) = try imagePage(linked: true)
        let canvas = host.canvas
        let column = try XCTUnwrap(canvas.textViews.first)
        XCTAssertNotNil(column.link(at: point))
        let menu = try XCTUnwrap(column.menu(for: mouse(.rightMouseDown, at: point, in: column, host: host)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Inspect Image" }, "the menu offers inspection")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(canvas.imageInspector)
        XCTAssertTrue(host.recorder.links.isEmpty, "inspecting follows no link")
    }
    #endif
}

#if os(macOS)
/// Stands after the canvas in the responder chain and takes what it passes on.
@MainActor final class ViewCoverageWheelReceiver: NSResponder {
    var events = 0
    override func scrollWheel(with event: NSEvent) { events += 1 }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// A keyboard layout that comes with macOS, read from its own data: what its keys type does not
/// depend on the layout this Mac has in use, and nothing here changes that.
struct MacKeyboardLayout {
    /// The keys of 1 to 9 and 0 on a US keyboard, by key code.
    static let digitRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    /// The keys of A to Z on a US keyboard, by key code.
    static let letterKeys: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]

    let identifier: String
    private let data: Data

    private init?(_ source: TISInputSource) {
        guard let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.identifier = Unmanaged<CFString>.fromOpaque(identifier).takeUnretainedValue() as String
        self.data = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
    }

    /// The installed layout with this identifier, such as `com.apple.keylayout.French`.
    init?(_ identifier: String) {
        guard let layout = Self.installed(matching: [kTISPropertyInputSourceID as String: identifier]).first else { return nil }
        self = layout
    }

    /// Every keyboard layout that comes with macOS.
    static func installed() -> [Self] {
        installed(matching: [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String])
            .filter { $0.identifier.hasPrefix("com.apple.keylayout.") }
    }

    private static func installed(matching properties: [String: String]) -> [Self] {
        guard let list = TISCreateInputSourceList(properties as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap(Self.init)
    }

    /// What the key types with no modifier or with Shift alone, as a key event's
    /// `charactersIgnoringModifiers` gives it; empty for a key the layout does not type with.
    func characters(_ keyCode: UInt16, shift: Bool) -> String {
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var deadKeys: UInt32 = 0, length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) : 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                        characters.count, &length, &characters)
            return status == noErr ? String(utf16CodeUnits: characters, count: length) : ""
        }
    }
}
#endif
