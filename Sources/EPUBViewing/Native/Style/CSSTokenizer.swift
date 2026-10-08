import Foundation

/// A token of CSS Syntax Level 3 (§4). Comments are dropped while tokenizing.
enum CSSToken: Equatable, Sendable {
    case ident(String)
    case function(String)
    case atKeyword(String)
    case hash(String, isID: Bool)
    case string(String)
    case badString
    case url(String)
    case badURL
    case delim(Unicode.Scalar)
    /// `signed` records an explicit `+` or `-`, which the An+B microsyntax distinguishes.
    case number(Double, isInteger: Bool, signed: Bool)
    case percentage(Double)
    case dimension(Double, unit: String, isInteger: Bool, signed: Bool)
    case whitespace
    case cdo, cdc, colon, semicolon, comma
    case openSquare, closeSquare, openParen, closeParen, openCurly, closeCurly
}

/// Tokenizes CSS text on demand, following the CSS Syntax tokenizer: escapes, strings,
/// `url()`, numbers and dimensions, comments and error recovery (bad strings and URLs).
struct CSSTokenizer {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        // Preprocessing (§3.3): CR, CRLF and FF become LF; NUL becomes U+FFFD.
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.utf8.count)
        var previousCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D: scalars.append("\n"); previousCR = true; continue
            case 0x0A: if !previousCR { scalars.append("\n") }
            case 0x0C: scalars.append("\n")
            case 0: scalars.append("\u{FFFD}")
            default: scalars.append(scalar)
            }
            previousCR = false
        }
        self.scalars = scalars
    }

    /// All remaining tokens.
    mutating func tokens() -> [CSSToken] {
        var tokens: [CSSToken] = []
        while let token = next() { tokens.append(token) }
        return tokens
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    /// The next token, or nil at the end of input.
    mutating func next() -> CSSToken? {
        skipComments()
        guard let c = peek() else { return nil }
        index += 1
        switch c {
        case "\n", "\t", " ":
            while let next = peek(), Self.isWhitespace(next) { index += 1 }
            return .whitespace
        case "\"", "'": return consumeString(ending: c)
        case "#":
            if let next = peek(), Self.isNameCharacter(next) || Self.isValidEscape(next, peek(1)) {
                let isID = startsIdentifier(at: index)
                return .hash(consumeName(), isID: isID)
            }
            return .delim(c)
        case "(": return .openParen
        case ")": return .closeParen
        case "[": return .openSquare
        case "]": return .closeSquare
        case "{": return .openCurly
        case "}": return .closeCurly
        case ",": return .comma
        case ":": return .colon
        case ";": return .semicolon
        case "+":
            if startsNumber(at: index - 1) { index -= 1; return consumeNumeric() }
            return .delim(c)
        case "-":
            if startsNumber(at: index - 1) { index -= 1; return consumeNumeric() }
            if peek() == "-", peek(1) == ">" { index += 2; return .cdc }
            if startsIdentifier(at: index - 1) { index -= 1; return consumeIdentLike() }
            return .delim(c)
        case ".":
            if startsNumber(at: index - 1) { index -= 1; return consumeNumeric() }
            return .delim(c)
        case "<":
            if peek() == "!", peek(1) == "-", peek(2) == "-" { index += 3; return .cdo }
            return .delim(c)
        case "@":
            if startsIdentifier(at: index) { return .atKeyword(consumeName()) }
            return .delim(c)
        case "\\":
            if Self.isValidEscape(c, peek()) { index -= 1; return consumeIdentLike() }
            return .delim(c)
        default:
            if Self.isDigit(c) { index -= 1; return consumeNumeric() }
            if Self.isNameStart(c) { index -= 1; return consumeIdentLike() }
            return .delim(c)
        }
    }

    private mutating func skipComments() {
        while peek() == "/", peek(1) == "*" {
            index += 2
            while index < scalars.count, !(scalars[index] == "*" && peek(1) == "/") { index += 1 }
            index = min(scalars.count, index + 2)
        }
    }

    private mutating func consumeString(ending: Unicode.Scalar) -> CSSToken {
        var value = String.UnicodeScalarView()
        while let c = peek() {
            index += 1
            if c == ending { return .string(String(value)) }
            if c == "\n" { index -= 1; return .badString }
            if c == "\\" {
                guard let next = peek() else { continue }
                if next == "\n" { index += 1; continue }
                value.append(consumeEscape())
                continue
            }
            value.append(c)
        }
        return .string(String(value))
    }

    private mutating func consumeNumeric() -> CSSToken {
        let (value, isInteger, signed) = consumeNumber()
        if startsIdentifier(at: index) {
            return .dimension(value, unit: consumeName(), isInteger: isInteger, signed: signed)
        }
        if peek() == "%" { index += 1; return .percentage(value) }
        return .number(value, isInteger: isInteger, signed: signed)
    }

    private mutating func consumeNumber() -> (Double, Bool, Bool) {
        var repr = String.UnicodeScalarView()
        var isInteger = true
        var signed = false
        if let c = peek(), c == "+" || c == "-" { repr.append(c); index += 1; signed = true }
        while let c = peek(), Self.isDigit(c) { repr.append(c); index += 1 }
        if peek() == ".", let next = peek(1), Self.isDigit(next) {
            repr.append("."); index += 1; isInteger = false
            while let c = peek(), Self.isDigit(c) { repr.append(c); index += 1 }
        }
        if let e = peek(), e == "e" || e == "E" {
            var exponent = false
            if let next = peek(1), Self.isDigit(next) {
                repr.append("e"); index += 1; exponent = true
            } else if let sign = peek(1), sign == "+" || sign == "-", let digit = peek(2), Self.isDigit(digit) {
                repr.append("e"); repr.append(sign); index += 2; exponent = true
            }
            if exponent {
                isInteger = false
                while let c = peek(), Self.isDigit(c) { repr.append(c); index += 1 }
            }
        }
        let value = Double(String(repr)) ?? 0
        return (value.isFinite ? value : 0, isInteger, signed)
    }

    private mutating func consumeIdentLike() -> CSSToken {
        let name = consumeName()
        guard peek() == "(" else { return .ident(name) }
        index += 1
        guard name.lowercased() == "url" else { return .function(name) }
        while let c = peek(), let next = peek(1), Self.isWhitespace(c), Self.isWhitespace(next) { index += 1 }
        func isQuote(_ c: Unicode.Scalar?) -> Bool { c == "\"" || c == "'" }
        if isQuote(peek()) || (peek().map(Self.isWhitespace) == true && isQuote(peek(1))) { return .function(name) }
        return consumeURL()
    }

    private mutating func consumeURL() -> CSSToken {
        var value = String.UnicodeScalarView()
        while let c = peek(), Self.isWhitespace(c) { index += 1 }
        while let c = peek() {
            index += 1
            switch c {
            case ")": return .url(String(value))
            case "\n", "\t", " ":
                while let next = peek(), Self.isWhitespace(next) { index += 1 }
                if peek() == nil { return .url(String(value)) }
                if peek() == ")" { index += 1; return .url(String(value)) }
                consumeBadURLRemnants(); return .badURL
            case "\"", "'", "(":
                consumeBadURLRemnants(); return .badURL
            case "\\":
                guard Self.isValidEscape(c, peek()) else { consumeBadURLRemnants(); return .badURL }
                value.append(consumeEscape())
            default:
                if Self.isNonPrintable(c) { consumeBadURLRemnants(); return .badURL }
                value.append(c)
            }
        }
        return .url(String(value))
    }

    private mutating func consumeBadURLRemnants() {
        while let c = peek() {
            index += 1
            if c == ")" { return }
            if Self.isValidEscape(c, peek()) { _ = consumeEscape() }
        }
    }

    /// Consumes an escape whose backslash has already been consumed.
    private mutating func consumeEscape() -> Unicode.Scalar {
        guard let c = peek() else { return "\u{FFFD}" }
        index += 1
        guard let first = Self.hexValue(c) else { return c }
        var value = first
        var count = 1
        while count < 6, let next = peek(), let digit = Self.hexValue(next) {
            value = value * 16 + digit
            index += 1; count += 1
        }
        if let next = peek(), Self.isWhitespace(next) { index += 1 }
        guard value != 0, !(0xD800...0xDFFF).contains(value), let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return scalar
    }

    private mutating func consumeName() -> String {
        var value = String.UnicodeScalarView()
        while let c = peek() {
            if Self.isNameCharacter(c) { value.append(c); index += 1 }
            else if Self.isValidEscape(c, peek(1)) { index += 1; value.append(consumeEscape()) }
            else { break }
        }
        return String(value)
    }

    private func scalar(at position: Int) -> Unicode.Scalar? {
        position < scalars.count ? scalars[position] : nil
    }

    private func startsIdentifier(at position: Int) -> Bool {
        guard let first = scalar(at: position) else { return false }
        let second = scalar(at: position + 1)
        if first == "-" {
            guard let second else { return false }
            return Self.isNameStart(second) || second == "-" || Self.isValidEscape(second, scalar(at: position + 2))
        }
        return Self.isNameStart(first) || Self.isValidEscape(first, second)
    }

    private func startsNumber(at position: Int) -> Bool {
        guard let first = scalar(at: position) else { return false }
        let second = scalar(at: position + 1)
        if first == "+" || first == "-" {
            if let second, Self.isDigit(second) { return true }
            return second == "." && scalar(at: position + 2).map(Self.isDigit) == true
        }
        if first == "." { return second.map(Self.isDigit) ?? false }
        return Self.isDigit(first)
    }

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: c.value - 0x30
        case 0x41...0x46: c.value - 0x41 + 10
        case 0x61...0x66: c.value - 0x61 + 10
        default: nil
        }
    }
    static func isNameStart(_ c: Unicode.Scalar) -> Bool {
        (c.value | 0x20 >= 0x61 && c.value | 0x20 <= 0x7A) || c == "_" || c.value >= 0x80
    }
    static func isNameCharacter(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || isDigit(c) || c == "-" }
    static func isValidEscape(_ first: Unicode.Scalar, _ second: Unicode.Scalar?) -> Bool {
        first == "\\" && second != nil && second != "\n"
    }
    static func isNonPrintable(_ c: Unicode.Scalar) -> Bool {
        c.value <= 0x08 || c.value == 0x0B || (c.value >= 0x0E && c.value <= 0x1F) || c.value == 0x7F
    }
}
