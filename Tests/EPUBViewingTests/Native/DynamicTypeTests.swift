import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Book text that follows the system text size (`EPUBReaderStyle.followsDynamicType`, #675): the
/// scale each Dynamic Type size gives, an open book rescaled in place, and what the supplied
/// text size controls step through and say.
@MainActor final class DynamicTypeTests: XCTestCase {
    /// The body text style's size at each Dynamic Type size, from Apple's Human Interface
    /// Guidelines ("Typography", "Specifications"): the expectation, not the implementation's table.
    private static let bodySizes: [DynamicTypeSize: Double] = [
        .xSmall: 14, .small: 15, .medium: 16, .large: 17, .xLarge: 19, .xxLarge: 21, .xxxLarge: 23,
        .accessibility1: 28, .accessibility2: 33, .accessibility3: 40, .accessibility4: 47, .accessibility5: 53,
    ]

    func testEachTextSizeScalesAsTheBodyTextStyleDoes() {
        XCTAssertEqual(Set(Self.bodySizes.keys), Set(DynamicTypeSize.allCases))
        for size in DynamicTypeSize.allCases {
            let expected = Self.bodySizes[size]! / 17
            // On iPhone and iPad this is UIKit's preferred body font, measured against the guidelines.
            XCTAssertEqual(Double(NativeTypography.dynamicTypeScale(for: size)), expected, accuracy: 0.5 / 17, "\(size)")
        }
        XCTAssertEqual(Double(NativeTypography.dynamicTypeScale(for: .large)), 1, accuracy: 0.0001)
    }

    // MARK: An open book

    @MainActor @Observable final class TextSize {
        /// The Dynamic Type size the reader's host gives it; nil is the window's own.
        var size: DynamicTypeSize?
    }

    private struct Reader: View {
        let session: any EPUBReaderSession
        let textSize: TextSize
        @Environment(\.dynamicTypeSize) private var inherited
        var body: some View {
            EPUBReaderView(session: session).environment(\.dynamicTypeSize, textSize.size ?? inherited)
        }
    }

    @MainActor private final class Host {
        let textSize = TextSize()
        #if os(macOS)
        let window: NSWindow
        #else
        let window: UIWindow
        let hosting: UIHostingController<Reader>
        #endif
        init(_ session: any EPUBReaderSession) {
            #if os(macOS)
            window = makeMacTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.keepLightAppearance()
            window.contentView = NSHostingView(rootView: Reader(session: session, textSize: textSize))
            window.orderFront(nil)
            #else
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
            } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
            window.keepLightAppearance()
            hosting = UIHostingController(rootView: Reader(session: session, textSize: textSize))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            #endif
        }
        func close() {
            #if os(macOS)
            window.close()
            window.contentView = nil
            #else
            window.isHidden = true
            window.rootViewController = nil
            #endif
        }
    }

    private func wait(_ label: String, timeout: TimeInterval = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open() throws -> (NativeSession, Host) {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        return (session, Host(session))
    }

    /// The book drawn at `points` throughout, with a page or screen of it on display. Sizes from
    /// the guidelines are whole points, which UIKit's metrics give to within half a point.
    private func shows(_ session: NativeSession, at points: CGFloat) -> Bool {
        guard let reported = session.readerState?.status.effectiveFontSize else { return false }
        return session.book.isComplete && abs(session.book.typography.fontSize - points) < 0.5 && session.visibleRange != nil
            && reported == Double(session.book.typography.fontSize)
    }

    /// With the option on, a change of the host's Dynamic Type size while the book is open draws
    /// it at the chosen size times the body style's scale, and keeps the place being read: the
    /// first character shown before the change is shown after it. With the option off, or after
    /// it is turned off, the chosen size is drawn whatever the text size.
    func testFollowingDynamicTypeRescalesAnOpenBookInPlace() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, host) = try open()
            defer { session.close(); host.close() }
            let state = try XCTUnwrap(session.readerState)
            try await wait("the opened reader") { session.isReady && shows(session, at: 17) }
            XCTAssertEqual(state.status.effectiveFontSize, 17)
            XCTAssertEqual(state.status.dynamicTypeScale, 1)
            try await session.send(.style(.init(fontSize: 17, flow: flow)))
            try await session.send(.navigate(href: "OPS/two.xhtml"))
            try await session.send(.nextPage)
            try await session.send(.nextPage)
            try await wait("a place inside the second chapter") { shows(session, at: 17) && session.visibleRange?.start.section == 1 }

            // Off: the host's text size changes nothing drawn.
            host.textSize.size = .accessibility3
            try await wait("the session told of the size") { session.systemTextSize == .accessibility3 }
            XCTAssertTrue(shows(session, at: 17))
            XCTAssertEqual(state.status.dynamicTypeScale, 1)

            // On: the size the host already has applies at once, then each change while open.
            // The place read is the canvas's anchor, which a relayout keeps: the page shown after
            // one starts where the page that holds it does, and the next relayout keeps the anchor,
            // not that page's start.
            let place = try XCTUnwrap(session.canvas?.anchor)
            if flow == .paginated { XCTAssertEqual(session.visibleRange?.start, place, "a page turn puts the anchor at the page's start") }
            var style = state.status.style
            style.followsDynamicType = true
            try await session.send(.style(style))
            for (size, points) in [(DynamicTypeSize.accessibility3, 40.0), (.accessibility5, 53), (.xSmall, 14), (.large, 17), (.xxxLarge, 23)] {
                host.textSize.size = size
                try await wait("\(flow) at \(size)") { shows(session, at: CGFloat(points)) }
                try await Task.sleep(for: .milliseconds(300))
                let after = try XCTUnwrap(session.visibleRange)
                XCTAssertEqual(session.canvas?.anchor, place, "\(flow) at \(size): the place read moved")
                XCTAssertTrue(after.start <= place && place < after.end,
                              "\(flow) at \(size): \(place) was on display and \(after) is shown")
                XCTAssertEqual(state.status.style.fontSize, 17, "the chosen size is kept")
                XCTAssertEqual(state.status.dynamicTypeScale, points / 17, accuracy: 0.5 / 17)
            }

            // A chosen size times the scale, never past what the reader draws.
            style.fontSize = 36
            try await session.send(.style(style))
            host.textSize.size = .accessibility5
            try await wait("\(flow): 36 at the largest size") { shows(session, at: 96) }
            XCTAssertEqual(state.status.style.fontSize, 36)

            // Off again: the chosen size, whatever the host's text size.
            style.followsDynamicType = false
            try await session.send(.style(style))
            try await wait("\(flow): the chosen size alone") { shows(session, at: 36) }
            XCTAssertEqual(state.status.dynamicTypeScale, 1)
        }
    }

    #if os(iOS)
    /// The system text size reaches the reader as it does any SwiftUI view: through its window's
    /// traits, whose content size category UIKit changes when the person changes Larger Text.
    /// Here the category is set on the hosting controller, with no environment value of the
    /// test's own.
    func testTheContentSizeCategoryOfTheReadersWindowRescalesIt() async throws {
        let (session, host) = try open()
        defer { session.close(); host.close() }
        try await wait("the opened reader") { session.isReady && shows(session, at: 17) }
        var style = try XCTUnwrap(session.readerState).status.style
        style.followsDynamicType = true
        style.fontSize = 19
        try await session.send(.style(style))
        try await wait("the opened reader at 19") { shows(session, at: 19) }
        host.hosting.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await wait("the largest category") { session.systemTextSize == .accessibility5 && shows(session, at: 19 * 53 / 17) }
        host.hosting.traitOverrides.preferredContentSizeCategory = .extraSmall
        try await wait("the smallest category") { session.systemTextSize == .xSmall && shows(session, at: 19 * 14 / 17) }
    }
    #endif

    // MARK: The supplied controls

    /// Larger Text from the default size goes all the way to 96 points, and Smaller Text all
    /// the way back to 12. After each step the size drawn is said, as VoiceOver hears it, and
    /// each control is off at its end. With the option on, the steps and what is said follow the
    /// size drawn at the host's text size.
    func testTextSizeStepsReachEitherEndAndSayTheSizeDrawn() async throws {
        let (session, host) = try open()
        defer { session.close(); host.close() }
        try await wait("the opened reader") { session.isReady && shows(session, at: 17) }
        let model = EPUBReaderControls(publication: session.publication, session: session)
        var announced: [String] = []
        model.postAnnouncement = { announced.append($0) }

        XCTAssertEqual(model.drawnTextSize, 17)
        while model.canStepTextSize(larger: true) {
            model.stepTextSize(larger: true)
            await model.waitForCommands()
            XCTAssertLessThan(announced.count, 30, "Larger Text never reached its end")
            if announced.count >= 30 { break }
        }
        XCTAssertEqual(announced, [19, 21, 23, 25, 27, 29, 31, 33, 35, 36, 40, 44, 48, 56, 64, 72, 80, 88, 96].map { "\($0) points" })
        XCTAssertEqual(session.readerState?.status.effectiveFontSize, 96)
        XCTAssertEqual(session.book.typography.fontSize, 96)
        XCTAssertFalse(model.canStepTextSize(larger: true))
        XCTAssertTrue(model.canStepTextSize(larger: false))

        announced = []
        while model.canStepTextSize(larger: false), announced.count < 30 {
            model.stepTextSize(larger: false)
            await model.waitForCommands()
        }
        XCTAssertEqual(announced.first, "88 points")
        XCTAssertEqual(announced.last, "12 points")
        XCTAssertEqual(announced.count, 21)
        XCTAssertFalse(model.canStepTextSize(larger: false))

        // At the largest accessibility size, 17 is drawn at 53 points and each step says its own.
        host.textSize.size = .accessibility5
        model.changeStyle { $0.fontSize = 17; $0.followsDynamicType = true }
        await model.waitForCommands()
        try await wait("the largest text size") { shows(session, at: 17 * 53 / 17) }
        XCTAssertEqual(model.drawnTextSize, 53, accuracy: 0.5)
        announced = []
        model.stepTextSize(larger: true)
        await model.waitForCommands()
        XCTAssertEqual(announced, ["59 points"], "19 points times 53 / 17")
        XCTAssertEqual(session.readerState?.status.style.fontSize, 19)
        while model.canStepTextSize(larger: true), announced.count < 30 {
            model.stepTextSize(larger: true)
            await model.waitForCommands()
        }
        XCTAssertEqual(announced.last, "96 points")
        let chosen = try XCTUnwrap(session.readerState?.status.style.fontSize)
        XCTAssertLessThan(chosen, 36, "a chosen size well under 96 is drawn at 96 there: \(chosen)")
        XCTAssertEqual(session.book.typography.fontSize, 96)
        XCTAssertTrue(model.canStepTextSize(larger: false))
    }
}
