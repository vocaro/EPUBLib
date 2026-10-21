import EPUBCore
import EPUBReading
import EPUBViewing
import SwiftUI
import UniformTypeIdentifiers

struct ReaderScreen: View {
    @State private var reader = BookReader()
    @State private var importing = false
    @State private var useToolbar = false
    @State private var style = EPUBReaderStyle()
    /// `-SampleSelectionLine YES` keeps a line under the reader that says what the reader
    /// reports as selected and what the selection action was last given. It is there from
    /// the start, so neither moves the page, and an automated check can read it.
    private let selectionLine = UserDefaults.standard.bool(forKey: "SampleSelectionLine")
    /// `-SampleControls none` shows the reader with none of the host's controls above it, as a
    /// host that hides them while a book is read: nothing between the open buttons and the page.
    private let showsControls = UserDefaults.standard.string(forKey: "SampleControls") != "none"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Open EPUB…") { importing = true }
                Button("Open Sample") {
                    if let url = Bundle.main.url(forResource: "sample", withExtension: "epub") { reader.open(url: url) }
                }
                Spacer()
                if reader.loading { ProgressView().controlSize(.small) }
                if reader.session != nil { Button("Close") { reader.close() } }
            }.padding()
            if let session = reader.session, let book = reader.publication {
                if showsControls { Button(useToolbar ? "Embed Controls" : "Use Toolbar") { useToolbar.toggle() }.padding(6) }
                if showsControls, !useToolbar, let controls = reader.controls {
                    EPUBReaderControlStrip(controls: controls) {
                        if session.capabilities.contains(.bookmarks) {
                            bookmarkMenu
                        }
                    }
                    // Padding hides the strip's own layout priority from the stack: with it the
                    // strip is offered the height it needs before the reader, and scrolls its
                    // groups where the keyboard leaves it less.
                    .padding(.horizontal).layoutPriority(1).id(reader.sessionID)
                }
                EPUBReaderView(session: session)
                    .id(reader.sessionID)
                Text(book.metadata.title).font(.caption).padding(6)
                if selectionLine {
                    Text("Selected: \(reader.selection ?? "nothing"). Used: \(reader.selectedText ?? "nothing").")
                        .font(.caption).lineLimit(1).padding(.bottom, 6).accessibilityIdentifier("sample.selection")
                }
            } else {
                ContentUnavailableView("Open a book", systemImage: "book", description: Text("Choose an EPUB file or explore the included sample."))
            }
            if let disclosure = reader.disclosure { Text(disclosure).font(.callout).padding() }
            if let notice = reader.notice { Text(notice).font(.callout).padding() }
            if let selection = reader.selectedText, !selectionLine { Text(selection).lineLimit(3).padding() }
            if let error = reader.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
        }
        .toolbar {
            if useToolbar, let controls = reader.controls {
                EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode])
                if controls.supports(.bookmarks) {
                    ToolbarItem {
                        bookmarkMenu.labelStyle(.iconOnly)
                    }
                }
                #if os(iOS)
                EPUBReaderToolbar(controls: controls, groups: [.pages], placement: .topBarPinnedTrailing)
                #else
                ToolbarSpacer(.fixed)
                EPUBReaderToolbar(controls: controls, groups: [.pages])
                #endif
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]) { result in
            switch result {
            case .success(let url): reader.open(url: url)
            case .failure(let error): reader.reportImportError(error)
            }
        }
        .onChange(of: reader.publication?.id) { style = EPUBReaderStyle() }
        .task { openFromLaunchArguments() }
        .onChange(of: reader.ready) { if reader.ready { applyLaunchStyle() } }
        .onDisappear { reader.close() }
        .frame(minWidth: 320, minHeight: 400)
    }

    private var bookmarkMenu: some View {
        Menu("Bookmark", systemImage: reader.savedPosition == nil ? "bookmark" : "bookmark.fill") {
            Button("Save Bookmark", systemImage: "bookmark") { reader.savePosition() }
                .disabled(!reader.ready || reader.location == nil)
            Button("Return to Bookmark", systemImage: "arrow.uturn.backward") { reader.restorePosition() }
                .disabled(!reader.ready || reader.savedPosition == nil)
            Button("Clear Bookmark", systemImage: "bookmark.slash", role: .destructive) { reader.clearPosition() }
                .disabled(reader.savedPosition == nil)
        }
        .disabled(!reader.ready)
        .help("Save, return to, or clear this book's bookmark")
        .accessibilityValue(reader.savedPosition == nil ? "No bookmark saved" : "Bookmark saved")
    }

    /// `-SampleBook <path>` opens a book at launch, for automated and visual checks;
    /// `-SampleFlow scrolled`, `-SampleDark YES` and `-SampleFontSize <points>` set its style,
    /// `-SampleHref <href>` shows one of its sections, `-SampleSelectionLine YES` a line that
    /// says what is selected, and `-SampleStepAfter <seconds>` sends Next Page once, that long
    /// after the book is ready: a move the host makes with nothing on screen touched for it.
    /// `-SampleDarkAfter <seconds>` makes the reader dark that long after the book is ready,
    /// as a host does that follows the time of day: the same text is shown again in place.
    /// `-SampleSearch <query>` submits that search once the book is ready, as its field does,
    /// so that the strip has results to step through, or `-SampleSearchAfter <seconds>` later:
    /// after the text built again for `-SampleFontSize`, which moves the view under a search.
    private func openFromLaunchArguments() {
        guard reader.session == nil, let path = UserDefaults.standard.string(forKey: "SampleBook") else { return }
        reader.open(url: URL(fileURLWithPath: path))
    }

    private func applyLaunchStyle() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "SampleBook") != nil else { return }
        if defaults.string(forKey: "SampleFlow") == "scrolled" { style.flow = .scrolled }
        if defaults.bool(forKey: "SampleDark") { style.appearance = .dark }
        if defaults.double(forKey: "SampleFontSize") > 0 { style.fontSize = defaults.double(forKey: "SampleFontSize") }
        reader.send(.style(style))
        if let href = defaults.string(forKey: "SampleHref") { reader.send(.navigate(href: href)) }
        if let query = defaults.string(forKey: "SampleSearch"), let controls = reader.controls {
            Task {
                try? await Task.sleep(for: .seconds(defaults.double(forKey: "SampleSearchAfter")))
                controls.searchText = query
                controls.submitSearch()
            }
        }
        let delay = defaults.double(forKey: "SampleStepAfter")
        if delay > 0 {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                if let href = defaults.string(forKey: "SampleStepHref") {
                    reader.send(.navigate(href: href))
                } else {
                    reader.send(.nextPage)
                }
            }
        }
        let dark = defaults.double(forKey: "SampleDarkAfter")
        if dark > 0 {
            Task {
                try? await Task.sleep(for: .seconds(dark))
                style.appearance = .dark
                reader.send(.style(style))
            }
        }
    }
}
