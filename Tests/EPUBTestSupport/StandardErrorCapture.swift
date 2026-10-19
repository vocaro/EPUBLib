import Foundation
import libxml2

/// What the process writes to standard error while a call runs. File descriptor 2 is pointed at
/// a file for the call, so what C code writes there, as libxml2 does with `fprintf(stderr, …)`,
/// is caught. For the call this thread has libxml2's default handlers, as a host that sets none
/// has them, so that a handler another test left set cannot take a message first (#392).
public enum StandardErrorCapture {
    public static func capture<T>(_ body: () throws -> T) throws -> (value: T, output: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "stderr-\(UUID().uuidString)")
        let file = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(file); unlink(url.path) }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let structured = (__xmlStructuredError()?.pointee, __xmlStructuredErrorContext()?.pointee)
        let generic = (__xmlGenericError()?.pointee, __xmlGenericErrorContext()?.pointee)
        xmlSetStructuredErrorFunc(nil, nil)
        xmlSetGenericErrorFunc(nil, nil)
        fflush(nil)
        dup2(file, STDERR_FILENO)
        let result = Result(catching: body)
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        close(saved)
        xmlSetStructuredErrorFunc(structured.1, structured.0)
        xmlSetGenericErrorFunc(generic.1, generic.0)
        return (try result.get(), String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }
}
