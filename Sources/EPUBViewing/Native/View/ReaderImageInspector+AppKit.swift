#if os(macOS)
import AppKit

/// A native magnifying scroll view, isolated from the book's page controls and selection.
@MainActor final class ReaderImageInspector: NSView {
    let scrollView = NSScrollView()
    let imageView = NSImageView()
    private let toolbar = NSView()
    private var controls: [NSButton] = []
    private let status = NSTextField(labelWithString: "")
    private var needsFit = true
    private var lastViewport = CGSize.zero
    private var safeAreaObservation: NSKeyValueObservation?
    var onClose: (() -> Void)?

    init(bitmap: CGImage, label: String, theme: ReaderTheme) {
        super.init(frame: .zero)
        // The bar keeps clear of a toolbar shown over the reader, as the pages do
        // (`ReaderCanvasView.platformSetUp`).
        safeAreaObservation = observe(\.safeAreaInsets) { inspector, _ in
            MainActor.assumeIsolated { inspector.needsLayout = true }
        }
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Image inspection")
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        imageView.image = NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height))
        imageView.imageScaling = .scaleNone
        imageView.frame = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        imageView.setAccessibilityLabel(label.isEmpty ? nil : label)
        scrollView.contentView = ReaderImageClipView()
        scrollView.documentView = imageView
        addSubview(scrollView)
        for (title, action) in [("−", #selector(zoomOut)), ("+", #selector(zoomIn)),
                                 ("Fit", #selector(fit)), ("Close", #selector(close))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(title == "+" ? "Zoom In" : title == "−" ? "Zoom Out" : title)
            button.toolTip = title == "+" ? "Zoom In (⌘+)" : title == "−" ? "Zoom Out (⌘−)" : title
            controls.append(button)
            toolbar.addSubview(button)
        }
        status.setAccessibilityLabel("Magnification")
        toolbar.addSubview(status)
        addSubview(toolbar)
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func open() {
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func layout() {
        super.layout()
        let area = safeAreaRect
        toolbar.frame = CGRect(x: area.minX + 8, y: area.minY + 8, width: max(1, area.width - 16), height: 36)
        var x: CGFloat = 0
        for (index, button) in controls.enumerated() {
            let width: CGFloat = index == 3 ? 64 : 44
            button.frame = CGRect(x: x, y: 0, width: width, height: 32)
            x += width + 8
        }
        status.frame = CGRect(x: x, y: 7, width: max(0, toolbar.bounds.width - x), height: 20)
        status.isHidden = toolbar.bounds.width - x < 50
        scrollView.frame = CGRect(x: area.minX, y: area.minY + 52, width: area.width, height: max(1, area.height - 52))
        if scrollView.contentSize != lastViewport {
            let oldFit = ReaderImageInspection.fitScale(image: imageView.frame.size, viewport: lastViewport)
            needsFit = needsFit || abs(scrollView.magnification - oldFit) < 0.001
            lastViewport = scrollView.contentSize
        }
        let minimum = ReaderImageInspection.fitScale(image: imageView.frame.size, viewport: scrollView.contentSize)
        scrollView.minMagnification = minimum
        scrollView.maxMagnification = ReaderImageInspection.maximumScale(fit: minimum)
        if needsFit { needsFit = false; fit() }
    }

    @objc func fit() {
        scrollView.setMagnification(scrollView.minMagnification, centeredAt: imageView.bounds.center)
        magnificationChanged()
    }
    @objc func zoomIn() { zoom(by: 2) }
    @objc func zoomOut() { zoom(by: 0.5) }
    private func zoom(by factor: CGFloat) {
        let center = imageView.convert(scrollView.contentView.bounds.center, from: scrollView.contentView)
        scrollView.setMagnification(min(scrollView.maxMagnification, max(scrollView.minMagnification,
                                   scrollView.magnification * factor)), centeredAt: center)
        magnificationChanged()
    }
    @objc private func magnificationChanged() { status.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%" }
    @objc func close() { onClose?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 123: pan(dx: -40, dy: 0)
        case 124: pan(dx: 40, dy: 0)
        case 125: pan(dx: 0, dy: -40)
        case 126: pan(dx: 0, dy: 40)
        case 116: pan(dx: 0, dy: scrollView.contentSize.height * 0.9)
        case 121: pan(dx: 0, dy: -scrollView.contentSize.height * 0.9)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoomIn()
            case "-": zoomOut()
            case "0": fit()
            default: scrollView.keyDown(with: event)
            }
        }
    }
    private func pan(dx: CGFloat, dy: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX + dx / scrollView.magnification,
                                y: clip.bounds.minY + dy / scrollView.magnification))
        scrollView.reflectScrolledClipView(clip)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "0": fit()
        case "w": close()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// NSScrollView otherwise parks a short image against the lower edge of its viewport.
@MainActor private final class ReaderImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if documentView.frame.width < result.width { result.origin.x = documentView.frame.midX - result.width / 2 }
            if documentView.frame.height < result.height { result.origin.y = documentView.frame.midY - result.height / 2 }
        }
        return result
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
#endif
