import CoreGraphics

/// An operator's form: its position in an `mrow`, or its `form` attribute.
enum OperatorForm: Sendable, Equatable { case prefix, infix, postfix }

struct OperatorFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let stretchy = OperatorFlags(rawValue: 1)
    static let symmetric = OperatorFlags(rawValue: 2)
    static let fence = OperatorFlags(rawValue: 4)
    static let separator = OperatorFlags(rawValue: 8)
    static let largeop = OperatorFlags(rawValue: 16)
    static let movablelimits = OperatorFlags(rawValue: 32)
    static let accent = OperatorFlags(rawValue: 64)
}

/// An operator's resolved spacing and behaviour, after the dictionary and its attributes.
struct OperatorProperties: Sendable {
    var form: OperatorForm
    /// Points.
    var lspace: CGFloat
    var rspace: CGFloat
    var flags: OperatorFlags
    /// Stretches along the inline axis (arrows, over- and underbraces, wide accents).
    var isHorizontal: Bool
    /// A binary operator by the dictionary, which becomes unary where TeX's rule 5 says so.
    var isBinary = false
    /// The dictionary's spacing, in eighteenths of an em, before attributes or script level.
    var dictionarySpacing: (lspace: UInt8, rspace: UInt8) = (0, 0)
    func has(_ flag: OperatorFlags) -> Bool { flags.contains(flag) }
}

/// The operator dictionary: default spacing and properties of common operators by form.
///
/// Spacing follows TeX's classes, which MathML's dictionary also encodes: relations and
/// arrows get a thick space (5/18 em) each side, binary operators a medium one (4/18 em) and
/// lose it as prefixes (unary minus), punctuation a thin space after, large operators a thin
/// space each side, fences none. An operator not listed gets thick spaces, as in MathML Core.
enum OperatorDictionary {
    struct Entry: Sendable, Equatable {
        /// Eighteenths of an em.
        var lspace: UInt8
        var rspace: UInt8
        var flags: OperatorFlags
    }
    static let unknown = Entry(lspace: 5, rspace: 5, flags: [])

    private struct Key: Hashable { let text: String; let form: OperatorForm }

    /// The entry for `text` in `form`; a missing form falls back to infix, postfix, then prefix.
    static func entry(_ text: String, form: OperatorForm) -> Entry {
        if let entry = table[Key(text: text, form: form)] { return entry }
        for other in [OperatorForm.infix, .postfix, .prefix] where other != form {
            if let entry = table[Key(text: text, form: other)] { return entry }
        }
        return unknown
    }

    /// Whether an operator stretches horizontally rather than vertically.
    static func isHorizontal(_ text: String) -> Bool {
        text.unicodeScalars.count == 1 && horizontal.contains(text.unicodeScalars.first!)
    }

    private static let horizontalArrows = "←→↔↚↛↮↜↝↞↠↢↣↤↦↩↪↫↬↭↼↽⇀⇁⇄⇆⇇⇉⇋⇌⇍⇎⇏⇐⇒⇔⇚⇛⟵⟶⟷⟸⟹⟺⟻⟼⟽⟾"
    private static let verticalArrows = "↑↓↕⇑⇓⇕↥↧⇅⇈⇊↾↿⇂⇃"
    private static let horizontalAccents = "‾¯_^ˆ~˜ˇ˘⏞⏟⏜⏝⎴⎵⏠⏡\u{0302}\u{0303}\u{030C}\u{0305}\u{0311}\u{0332}\u{20D6}\u{20D7}\u{20E1}"
    private static let horizontal = Set((horizontalArrows + horizontalAccents).unicodeScalars)

