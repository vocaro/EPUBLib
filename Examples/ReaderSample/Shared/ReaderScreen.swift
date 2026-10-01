import EPUBCore
import EPUBReading
import EPUBViewing
import SwiftUI
import UniformTypeIdentifiers

struct ReaderScreen: View {
    @State private var reader = BookReader()
    @State private var importing = false
    @State private var style = EPUBReaderStyle()

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
                ScrollView(.horizontal) {
                    HStack {
                        if session.capabilities.contains(.pagination) {
                            Button("Previous", systemImage: "chevron.left") { reader.send(.previousPage) }
                            Button("Next", systemImage: "chevron.right") { reader.send(.nextPage) }
                        }
                        if session.capabilities.contains(.navigateHref) {
                            Menu("Sections") {
                                ForEach(Array(book.spine.enumerated()), id: \.offset) { index, item in
                                    Button("\(index + 1). \(item.resource.path)") {
                                        reader.send(.navigate(href: item.resource.href))
                                    }
                                }
                            }
                        }
                        if session.capabilities.contains(.typography) {
                            Button("Larger Text") { style.fontSize = min(36, style.fontSize + 2); reader.send(.style(style)) }
                        }
                        if session.capabilities.contains(.scrolling) {
                            Button(style.flow == .paginated ? "Scroll" : "Paginate") {
                                style.flow = style.flow == .paginated ? .scrolled : .paginated
                                reader.send(.style(style))
                            }
                        }
                        if session.capabilities.contains(.bookmarks) {
                            Button("Save Position") { reader.savePosition() }
                            Button("Restore Position") { reader.restorePosition() }
                        }
                    }.padding(.horizontal)
                }.disabled(!reader.ready || reader.busy)
                EPUBReaderView(session: session).id(reader.sessionID)
                Text(book.metadata.title).font(.caption).padding(6)
            } else {
                ContentUnavailableView("Open a book", systemImage: "book", description: Text("Choose an EPUB file or explore the included sample."))
            }
            if let disclosure = reader.disclosure { Text(disclosure).font(.callout).padding() }
            if let notice = reader.notice { Text(notice).font(.callout).padding() }
            if let selection = reader.selectedText { Text(selection).lineLimit(3).padding() }
            if let error = reader.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]) { result in
            switch result {
            case .success(let url): reader.open(url: url)
            case .failure(let error): reader.reportImportError(error)
            }
        }
        .onChange(of: reader.publication?.id) { style = EPUBReaderStyle() }
        .onDisappear { reader.close() }
        .frame(minWidth: 320, minHeight: 400)
    }
}
