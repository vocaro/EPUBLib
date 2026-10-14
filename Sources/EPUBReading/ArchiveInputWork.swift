import EPUBCore

/// ZIPFoundation's Apple decoder calls its consumer after each processing step, including
/// those producing no output. A step holds at most one input chunk and produces at most one
/// output chunk. Charge a chunk per call; actual output and one partial final chunk per entry
/// pay for output steps. The archive's own bytes pay for the remaining input steps. This bounds
/// work even when records share a stream, without believing a declared compressed size.
struct ArchiveInputWork {
    static let chunkSize = 32_768
    private var remaining: UInt64

    init(archiveBytes: Int) { remaining = UInt64(archiveBytes) }

    mutating func beginEntry() {
        remaining += UInt64(Self.chunkSize)
    }

    mutating func consume(outputBytes: Int) throws {
        let cost = UInt64(Self.chunkSize - outputBytes)
        guard cost <= remaining else { throw EPUBPublicationError.limitExceeded("archive input work") }
        remaining -= cost
    }
}