    private static let table: [Key: Entry] = {
        var table: [Key: Entry] = [:]
        func add(_ characters: String, _ form: OperatorForm, _ lspace: UInt8, _ rspace: UInt8, _ flags: OperatorFlags = []) {
            for scalar in characters.unicodeScalars {
                table[Key(text: String(scalar), form: form)] = Entry(lspace: lspace, rspace: rspace, flags: flags)
            }
        }
        func addWords(_ words: [String], _ form: OperatorForm, _ lspace: UInt8, _ rspace: UInt8, _ flags: OperatorFlags = []) {
            for word in words { table[Key(text: word, form: form)] = Entry(lspace: lspace, rspace: rspace, flags: flags) }
        }
        let relations = "=≠<>≤≥≦≧≨≩≪≫≮≯≰≱≈≉≊≋≃≄≅≆≇≡≢≣∼≁≍≎≏≐≑≒≓≔≕≖≗≘≙≚≛≜≝≞≟∝∈∉∊∋∌∍"
            + "⊂⊃⊄⊅⊆⊇⊈⊉⊊⊋⊏⊐⊑⊒≺≻≼≽≾≿⊀⊁⊢⊣⊥⊨⊩⊪⊫⊬⊭∣∤∥∦≬⋈⋍⋐⋑⋘⋙⋚⋛⋞⋟⋠⋡⋢⋣⋤⋥⋦⋧⋨⋩⋪⋫⋬⋭"
            + "∴∵∷∶:⩽⩾⪅⪆⪇⪈⪉⪊⪋⪌⪯⪰⊸⟂≺"
        add(relations, .infix, 5, 5)
        add("↖↗↘↙↰↱↲↳↶↷↺↻", .infix, 5, 5)
        add(horizontalArrows, .infix, 5, 5, .stretchy)
        add(verticalArrows, .infix, 5, 5, .stretchy)
        let binary = "+−±∓×÷·∙∗∘⋅⊕⊖⊗⊘⊙⊚⊛⊝∪∩⊎⊔⊓∧∨∖⋆⋄◇△▽◁▷⊲⊳⊴⊵≀⨯⨿⊞⊟⊠⊡⋋⋌⋎⋏⋒⋓†‡*\\"
        add(binary, .infix, 4, 4)
        add("+−±∓¬∁", .prefix, 0, 0)
        add("∀∃∄∂∇∆√∛∜", .prefix, 0, 0)
        add("/", .infix, 0, 0)
        add("!′″‴⁗‵‶‷'%°", .postfix, 0, 0)
        add(",;", .infix, 0, 3, .separator)
        add("\u{2063}", .infix, 0, 0, .separator)
        add("\u{2061}\u{2062}\u{2064}.…⋯⋮⋰⋱", .infix, 0, 0)
        let fence: OperatorFlags = [.stretchy, .symmetric, .fence]
        add("([{⟨⟦⟪⟬⟮⦃⦅⦇⦉⦋⦍⦏⦑⦓⦕⦗⌈⌊〈❲⁅", .prefix, 0, 0, fence)
        add(")]}⟩⟧⟫⟭⟯⦄⦆⦈⦊⦌⦎⦐⦒⦔⦖⦘⌉⌋〉❳⁆", .postfix, 0, 0, fence)
        for form in [OperatorForm.prefix, .infix, .postfix] { add("|‖⦀¦⦙", form, 0, 0, fence) }
        add("∑∏∐⋀⋁⋂⋃⨀⨁⨂⨃⨄⨅⨆⨉⫿⅀", .prefix, 3, 3, [.largeop, .movablelimits, .symmetric])
        add("∫∬∭∮∯∰∱∲∳⨋⨌⨍⨎⨏⨐⨑⨒⨓⨔⨕⨖⨗⨘⨙⨚⨛⨜", .prefix, 3, 3, [.largeop, .symmetric])
        addWords(["lim", "max", "min", "sup", "inf", "liminf", "limsup", "lim inf", "lim sup", "det", "gcd", "Pr",
                  "inj lim", "proj lim"], .prefix, 0, 3, .movablelimits)
        add(horizontalAccents, .postfix, 0, 0, [.accent, .stretchy])
        add("˙¨´`˚¸˝\u{0300}\u{0301}\u{0304}\u{0306}\u{0307}\u{0308}\u{030A}\u{030B}\u{20DB}\u{20DC}", .postfix, 0, 0, .accent)
        return table
    }()
}
