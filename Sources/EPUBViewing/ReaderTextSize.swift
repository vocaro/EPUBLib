import EPUBCore
import Foundation

/// Smaller Text and Larger Text: the sizes they choose among, the steps between them and what
/// VoiceOver hears of them (doc/reader-controls.md, "Commands, appearance and state").
extension EPUBReaderControl {
    /// The sizes the bundled reader draws, 12 to 96 points. Nothing smaller than 12 or larger
    /// than 96 is drawn, so a step beyond either changed the style and not the page.
    static let textSizes: ClosedRange<Double> = 12...96

    /// The next size on the controls' ladder: two points at a time up to 36, four up to 48 and
    /// eight up to 96, so that a step changes the page about as much to the eye at every size
    /// and 96 is 22 steps from 12. A size off the ladder, as a host may set, steps to the next
    /// that is, stopping at 36 and 48. A size outside the range steps from its nearer end.
    static func textSize(_ size: Double, larger: Bool) -> Double {
        let from = min(max(size, textSizes.lowerBound), textSizes.upperBound)
        if larger {
            var next = from + (from < 36 ? 2 : from < 48 ? 4 : 8)
            for boundary in [36.0, 48] where from < boundary && next > boundary { next = boundary }
            return min(next, textSizes.upperBound)
        }
        var next = from - (from > 48 ? 8 : from > 36 ? 4 : 2)
        for boundary in [48.0, 36] where from > boundary && next < boundary { next = boundary }
        return max(next, textSizes.lowerBound)
    }

    /// The size drawn for the chosen `size` at `scale`, the system text size's
    /// (`EPUBReaderStatus.dynamicTypeScale`).
    static func drawnTextSize(_ size: Double, scale: Double) -> Double {
        min(max(size * scale, textSizes.lowerBound), textSizes.upperBound)
    }

    /// The chosen size one press of Larger Text or Smaller Text gives: the nearest on the ladder
    /// that is drawn at a different size, moving the way the control says. nil where none is,
    /// which disables the control. With a system text size the steps of the chosen size can
    /// draw alike at either end, where one size is drawn for several.
    static func textSize(_ size: Double, larger: Bool, scale: Double) -> Double? {
        let drawn = drawnTextSize(size, scale: scale)
        var next = size
        repeat {
            let step = textSize(next, larger: larger)
            guard larger ? step > next : step < next else { return nil }
            next = step
        } while drawnTextSize(next, scale: scale) == drawn
        return next
    }

    /// The text size as VoiceOver reads it, in whole points: "17 points".
    static func textSizeDescription(_ points: Double) -> String {
        "\(Int(points.rounded())) points"
    }
}

extension EPUBReaderControls {
    /// What the system text size multiplies the chosen size by; 1 where the engine does not say.
    var textSizeScale: Double { status?.dynamicTypeScale ?? 1 }

    /// The size the reader draws: the engine's own report, or the chosen size within the range.
    var drawnTextSize: Double {
        status?.effectiveFontSize
            ?? EPUBReaderControl.drawnTextSize(status?.style.fontSize ?? EPUBReaderStyle().fontSize, scale: textSizeScale)
    }

    /// Whether Larger Text or Smaller Text would change the size drawn.
    func canStepTextSize(larger: Bool) -> Bool {
        EPUBReaderControl.textSize(status?.style.fontSize ?? EPUBReaderStyle().fontSize, larger: larger, scale: textSizeScale) != nil
    }

    /// Larger Text or Smaller Text: the next size from the style as it stands when the command
    /// executes. Once the engine has taken it, an assistive technology says the size it reports
    /// drawing, while its cursor stays on the control.
    func stepTextSize(larger: Bool) {
        changeStyle({ [weak self] style in
            let scale = self?.textSizeScale ?? 1
            if let next = EPUBReaderControl.textSize(style.fontSize, larger: larger, scale: scale) { style.fontSize = next }
        }, then: { [weak self] in self?.announceDrawnTextSize() })
    }

    /// Whether Actual Size would change the size: the chosen size is not the style's default.
    var canResetTextSize: Bool {
        canChangeStyle && (status?.style.fontSize ?? EPUBReaderStyle().fontSize) != EPUBReaderStyle().fontSize
    }

    /// Actual Size: the style's default size, 17 points, which the system text size still scales
    /// while Use System Text Size is on. The size drawn is then announced, as after a step.
    func resetTextSize() {
        changeStyle({ $0.fontSize = EPUBReaderStyle().fontSize }, then: { [weak self] in self?.announceDrawnTextSize() })
    }

    private func announceDrawnTextSize() {
        postAnnouncement(EPUBReaderControl.textSizeDescription(drawnTextSize))
    }
}
