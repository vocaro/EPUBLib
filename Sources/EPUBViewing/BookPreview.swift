import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import SwiftUI

/// What a Quick Look preview extension's `QLPreviewingController` shows of a book: its cover,
/// title and authors, and the opening of its text, which `EPUBPreviewView` shows.
///
/// The book is opened on demand, and the opening is its first sections and no more
/// (`openingSections`, `openingBytes`): the preview's reader builds only those, and reads only
/// the resources they use (`doc/native-viewer.md`, "Quick Look").
public struct EPUBPreview: Sendable {
    /// The most linear sections an opening holds.
    public static let openingSections = 4
    /// The content documents' bytes after which an opening holds no further section.
    public static let openingBytes = 256 * 1024

    public let title: String
    public let authors: [String]
    /// The cover, decoded for the size the preview was made for; nil when the book has none that
    /// can be drawn.
    public let cover: EPUBThumbnail?
    /// The book with its spine cut to its opening: the items from the first through the
    /// `openingSections`-th linear one, or through the linear one that brings the linear items'
    /// documents to `openingBytes`, whichever comes first. Everything else is the book's.
    public let opening: EPUBPublication

    /// Opens the book at `url` on demand and reads its opening and its cover, decoded for at
    /// most `coverSize` points at `scale` pixels a point. Call it off the main actor.
    public init(contentsOf url: URL, coverSize: CGSize = CGSize(width: 240, height: 360), scale: CGFloat = 2,
                limits: EPUBImportLimits = .quickLook) throws {
        let publication = try EPUBPublication.open(at: url, limits: limits, onDemand: true)
        self.init(publication: publication, coverSize: coverSize, scale: scale)
    }

    /// The preview of a book already open.
    public init(publication: EPUBPublication, coverSize: CGSize = CGSize(width: 240, height: 360), scale: CGFloat = 2) {
        title = publication.metadata.title
        authors = publication.metadata.authors
        let cover = EPUBThumbnail(publication: publication, maximumSize: coverSize, scale: scale)
        self.cover = cover.content == .cover ? cover : nil
        opening = Self.opening(of: publication)
    }

    static func opening(of publication: EPUBPublication) -> EPUBPublication {
        var items = 0, linear = 0, bytes = 0
        for item in publication.spine {
            items += 1
            // A book with no linear item, or a long run of nonlinear ones, stops all the same.
            if items >= openingSections * 4 { break }
            guard item.isLinear else { continue }
            linear += 1
            bytes += (try? publication.data(for: item.resource).count) ?? 0
            if linear >= openingSections || bytes >= openingBytes { break }
        }
        return publication.prefix(spineItems: items)
    }
}

/// A read-only preview of a book for a Quick Look preview extension: the cover, title and
/// authors beside the opening of the book in continuous scroll, or above it where the view is
/// narrower than it is tall. The opening is shown by the package's reader, which the view opens
/// when it appears and closes when it disappears. The reader keeps text selection and copying
/// and has no page-turning edges.
///
/// An extension's view controller shows it in an `NSHostingView` or `UIHostingController` once
/// `EPUBPreview` has read the book (`doc/integration.md`, "Quick Look extensions").
@MainActor public struct EPUBPreviewView: View {
    private let preview: EPUBPreview
    @State private var pages = PreviewPages()

    public init(preview: EPUBPreview) { self.preview = preview }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 560, geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    ScrollView { details(coverHeight: min(360, geometry.size.height * 0.6)).padding(24) }
                        .frame(width: min(320, geometry.size.width * 0.36))
                    Divider()
                    reader
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        coverImage(height: min(120, geometry.size.height * 0.25))
                        names
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    Divider()
                    reader
                }
            }
        }
        .onAppear { pages.open(preview.opening) }
        .onDisappear { pages.close() }
    }

    private func details(coverHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            coverImage(height: coverHeight)
            names
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func coverImage(height: CGFloat) -> some View {
        if let cover = preview.cover, let image = cover.image {
            Image(image, scale: cover.scale, label: Text("Cover"))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: height)
                .shadow(radius: 2)
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.title.isEmpty ? "Untitled" : preview.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if !preview.authors.isEmpty {
                Text(preview.authors.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let disclosure = pages.disclosure {
                Text(disclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private var reader: some View {
        if let failure = pages.failure {
            Text(failure)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let session = pages.session {
            EPUBReaderView(session: session)
                .epubReaderPageControls(PreviewPages.pageControls)
                .id(pages.generation)
        } else {
            Color.clear
        }
    }
}

/// The reader an `EPUBPreviewView` shows the opening in, one session from the view's appearance
/// to its disappearance.
@MainActor @Observable final class PreviewPages {
    /// Continuous scroll turns no pages, so no edge or swipe is claimed from the host: a swipe
    /// in Quick Look moves to the next file.
    static let pageControls = EPUBPageControls(edgeTapsEnabled: false, touchSwipesEnabled: false)

    private(set) var session: (any EPUBReaderSession)?
    /// A session's view identity: a new one for each session.
    private(set) var generation = UUID()
    private(set) var failure: String?
    private(set) var disclosure: String?

    func open(_ opening: EPUBPublication) {
        guard session == nil else { return }
        let token = UUID()
        generation = token
        failure = nil
        disclosure = nil
        do {
            session = try NativeSession(publication: opening, action: nil, rich: NativeRichContent(),
                                        flow: .scrolled) { [weak self] event in
                guard let self, generation == token else { return }
                switch event {
                case .failed(let error): failure = error.message
                case .disclosure(let text): disclosure = text
                default: break
                }
            }
        } catch {
            failure = (error as? EPUBReaderError)?.message ?? String(describing: error)
        }
    }

    func close() {
        generation = UUID()
        session?.close()
        session = nil
    }
}
