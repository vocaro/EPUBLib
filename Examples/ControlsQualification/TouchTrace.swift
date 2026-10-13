#if os(iOS)
import os
import UIKit

/// `-QualificationTouchTrace YES` records what each touch did, the probe's or a finger's. The
/// accessibility tree shows where things stand after a touch and not what became of the touch:
/// whether it rested before it moved, and whether a scroll view or the control under it took
/// it. A scroll view holds a touch for a moment before the control under it has it, so the
/// same drag scrolls or does not by how long it rested. Every touch is read where the
/// application receives it, before any window, view or gesture recognizer has it, so the
/// record changes nothing it records.
///
/// Each touch gets a number. Its lines say where it went down and on which view, how long it
/// stayed and how far it went, when each scroll view began to drag, and where the scroll views,
/// the keyboard and the windows stood before it, as it lifted and a second later. A picture of
/// the windows at that second, the touch drawn on it, is kept as `touch-<number>.png`. The
/// host's line of reader state is recorded whenever it changes, and so is the application
/// becoming active or inactive and any two seconds in which its main thread did not run: an
/// application that is covered or hung receives no touch, and the record would only be silent.
/// Everything goes to standard output and to `Documents/touch-trace-<launch time>/`. On a
/// device the keyboard is another process: touches on it are not seen, and it is in no picture.
@MainActor final class TouchTrace {
    static let shared = TouchTrace()

    private struct Stroke {
        let number: Int
        let began: TimeInterval
        let start: CGPoint
        var end: CGPoint
        var reach: CGFloat = 0
        var movedAfter: TimeInterval?
        var dragged: [(name: String, after: TimeInterval)] = []
        let scrollViews: [UIScrollView]
    }

    private var folder: URL?
    private var log: FileHandle?
    private let launch = ProcessInfo.processInfo.systemUptime
    private var strokes: [ObjectIdentifier: Stroke] = [:]
    private var count = 0
    private var keyboard = CGRect.null
    private var windowsLine = ""

