import EPUBCore
import EPUBReading
import EPUBText
import Foundation

// snippet:start extraction
func readSectionText(from url: URL) throws -> [EPUBTextSection] {
    let book = try EPUBPublication.open(at: url)
    return try book.spine.indices.map { try book.textSection(at: $0) }
}
// snippet:end extraction
