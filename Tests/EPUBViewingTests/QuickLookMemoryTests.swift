import Darwin
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opt-in: the memory and time a Quick Look thumbnail or preview of each book takes (#695), for
/// `scripts/measure-quick-look-memory.py` (`doc/testing.md`, "Quick Look memory").
///
/// `EPUBLIB_QUICK_LOOK_INPUTS` names EPUB files, or directories of them, separated by colons;
/// `EPUBLIB_QUICK_LOOK_CALL` is `thumbnail` (the default) or `preview`; a report goes to
/// `EPUBLIB_QUICK_LOOK_REPORT` when it is set. Each book is made into a thumbnail of at most 512
/// points at 2 pixels a point, drawn, or into a preview, mounted and kept until its reader has
/// built the opening. A row records the process's footprint before the call, the most it rose
/// while the call ran (sampled every millisecond, so a shorter spike can be missed), the
/// kernel's lifetime peak footprint after it, the memory pressure level before and after, and
/// the call's time. The lifetime peak is the process's high-water mark: over one book in a
/// fresh process it bounds that book's call, and over many in one process it bounds every one.
@MainActor final class QuickLookMemoryTests: XCTestCase {
    func testQuickLookMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputs = environment["EPUBLIB_QUICK_LOOK_INPUTS"], !inputs.isEmpty else {
            throw XCTSkip("Set EPUBLIB_QUICK_LOOK_INPUTS to measure Quick Look calls")
        }
        let call = environment["EPUBLIB_QUICK_LOOK_CALL"] ?? "thumbnail"
        guard call == "thumbnail" || call == "preview" else { return XCTFail("Unknown call \(call)") }
        let files = try Self.books(inputs)
        XCTAssertFalse(files.isEmpty, "no EPUB file in \(inputs)")
        var rows = ["book\tcall\toutcome\tarchive_bytes\tfootprint_before\tsampled_rise\tlifetime_peak\tpressure_before\tpressure_after\tmilliseconds"]
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let before = Self.footprint(), pressureBefore = Self.pressureLevel()
            let sampler = FootprintSampler(baseline: before.current)
            let start = ContinuousClock.now
            let outcome = call == "thumbnail" ? Self.thumbnail(file) : await Self.preview(file)
            let elapsed = start.duration(to: .now)
            let rise = sampler.stop()
            let after = Self.footprint(), pressureAfter = Self.pressureLevel()
            let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
            rows.append([file.lastPathComponent, call, outcome, "\(size)", "\(before.current)", "\(rise)", "\(after.peak)",
                         "\(pressureBefore)", "\(pressureAfter)", String(format: "%.1f", milliseconds)].joined(separator: "\t"))
            print("QUICKLOOK " + rows.last!)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let summary = "QUICKLOOK-SUMMARY call=\(call) books=\(files.count) lifetime_peak=\(Self.footprint().peak) max_rss=\(usage.ru_maxrss)"
        print(summary)
        if let report = environment["EPUBLIB_QUICK_LOOK_REPORT"], !report.isEmpty {
            try (rows + ["# " + summary]).joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    /// The thumbnail Finder's largest icons ask for, drawn: "cover", "titlePage" or the error.
    private static func thumbnail(_ file: URL) -> String {
        do {
            let thumbnail = try EPUBThumbnail(contentsOf: file, maximumSize: CGSize(width: 512, height: 512), scale: 2)
            guard let image = thumbnail.makeImage() else { return "undrawn" }
            return "\(thumbnail.content == .cover ? "cover" : "titlePage") \(image.width)x\(image.height)"
        } catch {
            return "refused \(error)".replacingOccurrences(of: "\t", with: " ")
        }
    }

    /// The preview, read off the main actor as an extension reads it, then mounted until its
    /// reader is ready and has built the opening; "opening N" or why not.
    private static func preview(_ file: URL) async -> String {
        let preview: EPUBPreview
        do {
            preview = try await Task.detached { try EPUBPreview(contentsOf: file) }.value
        } catch {
            return "refused \(error)".replacingOccurrences(of: "\t", with: " ")
        }
        let view = EPUBPreviewView(preview: preview)
        #if os(macOS)
        let window = makeMacTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                                       backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.close(); window.contentView = nil }
        let root: PlatformView? = window.contentView
        #else
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let root: PlatformView? = window
        #endif
        let deadline = TestDeadline(seconds: 30)
        var session: NativeSession?
        while deadline.state == .running {
            session = canvases(in: root).first?.dataSource as? NativeSession
            if let session, session.isReady, session.book.isComplete { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let session, session.isReady, session.book.isComplete else { return "unmeasured: not built within 30 s" }
        return "opening \(session.book.count) of \(preview.opening.spine.count)"
    }

    private static func canvases(in view: PlatformView?) -> [ReaderCanvasView] {
        guard let view else { return [] }
        if let canvas = view as? ReaderCanvasView { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }

    private static func books(_ inputs: String) throws -> [URL] {
        try inputs.split(separator: ":").flatMap { path -> [URL] in
            let url = URL(fileURLWithPath: String(path))
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "epub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// The task's footprint now and its lifetime peak, in bytes (`task_vm_info`).
    nonisolated static func footprint() -> (current: Int64, peak: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? (Int64(info.phys_footprint), info.ledger_phys_footprint_peak) : (0, 0)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical; 0 unread.
    nonisolated static func pressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : 0
    }
}

/// The most the footprint rose above a baseline, sampled every millisecond on its own thread.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Int64
    private var running = true
    private let baseline: Int64
    private let thread: Thread

    init(baseline: Int64) {
        self.baseline = baseline
        highest = baseline
        let box = Box()
        thread = Thread { box.sampler?.run() }
        box.sampler = self
        thread.start()
    }

    private final class Box: @unchecked Sendable { weak var sampler: FootprintSampler? }

    private func run() {
        while lock.withLock({ running }) {
            let now = QuickLookMemoryTests.footprint().current
            lock.withLock { highest = max(highest, now) }
            usleep(1_000)
        }
    }

    /// Stops sampling, and gives the most the footprint rose above the baseline, in bytes.
    func stop() -> Int64 {
        let now = QuickLookMemoryTests.footprint().current
        return lock.withLock {
            running = false
            highest = max(highest, now)
            return highest - baseline
        }
    }
}
