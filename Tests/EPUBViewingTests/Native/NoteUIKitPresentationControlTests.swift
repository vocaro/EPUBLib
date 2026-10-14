#if os(iOS)
import Foundation
import UIKit
import XCTest
@testable import EPUBViewing

/// Independent controls for UIKit presentation in the package XCTest host. Neither routes a
/// link nor depends on a section build, so failure here identifies the presentation lane.
@MainActor final class NoteUIKitPresentationControlTests: XCTestCase {
    func testPlainViewControllerPopoverAttachesAndCompletes() async throws {
        let content = UIViewController()
        content.view = UIView(frame: CGRect(x: 0, y: 0, width: 358, height: 56))
        content.view.backgroundColor = .systemBackground
        content.preferredContentSize = CGSize(width: 358, height: 56)
        let label = UILabel(frame: content.view.bounds.insetBy(dx: 16, dy: 8))
        label.text = "Plain presentation control."
        content.view.addSubview(label)
        try await presentControl(content, style: .popover)
    }

    func testReaderNoteViewControllerFullScreenAttachesAndCompletes() async throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = 64
        let text = NSAttributedString(string: "Full screen note control.", attributes: [
            .font: UIFont.systemFont(ofSize: 16), .paragraphStyle: paragraph,
        ])
        let content = ReaderNoteViewController(text: text, dark: false, width: 358)
        try await presentControl(content, style: .fullScreen)
        XCTAssertEqual(content.textView.contentStorage.textStorage?.string, text.string)
    }

    private func presentControl(_ content: UIViewController, style: UIModalPresentationStyle) async throws {
        let window: UIWindow
        let size = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            window = UIWindow(windowScene: scene)
            window.frame = size
        } else { window = UIWindow(frame: size) }
        let presenter = NoteControlPresenter()
        presenter.view = UIView(frame: size)
        presenter.view.backgroundColor = .systemBackground
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            content.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        let delegate = NoteControlPopoverDelegate()
        content.modalPresentationStyle = style
        if let popover = content.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: 100, y: 100, width: 20, height: 20)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = delegate
        }
        var completed = false
        @MainActor func state() -> String {
            let coordinator = presenter.transitionCoordinator ?? content.transitionCoordinator
            return "kind=\(style.rawValue), presenterClass=\(type(of: presenter)), didAppear=\(presenter.didAppear), "
                + "rootIdentity=\(window.rootViewController === presenter), presenterAttached=\(presenter.viewIfLoaded?.window === window), "
                + "presenterPresenting=\(presenter.isBeingPresented), presenterDismissing=\(presenter.isBeingDismissed), "
                + "contentClass=\(type(of: content)), loaded=\(content.isViewLoaded), frame=\(String(describing: content.viewIfLoaded?.frame)), "
                + "attached=\(content.viewIfLoaded?.window === window), presenting=\(content.isBeingPresented), completed=\(completed), "
                + "coordinator=\(String(describing: coordinator.map { String(describing: type(of: $0)) })), "
                + "animated=\(String(describing: coordinator?.isAnimated)), interactive=\(String(describing: coordinator?.isInteractive)), "
                + "scene=\(String(describing: window.windowScene?.activationState.rawValue)), key=\(window.isKeyWindow)"
        }
        print("NoteUIKit control before presentation: \(state())")
        presenter.present(content, animated: true) {
            completed = true
            print("NoteUIKit control presentation completion: \(state())")
        }
        print("NoteUIKit control after presentation call: \(state())")
        let deadline = Date().addingTimeInterval(5)
        while !(completed && !content.isBeingPresented && content.viewIfLoaded?.window === window) {
            guard Date() < deadline else {
                XCTFail("UIKit control did not complete and attach within five seconds: \(state())")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("NoteUIKit control attached: \(state())")
        XCTAssertTrue(completed)
        XCTAssertFalse(content.isBeingPresented)
        XCTAssertTrue(content.viewIfLoaded?.window === window)
        XCTAssertTrue(window.rootViewController === presenter)
        // UIPopoverPresentationController holds its delegate weakly. Keep the adaptive-none
        // behavior alive through completion and attachment, exactly as the real note does.
        withExtendedLifetime(delegate) {}
        content.dismiss(animated: false)
        let dismissalDeadline = Date().addingTimeInterval(5)
        while content.presentingViewController != nil || content.viewIfLoaded?.window != nil || content.isBeingDismissed {
            guard Date() < dismissalDeadline else {
                XCTFail("UIKit control did not detach within five seconds: \(state())")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("NoteUIKit control detached: \(state())")
    }
}

@MainActor private final class NoteControlPresenter: UIViewController {
    private(set) var didAppear = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        print("NoteUIKit presenter viewWillAppear: animated=\(animated), attached=\(viewIfLoaded?.window != nil)")
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        print("NoteUIKit presenter viewDidAppear: animated=\(animated), attached=\(viewIfLoaded?.window != nil)")
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("NoteUIKit presenter viewWillDisappear: animated=\(animated)")
    }
}

@MainActor private final class NoteControlPopoverDelegate: NSObject, UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}
#endif
