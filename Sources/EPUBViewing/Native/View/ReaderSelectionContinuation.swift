import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A located passage remains selected on every page it crosses. These explicit controls
/// let readers follow its continuation while ordinary selection gestures cannot turn pages.
@MainActor final class ReaderSelectionContinuation: PlatformView {
    private weak var canvas: ReaderCanvasView?
    #if os(macOS)
    private let label = NSTextField(labelWithString: "Selected passage continues")
    private let previousButton = NSButton(title: "←", target: nil, action: nil)
    private let nextButton = NSButton(title: "→", target: nil, action: nil)
    #else
    private let label = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    #endif

    init(canvas: ReaderCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        #if os(macOS)
        label.font = .systemFont(ofSize: 11)
        previousButton.target = self
        previousButton.action = #selector(previousPage)
        nextButton.target = self
        nextButton.action = #selector(nextPage)
        previousButton.bezelStyle = .inline
        nextButton.bezelStyle = .inline
        previousButton.setAccessibilityLabel("Previous page of selected passage")
        nextButton.setAccessibilityLabel("Next page of selected passage")
        #else
        label.text = "Selected passage continues"
        label.font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: 11), maximumPointSize: 14)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        previousButton.setTitle("←", for: .normal)
        nextButton.setTitle("→", for: .normal)
        previousButton.titleLabel?.font = .systemFont(ofSize: 12)
        nextButton.titleLabel?.font = .systemFont(ofSize: 12)
        previousButton.addTarget(self, action: #selector(previousPage), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextPage), for: .touchUpInside)
        previousButton.accessibilityLabel = "Previous page of selected passage"
        nextButton.accessibilityLabel = "Next page of selected passage"
        #endif
        addSubview(label)
        addSubview(previousButton)
        addSubview(nextButton)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(previous: Bool, next: Bool, theme: ReaderTheme) {
        let color = theme.text
        #if os(macOS)
        label.textColor = color
        self.previousButton.contentTintColor = color
        self.nextButton.contentTintColor = color
        #else
        label.textColor = color
        self.previousButton.setTitleColor(color, for: .normal)
        self.nextButton.setTitleColor(color, for: .normal)
        #endif
        self.previousButton.isHidden = !previous
        self.nextButton.isHidden = !next
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); arrange() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); arrange() }
    #endif

    private func arrange() {
        let buttonWidth: CGFloat = 44
        nextButton.frame = CGRect(x: bounds.maxX - buttonWidth, y: 0, width: buttonWidth, height: bounds.height)
        previousButton.frame = CGRect(x: bounds.maxX - 2 * buttonWidth - 4, y: 0, width: buttonWidth, height: bounds.height)
        label.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - 2 * buttonWidth - 8), height: bounds.height)
    }

    @objc private func previousPage() { _ = canvas?.turnPage(forward: false) }
    @objc private func nextPage() { _ = canvas?.turnPage(forward: true) }
}
