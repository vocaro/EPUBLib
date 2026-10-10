#if os(iOS)
import UIKit

/// Native pinch, pan and explicit zoom controls, equally usable on a phone and tablet.
@MainActor final class ReaderImageInspector: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let imageView = UIImageView()
    private let toolbar = UIStackView()
    private let status = UILabel()
    private var needsFit = true
    private var lastViewport = CGSize.zero
    var onClose: (() -> Void)?

    init(bitmap: CGImage, label: String, dark: Bool) {
        super.init(frame: .zero)
        backgroundColor = ReaderPalette.background(dark: dark)
        accessibilityViewIsModal = true
        scrollView.delegate = self
        scrollView.backgroundColor = backgroundColor
        scrollView.contentInsetAdjustmentBehavior = .never
        imageView.image = UIImage(cgImage: bitmap)
        imageView.frame = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = label.isEmpty ? "Book image" : label
        imageView.accessibilityHint = "Use Zoom In and Zoom Out to enlarge the image, then scroll to inspect it."
        scrollView.addSubview(imageView)
        scrollView.contentSize = imageView.bounds.size
        addSubview(scrollView)
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fillEqually
        for (title, action) in [("−", #selector(zoomOut)), ("+", #selector(zoomIn)),
                                 ("Fit", #selector(fit)), ("Close", #selector(close))] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityLabel = title == "+" ? "Zoom In" : title == "−" ? "Zoom Out" : title
            button.addTarget(self, action: action, for: .touchUpInside)
            toolbar.addArrangedSubview(button)
        }
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontForContentSizeCategory = true
        status.accessibilityLabel = "Magnification"
        toolbar.addArrangedSubview(status)
        addSubview(toolbar)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var canBecomeFirstResponder: Bool { true }
    func open() {
        setNeedsLayout()
        layoutIfNeeded()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: toolbar.arrangedSubviews.first)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = safeAreaInsets.top
        toolbar.frame = CGRect(x: max(8, safeAreaInsets.left), y: top + 4,
            width: max(1, bounds.width - max(8, safeAreaInsets.left) - max(8, safeAreaInsets.right)), height: 44)
        scrollView.frame = CGRect(x: 0, y: top + 52, width: bounds.width,
                                 height: max(1, bounds.height - top - 52 - safeAreaInsets.bottom))
        if lastViewport != scrollView.bounds.size {
            let oldFit = ReaderImageInspection.fitScale(image: imageView.bounds.size, viewport: lastViewport)
            needsFit = needsFit || abs(scrollView.zoomScale - oldFit) < 0.001
            lastViewport = scrollView.bounds.size
        }
        let minimum = ReaderImageInspection.fitScale(image: imageView.bounds.size, viewport: scrollView.bounds.size)
        scrollView.minimumZoomScale = minimum
        scrollView.maximumZoomScale = ReaderImageInspection.maximumScale(fit: minimum)
        if needsFit { needsFit = false; fit() }
        centerImage()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        status.text = "\(Int((scrollView.zoomScale * 100).rounded()))%"
    }
    private func centerImage() {
        scrollView.contentInset = UIEdgeInsets(top: max(0, (scrollView.bounds.height - imageView.frame.height) / 2),
            left: max(0, (scrollView.bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
    }
    @objc func fit() {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.setContentOffset(CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top), animated: false)
        scrollViewDidZoom(scrollView)
    }
    @objc func zoomIn() { zoom(by: 2) }
    @objc func zoomOut() { zoom(by: 0.5) }
    private func zoom(by factor: CGFloat) {
        let scale = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scrollView.zoomScale * factor))
        let center = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: imageView)
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height), animated: false)
    }
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.01 { fit() }
        else { zoomIn() }
    }
    @objc func close() { onClose?() }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close)),
         UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(zoomIn)),
         UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(zoomIn)),
         UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(zoomOut)),
         UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(fit))]
        + [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow,
           UIKeyCommand.inputDownArrow, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(panFromKey(_:)))
        }
    }

    @objc private func panFromKey(_ command: UIKeyCommand) {
        var point = scrollView.contentOffset
        switch command.input {
        case UIKeyCommand.inputLeftArrow: point.x -= 40
        case UIKeyCommand.inputRightArrow: point.x += 40
        case UIKeyCommand.inputUpArrow: point.y -= 40
        case UIKeyCommand.inputDownArrow: point.y += 40
        case UIKeyCommand.inputPageUp: point.y -= scrollView.bounds.height * 0.9
        case UIKeyCommand.inputPageDown: point.y += scrollView.bounds.height * 0.9
        default: return
        }
        point.x = max(-scrollView.contentInset.left, min(point.x,
            max(-scrollView.contentInset.left, scrollView.contentSize.width - scrollView.bounds.width)))
        point.y = max(-scrollView.contentInset.top, min(point.y,
            max(-scrollView.contentInset.top, scrollView.contentSize.height - scrollView.bounds.height)))
        scrollView.setContentOffset(point, animated: false)
    }
}
#endif
