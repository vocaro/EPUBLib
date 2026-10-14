import Foundation

public extension Fixture {
    /// Directory records with distinct paths which re-read one header or one deflate stream.
    /// The stream has empty stored blocks and a final empty block: input without output.
    static func sharedInputArchive(entries: Int, streamBytes: Int = 0,
                                   longHeader: Bool = false, earlyEnd: Bool = false,
                                   distinctHeaders: Bool = false) throws -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let base = storedArchive(storedEntries(try files()))
        let end = base.count - 22
        let directoryStart = base.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: end + 16, as: UInt32.self))) }
        let baseCount = base.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: end + 10, as: UInt16.self))) }
        precondition(entries > 0 && entries + baseCount <= 20_000)
        precondition(!distinctHeaders || entries * 30 <= 65_535)
        var bytes = Data(base[..<directoryStart])
        var directory = Data(base[directoryStart..<end])
        var stream = Data()
        if earlyEnd {
            stream = Data([3, 0]) + Data(count: streamBytes)
        } else if streamBytes > 0 {
            for _ in 0..<max(0, streamBytes / 5 - 1) { stream += Data([0, 0, 0, 255, 255]) }
            stream += Data([1, 0, 0, 255, 255])
        } else {
            stream = Data([3, 0])
        }
        let firstHeader = bytes.count
        let headerCount = distinctHeaders ? entries : 1
        let nameLength = longHeader ? 65_535 : 0
        for index in 0..<headerCount {
            let extraLength = longHeader ? 65_535 : distinctHeaders ? (headerCount - index - 1) * 30 : 0
            bytes += le(UInt32(0x0403_4b50)) + le(UInt16(20)) + le(UInt16(0x0800)) + le(UInt16(8))
            bytes += le(UInt16(0)) + le(UInt16(0x21)) + le(UInt32(0)) + le(UInt32(stream.count)) + le(UInt32(0))
            bytes += le(UInt16(nameLength)) + le(UInt16(extraLength))
            if longHeader { bytes += Data(repeating: 120, count: nameLength) + Data(count: extraLength) }
        }
        bytes += stream
        for index in 0..<entries {
            let name = Data("extra/\(index).bin".utf8)
            directory += le(UInt32(0x0201_4b50)) + le(UInt16(20)) + le(UInt16(20)) + le(UInt16(0x0800)) + le(UInt16(8))
            directory += le(UInt16(0)) + le(UInt16(0x21)) + le(UInt32(0)) + le(UInt32(stream.count)) + le(UInt32(0))
            directory += le(UInt16(name.count)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
            directory += le(UInt32(0)) + le(UInt32(firstHeader + (distinctHeaders ? index * 30 : 0))) + name
        }
        let start = bytes.count
        bytes += directory
        bytes += le(UInt32(0x0605_4b50)) + le(UInt16(0)) + le(UInt16(0))
        bytes += le(UInt16(baseCount + entries)) + le(UInt16(baseCount + entries))
        bytes += le(UInt32(directory.count)) + le(UInt32(start)) + le(UInt16(0))
        return bytes
    }
}
