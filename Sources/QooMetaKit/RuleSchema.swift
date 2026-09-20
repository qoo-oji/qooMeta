import Foundation

/// 規則ファイル(第 2 版)の形。読み込みの検証と差分の重ね方は、すべてこの表に従う(RuleLoader)。
///
/// 段階の並び(`compare` → `markers` → `grouping` → `naming` → `volume`)と、段階の中の規則は固定。
/// キーの名前が規則の ID を兼ねる(docs/rules-format-design.md「段階と規則」)。規則・パラメータ・一覧を足したら
/// `CompiledRules.engineLevel` を上げ、足したものの `since` にその番号を書く。
enum RuleSchema {
    /// 一覧の中身の種類。
    enum ListKind: String, Sendable {
        /// 1 文字ずつの並び(記号の集合。全角空白やタブを目で確かめられるように配列で持つ)。
        case characters
        /// 語の並び。
        case words
        /// 1 文字 → 1 文字の対応表(異体字、閉じ括弧 → 開き括弧)。
        case pairs
    }

    indirect enum Shape: Sendable {
        case bool
        case int(ClosedRange<Int>)
        case choice([String])
        /// 一覧。`"@list:名前"` で `lists` の一覧を指すか、その場に書く。
        case list(ListKind)
        /// 正規表現の並び(ICU)。
        case patterns
        /// 差分では変えられない文字列(照合の処理との対応など)。
        case fixedString
        case object(Node)
        /// 巻の読み手(並び順が優先順位。差分では ID で指し、`$order` で並べ替える)。
        case readers
        /// 名前を付けた型の並び(`presets`)。差分では名前で指す。
        case presets
        /// 型の並び(書いた順が優先順位。差分の `$add` は `at` で先頭か末尾かを選ぶ)。
        case formats
    }

    struct Field: Sendable {
        var name: String
        var shape: Shape
        var since = 1
    }

    /// オブジェクトの形。`rule` なら規則(`since`・`required` を書ける。`hasEnabled` なら `enabled` も)。
    struct Node: Sendable {
        var fields: [Field]
        var isRule = false
        var hasEnabled = false

        init(_ fields: [Field], rule: Bool = false, enabled: Bool = false) {
            self.fields = fields
            self.isRule = rule
            self.hasEnabled = enabled
        }

        func field(_ name: String) -> Field? { fields.first { $0.name == name } }
    }

    static func rule(_ fields: [Field] = [], enabled: Bool = true) -> Shape {
        .object(Node(fields, rule: true, enabled: enabled))
    }

    static func f(_ name: String, _ shape: Shape) -> Field { Field(name: name, shape: shape) }

    // MARK: - シリーズの規則

    static let lists: [String: ListKind] = [
        "ignoredInComparison": .characters, "variantKanji": .pairs, "boundaryCharacters": .characters,
        "trimTrailing": .characters, "keepFollowing": .characters, "brackets": .pairs, "labelIntroducers": .words,
        "editionWords": .words, "sourceWords": .words, "compilationWords": .words, "volumePrefixes": .words,
        "volumeCounters": .words, "wholeOnlyCounters": .words, "kanjiCounters": .words, "positionFirst": .words,
        "positionMiddle": .words, "positionLast": .words, "notFirstMarkers": .words, "notFirstPrefixes": .words,
    ]

    /// 方針(好みで選ぶ扱い)と、選べる値。最初の値が既定(今の扱い)。
    static let policies: [(name: String, choices: [String])] = [
        ("editions", ["sameWork", "separateBooks", "ignore"]),
        ("sources", ["sameWork", "separateBooks", "ignore"]),
        ("compilations", ["ownSeries", "inMainSeries", "notInSeries"]),
        ("compilationVolume", ["none", "afterRange"]),
        ("magazines", ["perYear", "whole"]),
        ("unnumberedFirst", ["inferFirst", "leaveEmpty"]),
        ("differentRelation", ["split", "keep"]),
        ("differentGenre", ["split", "keep"]),
        ("subtitled", ["attach", "separate"]),
    ]

    /// 規則が名前で指せる辞書(実体は利用側が渡す)。
    static let dictionaries = ["english"]

