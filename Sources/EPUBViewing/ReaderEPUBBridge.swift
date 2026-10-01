import Foundation



struct ReaderEPUBLocation: Equatable, Sendable {
    let cfi: String?
    let sectionIndex: Int
    let fraction: Double?
    let sectionTitle: String?
}

struct ReaderEPUBSelection: Equatable, Sendable {
    let cfi: String
    let text: String
}

struct ReaderEPUBReadiness: Equatable, Sendable {
    let sectionCount: Int
    let scriptResourcesRefused: Int
    let remoteHintsRemoved: Int
    let lateRemoteHints: Int
}

enum ReaderEPUBMessage: Equatable, Sendable {
    case ready(ReaderEPUBReadiness)
    case relocated(ReaderEPUBLocation)
    case selected(ReaderEPUBSelection)
    case selectionCleared
    case pageNotice(String)
    case failed(reason: String)
}

enum ReaderEPUBDisclosure {
    static func text(for readiness: ReaderEPUBReadiness) -> String? {
        var sentences: [String] = []
        if readiness.scriptResourcesRefused > 0 {
            sentences.append(readiness.scriptResourcesRefused == 1
                ? "One interactive part of this document was not run."
                : "\(readiness.scriptResourcesRefused) interactive parts of this document "
                    + "were not run.")
        }
        if readiness.remoteHintsRemoved > 0 {
            sentences.append(readiness.remoteHintsRemoved == 1
                ? "One connection this document asked for was removed."
                : "\(readiness.remoteHintsRemoved) connections this document asked for "
                    + "were removed.")
        }
        if readiness.lateRemoteHints > 0 {
            sentences.append("This reader may have contacted a server this document named.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

enum ReaderEPUBMessageError: Error, Equatable, CustomStringConvertible, Sendable {
    case notAnObject
    case unknownType(String)
    case missingField(String)
    case wrongType(field: String)
    case outOfBounds(field: String)
    case malformedCFI

    var description: String {
        switch self {
        case .notAnObject: "the reader page sent something that is not a message object"
        case .unknownType(let type): "the reader page sent an unknown message type: \(type)"
        case .missingField(let field): "the reader message has no \(field)"
        case .wrongType(let field): "the reader message's \(field) has the wrong type"
        case .outOfBounds(let field): "the reader message's \(field) is out of bounds"
        case .malformedCFI: "the reader message carries a malformed EPUB CFI"
        }
    }
}


enum ReaderEPUBCFI {
    static let maximumLength = 1_024

    private static func isPermitted(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x2028, 0x2029: return false
        default: return true
        }
    }

    static func isWellFormed(_ cfi: String) -> Bool {
        guard cfi.count <= maximumLength,
              cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"),
              cfi.count > "epubcfi()".count
        else { return false }
        var depth = 0
        var isEscaped = false
        var isClosed = false
        for scalar in cfi.unicodeScalars {
            guard isPermitted(scalar), !isClosed else { return false }
            if isEscaped {
                isEscaped = false
                continue
            }
            switch scalar {
            case "^": isEscaped = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { return false }
                isClosed = depth == 0
            default: break
            }
        }
        return isClosed
    }
}


enum ReaderEPUBMessageDecoder {
    static let maximumSelectionLength = 4_096
    static let maximumTitleLength = 512
    static let maximumFailureReasonLength = 512
    static let maximumSectionCount = 100_000

    static func decode(_ body: Any) throws -> ReaderEPUBMessage {
        guard let object = body as? [String: Any] else { throw ReaderEPUBMessageError.notAnObject }
        let type = try string(object, "type", limit: 64)
        switch type {
        case "ready":
            return .ready(ReaderEPUBReadiness(
                sectionCount: try index(object, "sectionCount"),
                scriptResourcesRefused: try index(object, "scriptResourcesRefused"),
                remoteHintsRemoved: try index(object, "remoteHintsRemoved"),
                lateRemoteHints: try index(object, "lateRemoteHints")))
        case "relocated":
            return .relocated(ReaderEPUBLocation(
                cfi: try optionalCFI(object, "cfi"),
                sectionIndex: try index(object, "sectionIndex"),
                fraction: try optionalFraction(object, "fraction"),
                sectionTitle: try optionalString(object, "sectionTitle",
                                                 limit: maximumTitleLength)))
        case "selected":
            let text = try string(object, "text", limit: maximumSelectionLength)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReaderEPUBMessageError.outOfBounds(field: "text")
            }
            return .selected(ReaderEPUBSelection(cfi: try cfi(object, "cfi"), text: text))
        case "selection-cleared":
            return .selectionCleared
        case "notice":
            return .pageNotice(try string(object, "detail", limit: maximumFailureReasonLength))
        case "failed":
            return .failed(reason: try string(object, "reason", limit: maximumFailureReasonLength))
        default:
            throw ReaderEPUBMessageError.unknownType(type)
        }
    }

    private static func string(
        _ object: [String: Any], _ field: String, limit: Int
    ) throws -> String {
        guard let raw = object[field] else { throw ReaderEPUBMessageError.missingField(field) }
        guard let value = raw as? String else { throw ReaderEPUBMessageError.wrongType(field: field) }
        guard value.count <= limit else { throw ReaderEPUBMessageError.outOfBounds(field: field) }
        return value
    }

    private static func optionalString(
        _ object: [String: Any], _ field: String, limit: Int
    ) throws -> String? {
        guard object[field] != nil, !(object[field] is NSNull) else { return nil }
        return try string(object, field, limit: limit)
    }

    private static func isJavaScriptBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func index(_ object: [String: Any], _ field: String) throws -> Int {
        guard let raw = object[field] else { throw ReaderEPUBMessageError.missingField(field) }
        guard let number = raw as? NSNumber, !isJavaScriptBoolean(number) else {
            throw ReaderEPUBMessageError.wrongType(field: field)
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximumSectionCount),
              value == value.rounded(.towardZero) else {
            throw ReaderEPUBMessageError.outOfBounds(field: field)
        }
        return Int(value)
    }

    private static func optionalFraction(
        _ object: [String: Any], _ field: String
    ) throws -> Double? {
        guard let raw = object[field], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, !isJavaScriptBoolean(number) else {
            throw ReaderEPUBMessageError.wrongType(field: field)
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 1 else {
            throw ReaderEPUBMessageError.outOfBounds(field: field)
        }
        return value
    }

    private static func cfi(_ object: [String: Any], _ field: String) throws -> String {
        let value = try string(object, field, limit: ReaderEPUBCFI.maximumLength)
        guard ReaderEPUBCFI.isWellFormed(value) else { throw ReaderEPUBMessageError.malformedCFI }
        return value
    }

    private static func optionalCFI(_ object: [String: Any], _ field: String) throws -> String? {
        guard let raw = object[field], !(raw is NSNull) else { return nil }
        return try cfi(object, field)
    }
}


enum ReaderEPUBFlow: String, Equatable, Sendable {
    case paginated
    case scrolled
}

enum ReaderEPUBCommand: Equatable, Sendable {
    case navigate(href: String)
    case goTo(cfi: String)
    case select(cfi: String)
    case search(query: String)
    case clearSearch
    case setFlow(ReaderEPUBFlow)
    case locate(quote: String, highlight: Bool)
    case setStyle(css: String)
    case nextPage
    case previousPage

    static let maximumQueryLength = 512
    static let maximumLocateQueryLength = 4_096
    static let maximumStyleLength = 4_096
    static let entryPoint = "window.__studywrightReaderDispatch"

    private var payload: [String: Any] {
        switch self {
        case .navigate(let href): ["command": "navigate", "href": href]
        case .goTo(let cfi): ["command": "goTo", "cfi": cfi]
        case .select(let cfi): ["command": "select", "cfi": cfi]
        case .search(let query): ["command": "search", "query": query]
        case .clearSearch: ["command": "clearSearch"]
        case .locate(let quote, let highlight):
            ["command": "locate", "quote": quote, "highlight": highlight]
        case .setStyle(let css): ["command": "setStyle", "css": css]
        case .setFlow(let flow): ["command": "setFlow", "flow": flow.rawValue]
        case .nextPage: ["command": "nextPage"]
        case .previousPage: ["command": "previousPage"]
        }
    }

    func javaScript() throws -> String {
        switch self {
        case .goTo(let cfi), .select(let cfi):
            guard ReaderEPUBCFI.isWellFormed(cfi) else { throw ReaderEPUBMessageError.malformedCFI }
        case .navigate(let href):
            guard !href.isEmpty, href.count <= 4096 else {
                throw ReaderEPUBMessageError.outOfBounds(field: "href")
            }
        case .search(let query):
            guard !query.isEmpty, query.count <= Self.maximumQueryLength else {
                throw ReaderEPUBMessageError.outOfBounds(field: "query")
            }
        case .locate(let quote, _):
            guard !quote.isEmpty, quote.count <= Self.maximumLocateQueryLength else {
                throw ReaderEPUBMessageError.outOfBounds(field: "quote")
            }
        case .setStyle(let css):
            guard css.count <= Self.maximumStyleLength else {
                throw ReaderEPUBMessageError.outOfBounds(field: "css")
            }
        case .clearSearch, .setFlow, .nextPage, .previousPage:
            break
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReaderEPUBMessageError.wrongType(field: "command")
        }
        return "\(Self.entryPoint)(\(json))"
    }
}

enum ReaderEPUBTypography {
    static let minimumFontSizePoints: Double = 12
    static let maximumFontSizePoints: Double = 96

    static func css(fontSizePoints: Double, isDark: Bool) -> String {
        let size = min(max(fontSizePoints, minimumFontSizePoints), maximumFontSizePoints)
        var css =
            "html,body{font-size:\(formatted(size))px!important;"
                + "color-scheme:\(isDark ? "dark" : "light")}"
        if isDark {
            css += "html,body{background:Canvas!important;color:CanvasText!important}"
            css += "a,a:link,a:visited{color:LinkText!important}"
        }
        return css
    }

    private static func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
