import EPUBCore
import EPUBViewing
import Foundation
import QuickLookThumbnailing
import SwiftUI
#if os(macOS)
import AppKit
import QuickLookUI
#else
import QuickLook
import UIKit
#endif

// snippet:start quickLook
/// A Quick Look thumbnail extension's principal class.
final class BookThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let thumbnail = try EPUBThumbnail(contentsOf: request.fileURL, maximumSize: request.maximumSize,
                                              scale: request.scale)
            handler(QLThumbnailReply(contextSize: thumbnail.size) { context in thumbnail.draw(in: context) }, nil)
        } catch {
            handler(nil, error)
        }
    }
}

#if os(macOS)
/// A Quick Look preview extension's principal class.
final class BookPreviewController: NSViewController, QLPreviewingController {
    override func loadView() { view = NSView() }

    func preparePreviewOfFile(at url: URL) async throws {
        let preview = try await Task.detached { try EPUBPreview(contentsOf: url) }.value
        let host = NSHostingView(rootView: EPUBPreviewView(preview: preview))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
    }
}
#else
/// A Quick Look preview extension's principal class.
final class BookPreviewController: UIViewController, QLPreviewingController {
    func preparePreviewOfFile(at url: URL) async throws {
        let preview = try await Task.detached { try EPUBPreview(contentsOf: url) }.value
        let host = UIHostingController(rootView: EPUBPreviewView(preview: preview))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
#endif
// snippet:end quickLook
