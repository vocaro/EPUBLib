import Foundation

/// Inputs for the historical Foliate/WebKit recorder and native regression tests.
enum SearchCollationFixtures {
    struct Fixture: Sendable {
        let locale: String
        let query: String
        let body: String
        var markup: String {
            #"<html xmlns="http://www.w3.org/1999/xhtml" lang="\#(locale)"><body>"# + body + "</body></html>"
        }
    }

    static let fixtures: [Fixture] = {
        let pairs: [(String, String, String)] = [
            ("tr", "i", "I"), ("tr", "i", "İ"), ("tr", "I", "ı"), ("tr", "I", "î"),
            ("tr", "i", "i\u{307}"), ("tr", "ö", "o"), ("tr", "ü", "u"),
            ("tr", "ç", "c"), ("tr", "ş", "s"), ("tr", "ğ", "g"), ("tr", "â", "a"),
            ("sv", "å", "a"), ("sv", "ä", "a"), ("sv", "ö", "o"), ("sv", "å", "Å"),
            ("sv", "å", "a\u{30A}"), ("sv", "ü", "y"), ("sv", "ü", "u"),
            ("sv", "u\u{308}", "Y"), ("sv", "ę", "ä"), ("sv", "æ", "ä"), ("sv", "œ", "ö"),
            ("sv", "cafe", "Café"), ("es", "n", "ñ"), ("es", "ñ", "N\u{303}"),
            ("es", "a", "á"), ("es", "u", "ü"), ("en", "a", "å"), ("en", "o", "ö"),
            ("en", "n", "ñ"), ("en", "и", "й"), ("ru", "и", "й"), ("ru", "й", "Й"),
            ("ru", "й", "и\u{306}"), ("ru", "е", "ё"), ("da", "æ", "ä"), ("da", "y", "ü"),
            ("de", "cafe", "Café"), ("ja", "か", "ガ"), ("ja", "ゝ", "ヾ"),
            ("cs", "d", "ď"), ("hu", "ö", "ő"), ("de-u-co-phonebk", "äö", "æœ"),
            ("en", "a\u{34F}", "æ"), ("en", "café\u{E000}", "CAFE\u{E000}"),
            ("en", "a\u{E000}", "a\u{E001}"), ("sv", "ÅBC", "Ａ\u{30A}ＢＣ"),
            ("en", "ßs", "sß"), ("en", "ßa", "sa"), ("en", "a", "æ"),
            ("en", "a\u{E000}", "a\u{E000}"), ("en", "♥️", "♥"), ("en", "☺", "🙂"),
        ]
        return pairs.map { Fixture(locale: $0.0, query: $0.1, body: "<p>\($0.2)</p>") } + [
            Fixture(locale: "sv", query: "åland cafe", body: "<p>Å<b>land</b>   CAFÉ|aland cafe</p>"),
            Fixture(locale: "es", query: "niño", body: "<p>ni<b>ñ</b>o niño nino</p>"),
            Fixture(locale: "tr", query: "ıı", body: "<p>IıI</p>"),
            Fixture(locale: "sv", query: "åå", body: "<p>ÅåÅ</p>"),
        ]
    }()
}