    /// 段階の並び(固定)。`compilation`・`splitByRelation`・`rejectSameWork`・`firstVolume` が働くかどうかは
    /// `policies` が決めるので、`enabled` を持たない。
    static let seriesStages = Node([
        f("compare", .object(Node([
            f("ignored", .list(.characters)), f("variants", .list(.pairs)), f("boundaries", .list(.characters)),
        ]))),
        f("markers", .object(Node([
            f("edition", rule([f("words", .list(.words)), f("patterns", .patterns)])),
            f("source", rule([f("words", .list(.words)), f("patterns", .patterns)])),
        ]))),
        f("grouping", .object(Node([
            f("compilation", rule([f("words", .list(.words)), f("singleWhenMainExists", .bool)], enabled: false)),
            f("volumeHead", rule()),
            f("sharedPrefix", rule([
                f("minPrefix", .int(1...20)), f("minWholeTitle", .int(1...20)),
                f("conditions", .object(Node([
                    f("reject-hiragana-ending", rule()),
                    f("reject-single-script", rule()),
                    f("reject-common-english", rule([f("dictionary", .choice(dictionaries)), f("unlessVolume", .bool)])),
                ]))),
            ])),
            f("splitByRelation", rule(enabled: false)),
            f("rejectSameWork", rule(enabled: false)),
        ]))),
        f("naming", .object(Node([
            f("includeClosingBrackets", rule([f("pairs", .list(.pairs))])),
            f("includeFollowing", rule([f("characters", .list(.characters))])),
            f("trimTrailing", rule([f("characters", .list(.characters))])),
            f("dropLastWord", rule([f("words", .list(.words))])),
        ]))),
        f("volume", .object(Node([
            f("readers", .readers),
            f("inference", .object(Node([
                f("sharedLeadingKanji", rule([f("minBooks", .int(2...10))])),
                f("firstVolume", rule([f("excludeMarkers", .list(.words)), f("excludePrefixes", .list(.words))], enabled: false)),
            ]))),
        ]))),
    ])

    /// 巻の読み手の種類と、そのパラメータ。今は種類ごとに 1 つずつで、ID で指す。
    static let readerTypes: [(id: String, type: String, fields: [Field])] = [
        ("ordinal", "ordinal", []),
        ("number", "number", [f("prefixes", .list(.words)), f("counters", .list(.words)),
                              f("wholeOnlyCounters", .list(.words)), f("mergedSpan", .int(0...10))]),
        ("kanji", "kanjiNumber", [f("prefixes", .list(.words)), f("counters", .list(.words))]),
        ("greek", "greekLetter", []),
        ("roman", "romanNumeral", []),
        ("position", "positionWord", [f("first", .list(.words)), f("middle", .list(.words)), f("last", .list(.words))]),
    ]

    // MARK: - ファイル名のフォーマット

    /// 予約語(Stackroom 式)→ 照合の処理の予約語と qooMeta の欄。差分で変えられるのは作者の区切りだけ。
    /// filename-formats.json の中身(第 3 版): 著者の区切りと、名前を付けた型の並び(プリセット)。
    static let formatStages = Node([
        f("separators", .list(.characters)), f("defaultPreset", .fixedString), f("presets", .presets),
    ])

    /// 同梱のプリセットの名前(差分では、この名前で並びを変える)。
    static let presetNames = ["mixed", "doujinshi", "commercial"]

    // MARK: - 規則の ID

    /// 規則の ID(例の `covers`、差分の `retiredIDs`・`aliases` で使う)。段階の中の規則と、方針・プロファイル。
    static var ruleIDs: [String] {
        var ids: [String] = []
        func collect(_ node: Node) {
            for field in node.fields {
                switch field.shape {
                case .object(let child):
                    if child.isRule { ids.append(field.name) }
                    collect(child)
                case .readers: ids += readerTypes.map(\.id)
                default: break
                }
            }
        }
        collect(seriesStages)
        collect(formatStages)
        // 比べ方(compare)の項目も、例が確かめる対象として ID に数える。
        return ["ignored", "variants", "boundaries"] + ids + ["doujinshi"] + policies.map(\.name)
    }
}

/// 例の `covers` に書ける規則の ID。
enum KnownRuleIDs {
    static var all: [String] { RuleSchema.ruleIDs }
}
