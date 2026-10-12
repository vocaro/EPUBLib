import Foundation
import ZIPFoundation

public extension Fixture {
    /// The plain two-chapter book with its package, navigation, NCX and container documents each
    /// passed through an edit, then `adding` laid over the files (a nil value removes one).
    static func packageVariant(epub2: Bool = false, opf: (String) -> String = { $0 }, nav: (String) -> String = { $0 },
                               ncx: (String) -> String = { $0 }, container: (String) -> String = { $0 },
                               adding: [String: Data?] = [:]) throws -> Data {
        try archive(packageVariantFiles(epub2: epub2, opf: opf, nav: nav, ncx: ncx, container: container, adding: adding))
    }

    /// The files of `packageVariant`, for a test that packs them itself.
    static func packageVariantFiles(epub2: Bool = false, opf: (String) -> String = { $0 }, nav: (String) -> String = { $0 },
                                    ncx: (String) -> String = { $0 }, container: (String) -> String = { $0 },
                                    adding: [String: Data?] = [:]) throws -> [String: Data] {
        var result = try Self.files(epub2: epub2)
        func edit(_ path: String, _ change: (String) -> String) {
            result[path] = Data(change(String(decoding: result[path]!, as: UTF8.self)).utf8)
        }
        edit("OPS/book.opf", opf)
        edit("OPS/nav.xhtml", nav)
        edit("OPS/toc.ncx", ncx)
        edit("META-INF/container.xml", container)
        for (path, data) in adding { result[path] = data }
        return result
    }

    /// One scalar of each kind that `String` takes into the `Character` of a "/", "\", ":", "#" or
    /// "." written before it, so that by `Character` the separator or dot is not there: a
    /// combining accent and overlay, an enclosing mark, a variation selector of either block, the
    /// zero-width non-joiner and joiner, an emoji modifier, an Indic vowel sign and virama, a
    /// kana voicing mark and a tag.
    static let clusteringMarks = ["\u{301}", "\u{338}", "\u{20E3}", "\u{FE0F}", "\u{E0100}", "\u{200C}", "\u{200D}", "\u{1F3FB}", "\u{93E}",
                                  "\u{94D}", "\u{3099}", "\u{E0020}"]

