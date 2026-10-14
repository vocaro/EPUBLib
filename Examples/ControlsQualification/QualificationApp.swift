import EPUBCore
import EPUBReading
import EPUBViewing
import SwiftUI

/// A minimal host for operating the supplied reader controls live: one bundled synthetic book,
/// opened at launch, in an ordinary `NavigationStack`. Launch arguments choose the book, the
/// arrangement and the toolbar placement; see "Reader controls probe" in doc/testing.md.
@main struct ControlsQualificationApp: App {
    #if os(iOS)
    /// `-QualificationTouchTrace YES` records every touch and what took it; see `TouchTrace`.
    init() {
        if UserDefaults.standard.bool(forKey: "QualificationTouchTrace") { TouchTrace.shared.start() }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            NavigationStack { QualificationScreen() }
                #if os(macOS)
                .frame(minWidth: 320, minHeight: 400)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}

@MainActor @Observable final class QualificationModel {
    private(set) var controls: EPUBReaderControls?
    private(set) var failure: String?

    /// `-QualificationBook ltr|rtl|long` chooses the bundled book.
    func open() async {
        guard controls == nil, failure == nil else { return }
        let name = "controls-" + (UserDefaults.standard.string(forKey: "QualificationBook") ?? "ltr")
        do {
            guard let url = Bundle.main.url(forResource: name, withExtension: "epub") else { throw CocoaError(.fileNoSuchFile) }
            let book = try await Task.detached { try EPUBPublication.open(at: url) }.value
            let session = try EPUBReader().makeSession(publication: book, selectionAction: nil) { [weak self] event in
                if case .ready = event { self?.applyLaunchStyle() }
            }
            controls = EPUBReaderControls(publication: book, session: session)
        } catch {
            failure = String(describing: error)
        }
    }

    /// `-QualificationFlow scrolled` and `-QualificationFontSize <points>` set the opening style.
    private func applyLaunchStyle() {
        let defaults = UserDefaults.standard
        let scrolled = defaults.string(forKey: "QualificationFlow") == "scrolled"
        let size = defaults.double(forKey: "QualificationFontSize")
        guard scrolled || size > 0 else { return }
        controls?.changeStyle {
            if scrolled { $0.flow = .scrolled }
            if size > 0 { $0.fontSize = size }
        }
    }
}

struct QualificationScreen: View {
    @State private var model = QualificationModel()
    @State private var browsing = false
    private let defaults = UserDefaults.standard

    var body: some View {
        Group {
            if let controls = model.controls { host(controls) }
            else { Text(model.failure ?? "Opening…") }
        }
        .task { await model.open() }
        #if os(macOS)
        .task { Self.applyLaunchWindowSize() }
        #endif
    }