    func start() {
        guard folder == nil else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let folder = URL.documentsDirectory.appending(path: "touch-trace-\(stamp)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(path: "trace.txt").path
        log = FileHandle(fileDescriptor: open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644), closeOnDealloc: true)
        self.folder = folder
        let device = UIDevice.current
        var system = utsname()
        uname(&system)
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "a simulated " + $0 }
            ?? withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        note("trace \(stamp) on \(model), \(device.systemName) \(device.systemVersion), arguments "
             + ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))
        if let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
           let traced = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.qualificationTraced(_:))) {
            method_exchangeImplementations(original, traced)
        }
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardDidHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    if let frame { TouchTrace.shared.keyboard = frame }
                    TouchTrace.shared.note(name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "keyboard ")
                        .replacingOccurrences(of: "Notification", with: "") + " " + TouchTrace.shared.keyboardLine())
                }
            }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    TouchTrace.shared.note(name.rawValue.replacingOccurrences(of: "UIApplication", with: "application ")
                        .replacingOccurrences(of: "Notification", with: ""))
                }
            }
        }
        watchMainThread(path: path)
    }

    /// One line of the record, stamped with the seconds since launch.
    func note(_ text: String) {
        guard folder != nil else { return }
        let line = Self.line(text, since: launch)
        print("TOUCHTRACE " + line)
        try? log?.write(contentsOf: Data((line + "\n").utf8))
    }

    private nonisolated static func line(_ text: String, since launch: TimeInterval) -> String {
        String(format: "%8.3f %@", ProcessInfo.processInfo.systemUptime - launch, text)
    }

    /// A timer marks each quarter second in which the main thread ran, in every run loop mode,
    /// so that a long drag is not taken for a stall. Another thread reads the mark and writes a
    /// line of its own, since the main thread cannot, with five seconds between repeats.
    private func watchMainThread(path: String) {
        let mark = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in mark.withLock { $0 = ProcessInfo.processInfo.systemUptime } }
        RunLoop.main.add(timer, forMode: .common)
        let launch = launch
        Thread.detachNewThread {
            let log = FileHandle(fileDescriptor: open(path, O_WRONLY | O_APPEND), closeOnDealloc: true)
            func write(_ text: String) {
                let line = Self.line(text, since: launch)
                print("TOUCHTRACE " + line)
                try? log.write(contentsOf: Data((line + "\n").utf8))
            }
            var reported = 0.0
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let idle = ProcessInfo.processInfo.systemUptime - mark.withLock { $0 }
                if idle >= 2, reported == 0 || idle - reported >= 5 {
                    reported = idle
                    write(String(format: "the main thread has not run for %.1f s", idle))
                } else if idle < 2, reported > 0 {
                    write(String(format: "the main thread ran again, after at least %.1f s", reported))
                    reported = 0
                }
            }
        }
    }

    fileprivate func record(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch), point = touch.location(in: nil)
            switch touch.phase {
            case .began:
                count += 1
                strokes[key] = Stroke(number: count, began: touch.timestamp, start: point, end: point, scrollViews: scrollViews())
                let size = touch.window?.bounds.size ?? .zero
                note("touch \(count) down at \(Self.text(point)) in a window of \(Int(size.width)) x \(Int(size.height)), "
                     + "text size \(UIApplication.shared.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: ""))")
                note("touch \(count) on " + Self.lineage(touch.view))
                state("touch \(count) before")
            case .moved, .stationary:
                guard var stroke = strokes[key] else { continue }
                let after = touch.timestamp - stroke.began
                stroke.end = point
                stroke.reach = max(stroke.reach, hypot(point.x - stroke.start.x, point.y - stroke.start.y))
                if stroke.movedAfter == nil, stroke.reach >= 10 { stroke.movedAfter = after }
                for (index, view) in stroke.scrollViews.enumerated() where view.isDragging {
                    let name = "scroll \(index + 1)"
                    if !stroke.dragged.contains(where: { $0.name == name }) { stroke.dragged.append((name, after)) }
                }
                strokes[key] = stroke
            case .ended, .cancelled:
                guard var stroke = strokes.removeValue(forKey: key) else { continue }
                stroke.end = point
                let moved = stroke.movedAfter.map { String(format: "10 points from its start after %.3f s", $0) } ?? "never 10 points from its start"
                note(String(format: "touch %d %@ at %@ after %.3f s, %.0f across and %.0f down from its start, %@",
                            stroke.number, touch.phase == .ended ? "up" : "cancelled", Self.text(point), touch.timestamp - stroke.began,
                            point.x - stroke.start.x, point.y - stroke.start.y, moved))
                note("touch \(stroke.number) dragged " + (stroke.dragged.isEmpty ? "no scroll view"
                    : stroke.dragged.map { String(format: "%@ from %.3f s", $0.name, $0.after) }.joined(separator: ", ")))
                state("touch \(stroke.number) lifted", scrollViews: stroke.scrollViews)
                let lifted = stroke
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    self.state("touch \(lifted.number) a second later", scrollViews: lifted.scrollViews)
                    self.picture(lifted)
                }
            default: break
            }
        }
    }

    // MARK: What the screen holds

    private var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    private func scrollViews() -> [UIScrollView] {
        func found(in view: UIView) -> [UIScrollView] { ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(found) }
        return windows.flatMap(found)
    }

    /// The scroll views a touch found when it went down, numbered as its lines number them, then
    /// the keyboard, and the windows with whatever they hold whose class names a menu.
    private func state(_ label: String, scrollViews: [UIScrollView]? = nil) {
        for (index, view) in (scrollViews ?? self.scrollViews()).enumerated() {
            let frame = view.convert(view.bounds, to: nil)
            var words = [String(format: "%@: scroll %d %@ at %@, offset %.1f of %.1f in %.1f", label, index + 1, Self.name(view),
                                Self.text(frame), view.contentOffset.y, view.contentSize.height, view.bounds.height)]
            if view.adjustedContentInset.top != 0 || view.adjustedContentInset.bottom != 0 {
                words.append(String(format: "insets %.1f and %.1f", view.adjustedContentInset.top, view.adjustedContentInset.bottom))
            }
            if view.window == nil { words.append("gone") }
            if !view.isScrollEnabled { words.append("scrolling off") }
            if view.isDragging { words.append("dragging") }
            if view.isDecelerating { words.append("decelerating") }
            note(words.joined(separator: ", "))
        }
        note("\(label): \(keyboardLine())")
        func menus(in view: UIView) -> [String] {
            (Self.name(view).contains("Menu") ? [Self.name(view)] : []) + view.subviews.flatMap(menus)
        }
        let line = windows.map { window in
            let held = menus(in: window).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return Self.name(window) + (window.isKeyWindow ? " (key)" : "") + (held.isEmpty ? "" : " holding " + held.joined(separator: ", "))
        }.joined(separator: " | ")
        if line != windowsLine {
            windowsLine = line
            note("\(label): windows \(line)")
        }
    }

    private func keyboardLine() -> String {
        let screen = windows.first?.screen.bounds ?? .zero
        let shown = keyboard.intersection(screen)
        return shown.isNull || shown.height < 1 ? "keyboard down" : "keyboard up at \(Self.text(keyboard))"
    }

    /// The windows as they stand, with the touch over them: a ring where it went down and a
    /// line to where it lifted.
    private func picture(_ stroke: Stroke) {
        guard let folder, let bounds = windows.first?.bounds else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(bounds)
            for window in windows where !window.isHidden { window.drawHierarchy(in: window.frame, afterScreenUpdates: false) }
            UIColor.systemRed.setStroke()
            let path = UIBezierPath(ovalIn: CGRect(x: stroke.start.x - 8, y: stroke.start.y - 8, width: 16, height: 16))
            path.move(to: stroke.start)
            path.addLine(to: stroke.end)
            path.lineWidth = 2
            path.stroke()
        }
        let name = "touch-\(stroke.number).png"
        try? image.pngData()?.write(to: folder.appending(path: name))
        note("touch \(stroke.number) pictured in \(name)")
    }

    // MARK: Words

    private static func text(_ point: CGPoint) -> String { String(format: "(%.0f, %.0f)", point.x, point.y) }
    private static func text(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f %.0f x %.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// A class name without its generic arguments, which for a SwiftUI host run to hundreds of characters.
    private static func name(_ object: AnyObject) -> String {
        String(String(describing: type(of: object)).prefix { $0 != "<" })
    }

    /// The view a touch went down on and the views that hold it, innermost first, with any
    /// accessibility label and the frame in the window of the innermost.
    private static func lineage(_ view: UIView?) -> String {
        guard let view else { return "no view" }
        var names: [String] = []
        var next: UIView? = view
        while let current = next, names.count < 8 {
            names.append(name(current) + (current.accessibilityLabel.map { " \"\($0)\"" } ?? ""))
            next = current.superview
        }
        return names.joined(separator: " in ") + ", the first at " + text(view.convert(view.bounds, to: nil))
    }
}

private extension UIApplication {
    /// Stands in for `sendEvent(_:)` once the two are exchanged, and then calls the original.
    @objc func qualificationTraced(_ event: UIEvent) {
        TouchTrace.shared.record(event)
        qualificationTraced(event)
    }
}
#endif
