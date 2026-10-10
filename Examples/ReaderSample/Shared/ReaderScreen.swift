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
    @State private var pageInput = 0

    private var pageControls: EPUBPageControls {
        switch pageInput {
        case 1: .hostOnly
        case 2: PageControlsExample.customControls
        default: .init()
        }
    }

    private var pageInputMenu: some View {
        Menu("Page Input", systemImage: "keyboard") {
            Picker("Page Input", selection: $pageInput) {
                Text("Default").tag(0)
                Text("Host Only").tag(1)
                Text("Custom: ⇧⌘N / ⇧⌘P").tag(2)
            }
        }
    }

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
                Button(useToolbar ? "Embed Controls" : "Use Toolbar") { useToolbar.toggle() }.padding(6)
                if !useToolbar, let controls = reader.controls {
                    EPUBReaderControlStrip(controls: controls) {
                        pageInputMenu
                        if session.capabilities.contains(.bookmarks) {
                            Button("Save Position") { reader.savePosition() }
                            Button("Restore Position") { reader.restorePosition() }
                        }
                    }.padding(.horizontal).id(reader.sessionID)
                }
                EPUBReaderView(session: session)
                    .epubReaderPageControls(pageControls)
                    .id(reader.sessionID)
                Text(book.metadata.title).font(.caption).padding(6)
            } else {
                ContentUnavailableView("Open a book", systemImage: "book", description: Text("Choose an EPUB file or explore the included sample."))
            }
            if let disclosure = reader.disclosure { Text(disclosure).font(.callout).padding() }
            if let notice = reader.notice { Text(notice).font(.callout).padding() }
            if let selection = reader.selectedText { Text(selection).lineLimit(3).padding() }
            if let error = reader.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
        }
        .toolbar {
            if useToolbar, let controls = reader.controls {
                EPUBReaderToolbar(controls: controls)
                ToolbarItem { pageInputMenu.labelStyle(.iconOnly) }
                ToolbarItem {
                    Button("Save Position", systemImage: "bookmark") { reader.savePosition() }
                        .disabled(!reader.ready)
                }
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

    /// `-SampleBook <path>` opens a book at launch, for automated and visual checks;
    /// `-SampleFlow scrolled`, `-SampleDark YES` and `-SampleFontSize <points>` set its style.
    private func openFromLaunchArguments() {
        guard reader.session == nil, let path = UserDefaults.standard.string(forKey: "SampleBook") else { return }
        reader.open(url: URL(fileURLWithPath: path))
    }

    private func applyLaunchStyle() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "SampleBook") != nil else { return }
        if defaults.string(forKey: "SampleFlow") == "scrolled" { style.flow = .scrolled }
        if defaults.bool(forKey: "SampleDark") { style.isDark = true }
        if defaults.double(forKey: "SampleFontSize") > 0 { style.fontSize = defaults.double(forKey: "SampleFontSize") }
        reader.send(.style(style))
    }
}
