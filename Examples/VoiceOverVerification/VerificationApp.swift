import SwiftUI

/// Isolates the synthetic book and preferences from the normal reader sample.
@main struct VoiceOverVerificationApp: App {
    init() {
        // `-VerificationBook paragraphs` opens the book of ordinary paragraphs instead.
        let name = UserDefaults.standard.string(forKey: "VerificationBook") ?? "sample"
        if let book = Bundle.main.url(forResource: name, withExtension: "epub") {
            UserDefaults.standard.register(defaults: ["SampleBook": book.path, "SampleFlow": "paginated"])
        }
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            // `-VerificationPlainText YES` shows AppKit's own text view in the reader's place,
            // and `-VerificationPlainText TextKit1` one laid out by TextKit 1.
            if let kind = UserDefaults.standard.string(forKey: "VerificationPlainText") {
                PlainTextReference(textKit2: kind != "TextKit1").frame(minWidth: 360, minHeight: 600)
            } else {
                NavigationStack { ReaderScreen() }.frame(minWidth: 360, minHeight: 600)
            }
            #else
            if UserDefaults.standard.bool(forKey: "VerificationActivationCheck") {
                ActivationReference()
            } else {
                NavigationStack { ReaderScreen() }
            }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 850)
        #endif
    }
}

#if os(iOS)
/// An independent activation canary: neither a coordinate tap elsewhere nor a duplicate
/// activation can produce the expected count. It is never shown in reader recordings.
private struct ActivationReference: View {
    @State private var count = 0
    var body: some View {
        VStack {
            Button("Activation check \(count)") { count += 1 }
                .accessibilityIdentifier("activation.check")
            Text("Other item")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

#if os(macOS)
/// AppKit's own text view holding a link of words and a link that is a picture, with none of
/// the reader's code: what VoiceOver says and does here is AppKit's and VoiceOver's doing, to
/// compare the reader with. Following a link writes its name at the start of the text, which
/// changes the text's accessibility value.
struct PlainTextReference: NSViewRepresentable {
    /// The reader's views are TextKit 2 views. TextKit 1 is what AppKit's text views were.
    var textKit2 = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        // Asking a text view for its layout manager takes it to TextKit 1 for good.
        if !textKit2 { _ = view.layoutManager }
        let font = NSFont.systemFont(ofSize: 17)
        let text = NSMutableAttributedString(string: "Reference opening words. Before the reference link after it.\nPicture link: ",
                                             attributes: [.font: font])
        text.addAttribute(.link, value: URL(string: "reference:words")!, range: (text.string as NSString).range(of: "reference link"))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let picture = NSMutableAttributedString(attachment: attachment)
        picture.addAttributes([.link: URL(string: "reference:picture")!, .font: font], range: NSRange(location: 0, length: 1))
        text.append(picture)
        text.append(NSAttributedString(string: " closing words.\nReference last words.", attributes: [.font: font]))
        view.isEditable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let name = (link as? URL)?.absoluteString ?? "\(link)"
            let font = NSFont.systemFont(ofSize: 17)
            textView.textStorage?.insert(NSAttributedString(string: "Followed \(name). ", attributes: [.font: font]), at: 0)
            NSAccessibility.post(element: textView, notification: .valueChanged)
            return true
        }
    }
}
#endif
