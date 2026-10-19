import Foundation
import libxml2

/// Keeps libxml2's messages about a book off the host's standard error (#392).
///
/// libxml2 2.9 writes a message to standard error unless a handler takes it, and
/// `XML_PARSE_NOERROR` does not reach all of them. A validity error, such as one for a repeated
/// `xml:id`, goes past it to a parse's own handler (`sax.serror`) if it has one. An error in
/// decoding the bytes, and the I/O error that follows it, are raised with no parser at all, so no
/// parse's handler can take them, and the pull reader's push parser writes a decoder failure
/// straight to the generic handler. What no parser takes goes to this thread's handlers, which
/// libxml2 keeps per thread. For the call they take everything and write nowhere; then the
/// thread's own come back, so a host's handlers, and the messages of its own libxml2 calls, are
/// as they were.
package enum LibXML2Messages {
    package static func silenced<T>(_ body: () throws -> T) rethrows -> T {
        let structured = (__xmlStructuredError()?.pointee, __xmlStructuredErrorContext()?.pointee)
        let generic = (__xmlGenericError()?.pointee, __xmlGenericErrorContext()?.pointee)
        xmlSetStructuredErrorFunc(nil) { _, _ in }
        // Named no handler, libxml2's default generic one writes to the context as a FILE.
        xmlSetGenericErrorFunc(sink, nil)
        defer {
            xmlSetStructuredErrorFunc(structured.1, structured.0)
            xmlSetGenericErrorFunc(generic.1, generic.0)
        }
        return try body()
    }

    /// A FILE whose writes go nowhere.
    private nonisolated(unsafe) static let sink = UnsafeMutableRawPointer(funopen(nil, nil, { _, _, count in count }, nil, nil))
}