    #if os(macOS)
    /// `-QualificationWindowSize 440x700` opens the Mac window at that content size, for the
    /// toolbar's overflow at narrow widths without a drag.
    private static func applyLaunchWindowSize() {
        let parts = (UserDefaults.standard.string(forKey: "QualificationWindowSize") ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
    }
    #endif

    /// `-QualificationHost toolbar|strip|navigator`: the toolbar of doc/reader-controls.md, the
    /// embedded control strip, or the host-placed match navigator and result list.
    @ViewBuilder private func host(_ controls: EPUBReaderControls) -> some View {
        switch defaults.string(forKey: "QualificationHost") ?? "toolbar" {
        case "strip":
            VStack(spacing: 0) {
                // Padding and a frame hide the strip's own layout priority from the stack.
                strip(controls).padding(.horizontal).layoutPriority(1)
                reader(controls)
            }
        case "navigator":
            titled(reader(controls), controls)
                .toolbar {
                    EPUBReaderToolbar(controls: controls, groups: [.search, .contents], placement: placement)
                    ToolbarItemGroup(placement: Self.navigatorPlacement) {
                        EPUBSearchResultNavigator(controls: controls, showsResultBrowser: false)
                        Button("Search Results", systemImage: "list.bullet.rectangle") { browsing = true }
                            .disabled(!controls.canShowSearchResults)
                    }
                }
                .sheet(isPresented: $browsing) {
                    EPUBSearchResultList(controls: controls) { _ in browsing = false }
                }
        default:
            titled(reader(controls), controls)
                .toolbar {
                    EPUBReaderToolbar(controls: controls, groups: [.search, .contents, .appearance, .readingMode], placement: placement)
                    // `-QualificationHostItems <count>` adds host actions beside the supplied groups.
                    ToolbarItemGroup(placement: placement) {
                        ForEach(0..<defaults.integer(forKey: "QualificationHostItems"), id: \.self) { index in
                            Button("Host Action \(index + 1)", systemImage: "\(index + 1).circle") {}
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
    }

    /// `-QualificationStripGroups pages,contents,appearance,readingMode` gives the strip those
    /// groups in that order, and `-QualificationStripRoom <points>` offers it no more height than
    /// that: a strip without its search field raises no keyboard to be short of room under.
    @ViewBuilder private func strip(_ controls: EPUBReaderControls) -> some View {
        let names = (defaults.string(forKey: "QualificationStripGroups") ?? "").split(separator: ",")
        let groups = names.isEmpty ? EPUBReaderControlGroup.allCases : names.compactMap { EPUBReaderControlGroup(rawValue: String($0)) }
        let room = defaults.double(forKey: "QualificationStripRoom")
        if room > 0 {
            EPUBReaderControlStrip(controls: controls, groups: groups).frame(maxHeight: room)
        } else {
            EPUBReaderControlStrip(controls: controls, groups: groups)
        }
    }

    /// `-QualificationTitle NO` leaves the navigation bar to the toolbar items alone.
    @ViewBuilder private func titled(_ view: some View, _ controls: EPUBReaderControls) -> some View {
        if defaults.object(forKey: "QualificationTitle") == nil || defaults.bool(forKey: "QualificationTitle") {
            view.navigationTitle(controls.publication.metadata.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } else {
            view
        }
    }

    private func reader(_ controls: EPUBReaderControls) -> some View {
        VStack(spacing: 0) {
            EPUBReaderView(session: controls.session)
            Text(Self.summary(controls))
                .font(.caption2).lineLimit(2).dynamicTypeSize(.small).padding(4)
                .accessibilityIdentifier("qualification.status")
                #if os(iOS)
                .onChange(of: Self.summary(controls), initial: true) { TouchTrace.shared.note("status " + $1) }
                #endif
        }
    }

    /// The reader's public state on one line, so each control's effect can be read back.
    private static func summary(_ controls: EPUBReaderControls) -> String {
        guard let status = controls.status else { return "no state" }
        let search = switch status.search {
        case .idle: "search idle"
        case .searching(let query): "searching \(query)"
        case .completed(let query, let found): "searched \(query): \(found ? "matches" : "none")"
        case .failed(let query, let error): "search \(query) failed: \(error.message)"
        }
        return [status.location?.href ?? "no location",
                status.location?.progression.map { String(format: "%.4f", $0) } ?? "-",
                status.location?.page.map { "page \($0.label)" } ?? "no page",
                status.style.flow == .scrolled ? "scrolled" : "paginated",
                "\(Int(status.style.fontSize)) pt",
                "\(status.style.appearance.rawValue) shown \(status.effectiveAppearance.rawValue)",
                search,
                controls.searchResults.map { "\($0.currentIndex.map { String($0 + 1) } ?? "-")/\($0.count)" } ?? "no results",
        ].joined(separator: " | ")
    }

    /// `-QualificationPlacement automatic|leading|bottom`; otherwise the trailing navigation bar.
    private var placement: ToolbarItemPlacement {
        #if os(iOS)
        switch defaults.string(forKey: "QualificationPlacement") {
        case "automatic": .automatic
        case "leading": .topBarLeading
        case "bottom": .bottomBar
        default: .topBarTrailing
        }
        #else
        .automatic
        #endif
    }

    #if os(iOS)
    private static let navigatorPlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let navigatorPlacement = ToolbarItemPlacement.automatic
    #endif
}
