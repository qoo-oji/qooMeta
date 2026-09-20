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
        /// 語 → 語の対応表(ひらがなの数え方 → 数字)。
        case wordPairs
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
        /// 差分で置き換えられる文字列(既定のプリセットの名前、見出し、説明)。
        case string
        /// 著者の区切り(空でない文字列の並び。1 文字とは限らない)。
        case separators
        /// 空でない文字列の並び(その場に書く。省いたときは空)。
        case strings
        case object(Node)
        /// 巻の読み手(並び順が優先順位。差分では ID で指し、`$order` で並べ替える)。
        case readers
        /// 語の規則の並び(`markers`。並び順が優先順位。差分では ID で指し、`$order` で並べ替え、新しい ID で足せる)。
        case markers
        /// 名前を付けた型の並び(`presets`)。差分では名前で指す。同梱に無い名前は、利用者の新しいプリセット。
        case presets
        /// プリセットが入れる既定の欄(`defaults`)。書いた欄だけ。
        case presetDefaults
        /// 型の並び(書いた順が優先順位。差分の `$add` は `at` で先頭か末尾かを選ぶ)。
        /// 1 つの型は文字列か、その型だけの区切り・既定の欄を添えたオブジェクト(`formatEntry`)。
        case formats
    }

    struct Field: Sendable {
        var name: String
        var shape: Shape
        var since = 1
        /// 既定値のファイルでも省けるキー(省いたときの値は、形式の側で決まっている)。
        var optional = false
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
    static func optional(_ name: String, _ shape: Shape) -> Field { Field(name: name, shape: shape, optional: true) }

    // MARK: - シリーズの規則

    static let lists: [String: ListKind] = [
        "ignoredInComparison": .characters, "variantKanji": .pairs, "boundaryCharacters": .characters,
        "trimTrailing": .characters, "keepFollowing": .characters, "brackets": .pairs, "labelIntroducers": .words,
        "editionWords": .words, "sourceWords": .words, "compilationWords": .words,
        "plainWords": .words, "standaloneWords": .words, "volumePrefixes": .words,
        "volumeCounters": .words, "wholeOnlyCounters": .words, "kanjiCounters": .words,
        "kanjiAloneDigits": .words, "volumeFollowers": .characters, "numberWords": .wordPairs,
        "positionFirst": .words,
        "positionMiddle": .words, "positionLast": .words, "sequelWords": .words,
        "notFirstMarkers": .words, "notFirstPrefixes": .words,
    ]

    /// 方針(好みで選ぶ扱い)と、選べる値。最初の値が既定(今の扱い)。
    static let policies: [(name: String, choices: [String])] = [
        ("editions", ["sameWork", "separateBooks", "ignore"]),
        ("sources", ["sameWork", "separateBooks", "ignore"]),
        ("compilations", ["ownSeries", "inMainSeries", "notInSeries"]),
        ("compilationVolume", ["offset", "none", "afterRange"]),
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
        f("markers", .markers),
        f("grouping", .object(Node([
            f("compilation", rule([
                f("singleWhenMainExists", .bool), f("volumeOffset", .int(0...100_000)),
            ], enabled: false)),
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
            // 巻の番号のすぐ後ろに来てよい文字。読み手ごとではなく、番号を読むどの読み手にも同じように効く。
            f("followers", rule([f("characters", .list(.characters))], enabled: false)),
            f("inference", .object(Node([
                f("sharedLeadingKanji", rule([f("minBooks", .int(2...10))])),
                f("firstVolume", rule([f("excludeMarkers", .list(.words)), f("excludePrefixes", .list(.words))], enabled: false)),
            ]))),
        ]))),
    ])

    /// 語の規則(`markers` の 1 件)の扱い。タイトルの中の語を上の規則から順に探し、**上の規則が取った所には下の規則は反応しない**。
    /// - `keep`: そのまま読む(何もしない。下の規則から語を守るための規則で、例外はこれを上に置いて書く)
    /// - `edition`・`source`: 版・発行形態の印(方針 editions・sources が扱いを決める)
    /// - `compilation`: 総集編の語(方針 compilations が置き場所を決める)
    /// - `standalone`: この語のある本は、どのシリーズにも入れない(利用者が一覧で「シリーズに入れない」と直した本と同じ扱い)
    static let markerTreatments = ["keep", "edition", "source", "compilation", "standalone"]

    /// 語の規則 1 件の形(`id` は別に見る)。
    static let markerNode = Node([
        f("treat", .choice(markerTreatments)), f("words", .list(.words)), f("patterns", .patterns),
    ], rule: true, enabled: true)

    /// 同梱の語の規則の ID(例の `covers` と、規則の編集画面が ID で指すのに使う。利用者は別の ID の規則を足せる)。
    static let builtInMarkerIDs = ["plain", "edition", "source", "compilationMark", "standalone"]

    /// 巻の読み手の種類と、そのパラメータ。今は種類ごとに 1 つずつで、ID で指す。
    static let readerTypes: [(id: String, type: String, fields: [Field])] = [
        ("ordinal", "ordinal", []),
        ("number", "number", [f("prefixes", .list(.words)), f("counters", .list(.words)),
                              f("wholeOnlyCounters", .list(.words)), f("mergedSpan", .int(0...10))]),
        ("kanji", "kanjiNumber", [f("prefixes", .list(.words)), f("counters", .list(.words))]),
        // 大字(壱・弐・参)は、前に語も後ろに単位も無くても巻と読める。ふつうの漢数字と分けてあるのは、
        // 「三人の夜」のような題名の言葉と見分けが付くのが大字だけだから。
        ("kanjiAlone", "kanjiAloneNumeral", [Field(name: "digits", shape: .list(.words), since: 4)]),
        // 数を語で書いた巻(「ふたつ」「みっかめ」)。どの語がどの数かは一覧が決める。
        ("wordNumber", "numberWord", [Field(name: "words", shape: .list(.wordPairs), since: 6)]),
        ("greek", "greekLetter", []),
        ("roman", "romanNumeral", []),
        ("position", "positionWord", [f("first", .list(.words)), f("middle", .list(.words)), f("last", .list(.words))]),
        // 本編のナンバリングの後ろに続く本(「アフターエピソード」「後日談」)。数はシリーズの中の文脈で決まる
        // ので、読み手は表記だけを返す(位置の語と同じ作り)。
        ("sequel", "sequel", [Field(name: "words", shape: .list(.words), since: 3)]),
    ]

    // MARK: - ファイル名のフォーマット

    /// filename-formats.json の中身(第 5 版): 既定のプリセットの名前と、名前を付けた型の並び(プリセット)。
    ///
    /// 著者の区切り(`separators`)と既定の欄(`defaults`)は ファイル全体 → プリセット → 型 の 3 か所に同じ綴りで書け、
    /// **内側に書いたものが勝つ**。ファイル全体の `separators` だけは必ず書く(いちばん外側の値が無いと、読み方が決まらない)。
    static let formatStages = Node([f("defaultPreset", .string), f("presets", .presets)])

    /// 型として読まない文字列(`plain`)。プリセットと型の 2 か所に書け、**足し合わさる**(区切りや既定の欄と違い、
    /// 内側が外側を打ち消さない。どの文字列を型として読まないかは、足していくものだから)。
    static let plainNode = Node([optional("words", .strings), optional("patterns", .patterns)])

    /// 同梱のプリセットの名前(綴りの候補を出すのに使う。利用者は差分で別の名前のプリセットを足せる)。
    static let presetNames = ["commercial", "doujinshi", "doujinshi-event"]

    /// 1 つのプリセット。要るのは `formats` だけで、ほかは省ける(省いた区切りは、同梱の既定の `,` `，` `、`)。
    /// **ファイル全体の段は持たない**(2026-09-21、利用者の指示。設定はルールセットごと)。
    static let presetNode = Node([
        optional("label", .string), optional("note", .string), optional("separators", .separators),
        optional("defaults", .presetDefaults), optional("plain", .object(plainNode)),
        optional("ignoreBracketsInsideTitle", .bool), f("formats", .formats),
    ])

    /// 1 つの型をオブジェクトで書いたとき。要るのは `format` だけ。
    static let formatEntryNode = Node([
        f("format", .string), optional("separators", .separators), optional("defaults", .presetDefaults),
        optional("plain", .object(plainNode)),
    ])

    /// 既定を入れられる欄(シリーズと巻は中核が導くので入れられない。タイトルと著者は本ごとに違うので入れない)。
    static let presetDefaultFields = ["genre", "event", "source", "info"]

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
                case .markers: ids += builtInMarkerIDs
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