    /// `text` with each byte outside ASCII percent-encoded, as a resolved reference writes it.
    static func escapingNonASCII(_ text: String) -> String {
        text.utf8.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// A navigation document holding `body` between the XHTML and OPS namespace declarations.
    static func navigationDocument(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
            + "<head><title>Contents</title></head><body>\(body)</body></html>"
    }

    /// One entry of `storedArchive`: its name's bytes and header fields exactly as given, its data
    /// stored without compression whatever `method` claims.
    struct StoredEntry {
        public var name: Data
        public var data: Data
        /// General purpose flags: bit 11 declares a UTF-8 name, bit 3 moves the CRC and sizes into
        /// a data descriptor after the data.
        public var flags: UInt16
        public var method: UInt16
        /// The upper byte names the system whose `externalAttributes` these are (3: Unix).
        public var versionMadeBy: UInt16
        public var externalAttributes: UInt32
        public init(_ name: String, _ data: Data = Data(), flags: UInt16 = 0x0800, method: UInt16 = 0,
                    versionMadeBy: UInt16 = 20, externalAttributes: UInt32 = 0) {
            self.name = Data(name.utf8); self.data = data; self.flags = flags; self.method = method
            self.versionMadeBy = versionMadeBy; self.externalAttributes = externalAttributes
        }
        public init(_ name: String, _ text: String, flags: UInt16 = 0x0800) {
            self.init(name, Data(text.utf8), flags: flags)
        }
    }

    /// How much of a `storedArchive` moves into ZIP64 structures, however small the book.
    enum ZIP64Layout {
        /// Each entry's sizes sit in a ZIP64 extra field, in its local header and in the directory.
        case sizes
        /// As `sizes`, and each entry's header offset too, behind a ZIP64 end-of-directory record
        /// and locator: what a writer told always to use ZIP64 produces.
        case everything
    }

    /// A ZIP written byte by byte in the order given, for layouts ZIPFoundation's writer never
    /// produces for a small book: names without the UTF-8 flag, data descriptors, directory
    /// records, other methods and ZIP64 fields (not together with a data descriptor).
    static func storedArchive(_ entries: [StoredEntry], comment: Data = Data(), zip64: ZIP64Layout? = nil) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let version = UInt16(zip64 == nil ? 20 : 45)
        let wideOffsets = zip64 == .everything
        var bytes = Data()
        var directory = Data()
        for entry in entries {
            let crc: UInt32 = entry.data.crc32(checksum: 0)
            let size = UInt32(entry.data.count)
            let described = entry.flags & 0x0008 != 0
            let offset = UInt32(bytes.count)
            let shortSize = zip64 == nil ? size : UInt32.max
            // Uncompressed then compressed size and, in the directory, the local header's offset.
            let sizes = zip64 == nil ? Data() : le(UInt64(size)) + le(UInt64(size))
            let localExtra = zip64 == nil ? Data() : le(UInt16(1)) + le(UInt16(16)) + sizes
            let directoryExtra = zip64 == nil ? Data() : le(UInt16(1)) + le(UInt16(wideOffsets ? 24 : 16)) + sizes + (wideOffsets ? le(UInt64(offset)) : Data())
            bytes += le(UInt32(0x0403_4b50)) + le(version) + le(entry.flags) + le(entry.method) + le(UInt16(0)) + le(UInt16(0x21))
            bytes += le(described ? 0 : crc) + le(described ? 0 : shortSize) + le(described ? 0 : shortSize)
            bytes += le(UInt16(entry.name.count)) + le(UInt16(localExtra.count)) + entry.name + localExtra + entry.data
            if described { bytes += le(UInt32(0x0807_4b50)) + le(crc) + le(size) + le(size) }
            directory += le(UInt32(0x0201_4b50)) + le(entry.versionMadeBy) + le(version) + le(entry.flags) + le(entry.method)
            directory += le(UInt16(0)) + le(UInt16(0x21)) + le(crc) + le(shortSize) + le(shortSize) + le(UInt16(entry.name.count))
            directory += le(UInt16(directoryExtra.count)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(entry.externalAttributes)
            directory += le(wideOffsets ? UInt32.max : offset) + entry.name + directoryExtra
        }
        let start = bytes.count
        bytes += directory
        if wideOffsets {
            let record = bytes.count
            bytes += le(UInt32(0x0606_4b50)) + le(UInt64(44)) + le(version) + le(version) + le(UInt32(0)) + le(UInt32(0))
            bytes += le(UInt64(entries.count)) + le(UInt64(entries.count)) + le(UInt64(directory.count)) + le(UInt64(start))
            bytes += le(UInt32(0x0706_4b50)) + le(UInt32(0)) + le(UInt64(record)) + le(UInt32(1))
        }
        bytes += le(UInt32(0x0605_4b50)) + le(UInt16(0)) + le(UInt16(0))
        bytes += le(wideOffsets ? UInt16.max : UInt16(entries.count)) + le(wideOffsets ? UInt16.max : UInt16(entries.count))
        bytes += le(wideOffsets ? UInt32.max : UInt32(directory.count)) + le(wideOffsets ? UInt32.max : UInt32(start))
        bytes += le(UInt16(comment.count)) + comment
        return bytes
    }

    /// `files` as stored entries, `mimetype` first and the rest in name order.
    static func storedEntries(_ files: [String: Data], flags: UInt16 = 0x0800) -> [StoredEntry] {
        files.keys.sorted { a, b in a == "mimetype" || (b != "mimetype" && a < b) }
            .map { StoredEntry($0, files[$0]!, flags: flags) }
    }

    /// The offset of the first byte of `name`'s data in an archive ZIPFoundation wrote.
    static func dataOffset(of name: String, in archive: Data) -> Int? {
        var search = archive.startIndex
        while let header = archive.range(of: Data([0x50, 0x4b, 0x03, 0x04]), in: search..<archive.endIndex) {
            let base = header.lowerBound
            guard base + 30 <= archive.endIndex else { return nil }
            let nameLength = Int(archive[base + 26]) | Int(archive[base + 27]) << 8
            let extraLength = Int(archive[base + 28]) | Int(archive[base + 29]) << 8
            guard base + 30 + nameLength <= archive.endIndex else { return nil }
            if archive[(base + 30)..<(base + 30 + nameLength)] == Data(name.utf8) { return base + 30 + nameLength + extraLength }
            search = header.upperBound
        }
        return nil
    }

    /// The offset of `name`'s central directory record in an archive.
    static func directoryOffset(of name: String, in archive: Data) -> Int? {
        var search = archive.startIndex
        while let header = archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]), in: search..<archive.endIndex) {
            let base = header.lowerBound
            guard base + 46 <= archive.endIndex else { return nil }
            let nameLength = Int(archive[base + 28]) | Int(archive[base + 29]) << 8
            guard base + 46 + nameLength <= archive.endIndex else { return nil }
            if archive[(base + 46)..<(base + 46 + nameLength)] == Data(name.utf8) { return base }
            search = header.upperBound
        }
        return nil
    }
}
