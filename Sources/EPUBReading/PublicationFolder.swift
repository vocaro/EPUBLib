import EPUBCore
import Foundation

/// A book unpacked into a folder, as Apple Books keeps one on the Mac and as the type
/// `org.idpf.epub-folder` names it: an OCF abstract container (EPUB 3.3 §4.2) held by the file
/// system, whose files `EPUBPublication.open(at:)` reads as it reads an archive's entries (#680).
///
/// Each file is kept under its path from the folder, its names joined by `/`, and held to what an
/// entry's path is held to (`ResourceReference.isReadablePath`); a name that is not UTF-8 is
/// refused as an entry's name is, with its bytes in the error. The limits are those of an
/// archive's expansion: `resourceBytes` for each file, `expandedBytes` for all of them together,
/// and `entryCount` for its files and the folders inside it together. `archiveBytes`, which
/// limits an archive's own bytes, is not asked. A file is refused by its length before it is read,
/// as a stored entry is by its declared size, and its bytes are held to the limits as they come.
///
/// A symbolic link is refused wherever it stands, as a link entry is in an archive, whatever it
/// points at: a book that names one could otherwise read a file outside its folder. So is anything
/// but a file or a folder, a pipe or a socket, which has no length to take. Every file and folder
/// is opened by its path from the folder with `O_NOFOLLOW_ANY`, which refuses a link in any part
/// of it, so a folder or file the walk listed and that is then replaced by a link is refused too.
/// The folder named by the URL itself may be a link, which the host chose to open. A file the
/// folder holds under two names, a hard link, is read under each; nothing it names leaves the
/// folder. The file system is asked nothing beyond the names and kinds of a folder's entries and
/// each file's length, so no timestamp is read (`ArchiveFile`, #685).
struct PublicationFolder {
    /// The folder's descriptor, which every path is opened from.
    private let root: FileDescriptor

    /// The folder `url` names, or nil when it names no folder that can be opened. Whatever else
    /// it names is opened as a file, which says why it cannot be read.
    init?(_ url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        root = FileDescriptor(descriptor)
    }

    /// Every file the folder holds, by its path, read within `limits`. `onProgress` receives the
    /// bytes read so far, after each chunk.
    func files(limits: EPUBImportLimits, onProgress: (@Sendable (Int) -> Void)?) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var paths = Set<String>()
        var total = 0
        // The folders still to list, the last first, each by its path; "" is the folder itself.
        var pending = [""]
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            var folders: [String] = []
            for (name, kind) in try entries(of: folder, count: &paths, limits: limits) {
                let path = folder.isEmpty ? name : folder + "/" + name
                switch kind {
                case .folder: folders.append(path)
                case .file: files[path] = try read(path, total: &total, limits: limits, onProgress: onProgress)
                }
            }
            pending += folders.reversed()
        }
        return files
    }

    private enum Kind { case file, folder }

    /// The entries of the folder at `path`, by name in the order of their bytes, each a file or a
    /// folder, after adding their paths to `paths` within the entry count. A link, or an entry
    /// that is neither a file nor a folder, is refused.
    private func entries(of path: String, count paths: inout Set<String>, limits: EPUBImportLimits) throws -> [(String, Kind)] {
        let descriptor = try open(path.isEmpty ? "." : path, path: path, flags: O_DIRECTORY)
        // The listing closes the descriptor when it is closed.
        guard let directory = fdopendir(descriptor.descriptor) else { throw Self.error(path) }
        _ = descriptor.take()
        defer { closedir(directory) }
        var listed: [(name: [UInt8], type: Int32)] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.error(path) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            listed.append((name, Int32(entry.pointee.d_type)))
            // A folder of more entries than the limit is refused before it is listed whole.
            guard listed.count <= limits.entryCount - paths.count else { throw EPUBPublicationError.limitExceeded("entry count") }
        }
        var entries: [(String, Kind)] = []
        for (bytes, type) in listed.sorted(by: { $0.name.lexicographicallyPrecedes($1.name) }) {
            try Task.checkCancellation()
            guard let name = String(validating: bytes, as: UTF8.self) else {
                throw EPUBPublicationError.invalidArchive("Entry name not UTF-8: \(path.isEmpty ? "" : path + "/")\(EntryName.escaped(bytes))")
            }
            let entry = path.isEmpty ? name : path + "/" + name
            guard ResourceReference.isReadablePath(entry) else { throw EPUBPublicationError.unsafePath(entry) }
            // Two names a file system holds apart may be one path, as two entries may.
            guard paths.insert(entry).inserted else { throw EPUBPublicationError.invalidArchive("Duplicate path: \(entry)") }
            guard paths.count <= limits.entryCount else { throw EPUBPublicationError.limitExceeded("entry count") }
            switch type {
            case Int32(DT_REG): entries.append((name, .file))
            case Int32(DT_DIR): entries.append((name, .folder))
            // A file system that does not say: a folder if it opens as one.
            case Int32(DT_UNKNOWN): entries.append((name, try isFolder(entry) ? .folder : .file))
            default: throw EPUBPublicationError.unsafePath(entry)
            }
        }
        return entries
    }

    /// Whether the entry at `path`, which its folder's listing does not say the kind of, is a folder.
    private func isFolder(_ path: String) throws -> Bool {
        do { _ = try open(path, path: path, flags: O_DIRECTORY); return true }
        catch let error as POSIXError where error.code == .ENOTDIR { return false }
    }

    /// The bytes of the file at `path`, adding their count to `total` within the limits.
    private func read(_ path: String, total: inout Int, limits: EPUBImportLimits,
                      onProgress: (@Sendable (Int) -> Void)?) throws -> Data {
        // Not blocking: a pipe put in a file's place is refused by its length, not waited on.
        let file = try open(path, path: path, flags: O_NONBLOCK)
        // A pipe or a socket cannot be read at an offset and has no length.
        let length = lseek(file.descriptor, 0, SEEK_END)
        guard length >= 0, lseek(file.descriptor, 0, SEEK_SET) == 0 else { throw EPUBPublicationError.unsafePath(path) }
        guard length <= limits.resourceBytes, length <= limits.expandedBytes - total else {
            throw EPUBPublicationError.limitExceeded(path)
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: ArchiveInputWork.chunkSize)
        while true {
            try Task.checkCancellation()
            let count = chunk.withUnsafeMutableBytes { Darwin.read(file.descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.error(path) }
            if count == 0 { return bytes }
            // A file that grew after its length was taken is held to the limits as it is read.
            guard count <= limits.resourceBytes - bytes.count, count <= limits.expandedBytes - total else {
                throw EPUBPublicationError.limitExceeded(path)
            }
            bytes.append(contentsOf: chunk[..<count])
            total += count
            onProgress?(total)
        }
    }

    /// The entry at `path` from the folder, opened with `flags` and refusing a link in any part of
    /// the path; `name` is the path an error gives.
    private func open(_ relative: String, path name: String, flags: Int32) throws -> FileDescriptor {
        let descriptor = openat(root.descriptor, relative, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | flags)
        guard descriptor >= 0 else {
            // A link refused in the path, which the folder's listing said was not one.
            if errno == ELOOP { throw EPUBPublicationError.unsafePath(name) }
            throw Self.error(name)
        }
        return FileDescriptor(descriptor)
    }

    /// The error that `errno` gives for the entry at `path`.
    private static func error(_ path: String) -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
    }
}

/// An open file descriptor, closed when nothing holds it, unless taken.
private final class FileDescriptor {
    private(set) var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    /// The descriptor, which the caller now closes.
    func take() -> Int32 {
        defer { descriptor = -1 }
        return descriptor
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
