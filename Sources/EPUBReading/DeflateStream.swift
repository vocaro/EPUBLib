import Foundation
import zlib

/// Inflates a deflated entry's data with zlib, in place of ZIPFoundation.
///
/// ZIPFoundation 0.9.20 inflates with Apple's Compression framework on Apple platforms. For some
/// streams whose block header is damaged, that decoder reads stack memory it has not set: how
/// much it gives, what, and whether it then fails depend on what earlier calls left there, so
/// the same book was refused one way on one open and another way on the next (#583, reported to
/// Apple as FB25250089). zlib refuses those streams outright, and on any stream gives what its
/// bytes alone decide. ZIPFoundation is left to read stored entries, and to refuse other methods.
///
/// The steps are the ones ZIPFoundation's took, which `ArchiveInputWork` charges. Each is one
/// call to zlib's `inflate`, given the rest of the current input chunk and a chunk of room. It
/// returns once that input is used up, the room is full or the stream ends (zlib.h), so each
/// takes at most a chunk and gives at most one, and the consumer is called after each with what
/// it gave.
enum DeflateStream {
    /// ZIPFoundation's names for the same failures, which `open` has given since #74.
    enum Failure: Error {
        /// zlib could not be set up to inflate.
        case invalidStream
        /// The stream is not Deflate, or its bytes end before it does.
        case corruptedData
    }

    /// Inflates the stream that begins `bytes`, reading no further than it ends, and returns the
    /// CRC-32 of what it inflates to.
    static func inflate(_ bytes: UnsafeRawBufferPointer, chunkSize: Int, consumer: (Data) throws -> Void) throws -> UInt32 {
        // A raw stream, with no zlib header or checksum, as ZIP holds it (APPNOTE.TXT 4.4.5).
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.invalidStream
        }
        defer { inflateEnd(&stream) }
        let room = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
        defer { room.deallocate() }
        var checksum = crc32(0, nil, 0)
        var read = 0
        while true {
            if stream.avail_in == 0, read < bytes.count, let base = bytes.baseAddress {
                let count = min(chunkSize, bytes.count - read)
                // zlib reads its input and never writes it.
                stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: read).assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(count)
                read += count
            }
            stream.next_out = room
            stream.avail_out = uInt(chunkSize)
            // A step that can make no progress, its input used up short of the stream's end,
            // gives `Z_BUF_ERROR`; damage gives `Z_DATA_ERROR`.
            let status = zlib.inflate(&stream, Z_NO_FLUSH)
            guard status == Z_OK || status == Z_STREAM_END else { throw Failure.corruptedData }
            let count = chunkSize - Int(stream.avail_out)
            checksum = crc32(checksum, room, uInt(count))
            try consumer(Data(bytes: room, count: count))
            if status == Z_STREAM_END { return UInt32(checksum) }
        }
    }
}
