import Foundation

// ファイル名フォーマット(docs/filename-format.md の 1・2・5)。
//
// 書き方はターゲットの 3 アプリ(qooViewer・StackNest・ShelfRow)と同じ: 予約語で欄の位置を書き、予約語以外の文字はそのまま
// 照合し、空白は「0 文字以上の空白」。型の並びを上から照合し、名前全体に一致した最初の型で読む。qooMeta で足すのは、
// 全角と半角の括弧を同じとみなすことと、どの型にも合わなかった名前に最も近い型を示すことだけ。フォルダ名は読まない。
//
// シリーズ名と巻数は、ふつうはタイトルから中核の規則で導く。ただし、名前の中に**はっきり書いてある**とき
// (商業の本の「(12)」「第01巻」)は `@series` `@volume` で読める(2026-09-20、利用者の判断)。読んだ値は、利用者が確定した値と
// 同じ扱いで中核へ渡す。`@volume` は数字だけの値に当たる(全角の数字は半角に畳む)。
// `@series` を書いた型は `@title` を省ける(`@series (@volume) - @author`)。タイトルは、型のその部分に値をはめて組み立てる(「月の庭 (3)」)。

/// 予約語。
public enum FormatWord: String, Sendable, Hashable, CaseIterable, Codable {
    case title, author, genre, event, source, info, series, volume, ignore

    /// 書いたときの綴り(`@title`)。
    public var spelling: String { "@" + rawValue }

    /// 入る欄(`@ignore` は捨てるので nil。同梱の型は `@ignore` を使わず、付記も `@info` として残す)。`@source` は原作(StackNest・ShelfRow の `@relation` にあたる)。
    public var field: BookMetadata.Field? {
        switch self {
        case .title: .title
        case .author: .authors
        case .genre: .genre
        case .event: .event
        case .source: .source
        case .info: .info
        case .series: .series
        case .volume: .volume
        case .ignore: nil
        }
    }

    /// 1 つの型に何度でも書けるか(名義が複数ある著者と、読まない部分だけ)。
    public var repeatable: Bool { self == .author || self == .ignore }
}

extension FormatWord {
    /// 値の形が決まっている欄か。`@volume` は**巻数とみなせる形**だけを受ける。ほかの欄は何でもよい。
    var isVolume: Bool { self == .volume }
}

/// 型の書き方の誤り。
public enum FormatError: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case unknownWord(String)
    case repeated(FormatWord)
    case missingTitle
    case unbalanced(Character)
    /// 欄と欄のあいだに、空白のほかの文字が無い(どこで分けるかが決まらない)。
    case adjacent(FormatWord, FormatWord)

    public var description: String {
        switch self {
        case .empty: "型が空"
        case .unknownWord(let w): "予約語ではない: \(w)"
        case .repeated(let w): "\(w.spelling) は 1 つの型に 1 度だけ書ける"
        case .missingTitle: "@title か @series が要る"
        case .unbalanced(let c): "括弧の対が合わない: \(c)"
        case .adjacent(let a, let b): "\(a.spelling) と \(b.spelling) のあいだに区切りの文字が要る"
        }
    }
}

/// 巻数とみなせるかを決めるもの。**語はコードに書かない**(concept.md の原則 8): 判定は `series-rules.json` の
/// 巻の読み手(`volume.readers` の語の一覧)に任せる ―― 巻数に変換する文字列の設定があるのだから、そこに登録された
/// ものだけを通すべき(2026-09-21、利用者の指摘)。
///
/// 規則を読み込む前(同梱の並びをコードから使うとき)は、誰も決めていないので**すべて断る**。
public struct VolumeTest: Sendable {
    let test: @Sendable (String) -> Bool

    public init(_ test: @escaping @Sendable (String) -> Bool) { self.test = test }

    /// 規則がまだ無いときの値。巻数を読む型には当たらない(黙って何でも通すより、当たらないほうが分かる)。
    public static let none = VolumeTest { _ in false }

    func callAsFunction(_ s: some Sequence<Character>) -> Bool { test(String(s)) }
}

/// 型として読まない文字列(filename-formats.json の `plain`)。名前の中のこの部分は、**型の照合のあいだだけ、ただの文字として扱う**:
/// 括弧であっても型の括弧には当たらず、欄の区切りにもならない。値からは消えない(タイトルの一部として残る)。
///
/// 「月の庭 (2026)」の「(2026)」は年で、原作でも巻数でもない。これを型の側で見分ける手段が無かった(末尾の丸括弧は、
/// 同人誌の並びでは原作、商業誌の並びでは巻数として読まれていた。利用者の指摘 2026-09-20)。
public struct PlainText: Sendable, Hashable {
    public var words: [String]
    /// 正規表現(ICU)。
    public var patterns: [String]
    private let regex: NSRegularExpression?

    public static let none = PlainText()

    public init(words: [String] = [], patterns: [String] = []) {
        self.words = words
        self.patterns = patterns
        let all = words.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            + patterns.filter { !$0.isEmpty }
        regex = all.isEmpty ? nil : try? NSRegularExpression(pattern: all.map { "(?:\($0))" }.joined(separator: "|"))
    }

    public var isEmpty: Bool { regex == nil }

    /// 外側の分に内側の分を足したもの(`plain` は ファイル全体 → プリセット → 型 と**足し合わさる**。打ち消す使い道が無いため)。
    public func adding(_ inner: PlainText) -> PlainText {
        inner.isEmpty ? self : isEmpty ? inner : PlainText(words: words + inner.words.filter { !words.contains($0) },
                                                           patterns: patterns + inner.patterns.filter { !patterns.contains($0) })
    }

    public static func == (a: PlainText, b: PlainText) -> Bool { a.words == b.words && a.patterns == b.patterns }
    public func hash(into hasher: inout Hasher) { hasher.combine(words); hasher.combine(patterns) }

    /// この文字列の**全体**が、型として読まない語そのものか(「(2026)」など)。読み残しを数えるときに使う。
    public func covers(_ text: String) -> Bool {
        guard let regex else { return false }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return (BudgetedRegex.matches(regex, in: text, budget: BudgetedRegex.defaultBudget) ?? [])
            .contains { $0.range == whole }
    }

    /// 名前の中の、型として読まない文字(文字 = Character の番号ごと)。1 つも無ければ nil(ふつうの名前は、ここで終わる)。
    /// 正規表現は利用者が書き足せるので、照合に時間の上限を設ける(越えたら、無いものとして扱う)。
    func mask(_ name: String, _ chars: [Character]) -> [Bool]? {
        guard let regex, let matches = BudgetedRegex.matches(regex, in: name, budget: BudgetedRegex.defaultBudget),
              !matches.isEmpty else { return nil }
        // 正規表現の位置は UTF-16。文字の番号へ直す。
        var starts: [Int] = []
        var offset = 0
        for c in chars { starts.append(offset); offset += c.utf16.count }
        var mask = [Bool](repeating: false, count: chars.count)
        for m in matches where m.range.length > 0 {
            for i in chars.indices where starts[i] >= m.range.location && starts[i] < m.range.location + m.range.length { mask[i] = true }
        }
        return mask
    }
}

/// 1 つの型。
public struct FilenameFormat: Sendable, Hashable {
    enum Token: Sendable, Hashable {
        /// そのまま照合する文字(括弧は半角に畳んだもの)。
        case literal(Character)
        /// 0 文字以上の空白。
        case space
        /// 欄。`excluded` は値に含められない文字(すぐ外側の括弧の対。全角・半角とも)。
        case field(FormatWord, excluded: Set<Character>)
    }

    /// 書いたとおりの型。
    public let text: String
    let tokens: [Token]
    /// この型だけの著者の区切り。nil ならプリセットの区切りで分ける(**書いたら丸ごと置き換える**。足し合わせない)。
    ///
    /// 同じ「×」でも、角括弧の中では 1 つの名義の一部で、` - @author` の形の商業の本では連名の区切り、ということがある。
    /// どの字で分けるかは命名の形ごとに違うので、型ごとに決められるようにする(2026-09-20、利用者の指示)。
    public var separators: [String]?
    /// この型で読んだ本にだけ入れる既定の欄(欄ごとにプリセットの既定より勝つ)。名前から読めた欄は触らない。
    public var defaults: [BookMetadata.Field: [String]]
    /// この型で照合するときにだけ足す「型として読まない文字列」(プリセットの分に足される)。
    public var plain: PlainText

    public init(_ text: String, separators: [String]? = nil,
                defaults: [BookMetadata.Field: [String]] = [:], plain: PlainText = .none) throws(FormatError) {
        self.text = text
        self.separators = separators
        self.defaults = defaults
        self.plain = plain
        tokens = try Self.compile(text)
    }

    /// 全角の括弧を半角に畳む(名前の揺れで、意味は同じ)。全角の数字も畳む(`@volume` が「（１２）」にも当たるように)。
    static func fold(_ c: Character) -> Character {
        switch c {
        case "（": "("
        case "）": ")"
        case "［": "["
        case "］": "]"
        case "０"..."９": Character(UnicodeScalar(c.unicodeScalars.first!.value - 0xFF10 + 0x30)!)
        default: c
        }
    }

    /// 欄の値を、欄ごとの形に畳む(巻数の全角の数字は半角に)。
    static func foldValue(_ word: FormatWord, _ value: String) -> String {
        word.isVolume ? String(value.map(fold)) : value
    }

    static let pairs: [Character: Character] = ["(": ")", "[": "]"]

    static func isSpace(_ c: Character) -> Bool { c.isWhitespace }

    static func compile(_ text: String) throws(FormatError) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var open: [Character] = []
        var seen = Set<FormatWord>()
        var i = 0
        while i < chars.count {
            let c = fold(chars[i])
            if isSpace(c) {
                if tokens.last != .space { tokens.append(.space) }
                i += 1
                continue
            }
            if c == "@" {
                var j = i + 1
                while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
                let spelled = String(chars[i..<j])
                guard let word = FormatWord(rawValue: String(spelled.dropFirst())) else { throw .unknownWord(spelled) }
                if !word.repeatable, !seen.insert(word).inserted { throw .repeated(word) }
                // 前の欄とのあいだに、空白のほかの文字が要る。
                let previous = tokens.last(where: { $0 != .space })
                if case .field(let before, _)? = previous { throw .adjacent(before, word) }
                var excluded = Set<Character>()
                if let o = open.last, let close = pairs[o] {
                    excluded = [o, close]
                    for (full, half) in [("（", "("), ("）", ")"), ("［", "["), ("］", "]")] as [(Character, Character)]
                    where excluded.contains(half) {
                        excluded.insert(full)
                    }
                }
                tokens.append(.field(word, excluded: excluded))
                i = j
                continue
            }
            if pairs[c] != nil {
                open.append(c)
            } else if let o = pairs.first(where: { $0.value == c })?.key {
                guard open.last == o else { throw .unbalanced(chars[i]) }
                open.removeLast()
            }
            tokens.append(.literal(c))
            i += 1
        }
        if let o = open.last { throw .unbalanced(o) }
        if tokens.allSatisfy({ $0 == .space }) { throw .empty }
        // `@series` を書いた型は `@title` を省ける(タイトルは、型のシリーズと巻数の部分に値をはめて組み立てる)。
        if !seen.contains(.title), !seen.contains(.series) { throw .missingTitle }
        return tokens
    }

    /// 型の頭に続く、何にでも当たる部品(欄と空白)の数。ここまでしか進まなかった名前は、この型に近いとは言えない
    /// (`@title` で始まる型は、どんな名前でも頭の欄までは「合う」)。
    var leadingFreeTokens: Int {
        tokens.prefix { if case .literal = $0 { false } else { true } }.count
    }

    /// `@title` の無い型のタイトル: 型の `@series` から `@volume` までの部分(じかに付いた括弧などの文字も含む)に、
    /// 読んだ値をはめたもの。`@series (@volume) - @author` なら「月の庭 (3)」、`@series 第@volume巻` なら「月の庭 第3巻」。
    /// 型に書いた文字をそのまま使う(名前の側の全角の括弧や空白の数ではなく)ので、同じ型で読んだ本は同じ形にそろう。
    func assembledTitle(series: String, volume: String) -> String {
        func isPart(_ token: Token) -> Bool {
            if case .field(let word, _) = token { return word == .series || word == .volume }
            return false
        }
        guard var lower = tokens.firstIndex(where: isPart), var upper = tokens.lastIndex(where: isPart) else { return series }
        // 欄にじかに付いた文字(括弧・「第」「巻」)までを含める。空白やほかの欄で止める。
        while lower > 0, case .literal = tokens[lower - 1] { lower -= 1 }
        while upper + 1 < tokens.count, case .literal = tokens[upper + 1] { upper += 1 }
        var text = ""
        for token in tokens[lower...upper] {
            switch token {
            case .literal(let c): text.append(c)
            case .space: text.append(" ")
            case .field(.series, _): text += series
            case .field(.volume, _): text += volume
            case .field: break
            }
        }
        return TextRules.normalizeDisplay(text)
    }

    /// 照合の結果: 欄ごとの値の位置(名前の中の文字の位置)。
    struct Match {
        var fields: [(word: FormatWord, range: Range<Int>)]
    }

    /// どこまで合ったか(合わなかったとき、最も近い型を選ぶため)。
    struct Progress: Comparable {
        /// 満たした部品の数(型の頭から)。
        var tokens: Int
        /// そこまでに読んだ名前の文字数。
        var characters: Int
        static func < (a: Progress, b: Progress) -> Bool { (a.tokens, a.characters) < (b.tokens, b.characters) }
    }

    /// 名前全体に一致すれば、欄の位置。欄は長く取るほうを先に試す(区切りが何度も現れるときは最後のもので分ける)。
    /// 失敗した (部品, 位置) を覚えるので、名前の長さに対して多項式の時間で終わる(正規表現の後戻りの爆発が無い)。
    ///
    /// `plain` は、型として読まない文字(`PlainText.mask`)。その文字は型の文字(括弧など)には当たらず、欄の値を括弧で
    /// 止めることもない。数字だけの欄(`@volume`)には入らない。
    func match(_ name: [Character], isVolume: VolumeTest = .none, plain: [Bool]? = nil) -> (match: Match?, progress: Progress) {
        let folded = name.map(Self.fold)
        func isPlain(_ p: Int) -> Bool { plain?[p] ?? false }
        var failed = Set<Int>()
        var best = Progress(tokens: 0, characters: 0)
        var fields: [(word: FormatWord, range: Range<Int>)] = []
        let width = folded.count + 1

        func step(_ t: Int, _ p: Int) -> Bool {
            best = max(best, Progress(tokens: t, characters: p))
            if t == tokens.count { return p == folded.count }
            if failed.contains(t * width + p) { return false }
            switch tokens[t] {
            case .literal(let c):
                if p < folded.count, folded[p] == c, !isPlain(p), step(t + 1, p + 1) { return true }
            case .space:
                var end = p
                while end < folded.count, Self.isSpace(folded[end]) { end += 1 }
                for e in stride(from: end, through: p, by: -1) where step(t + 1, e) { return true }
            case .field(let word, let excluded):
                var end = p
                while end < folded.count, isPlain(end) || !excluded.contains(folded[end]) {
                    // 型として読まない文字は、巻数にもしない。
                    if word.isVolume, isPlain(end) { break }
                    end += 1
                }
                for e in stride(from: end, to: p, by: -1) {
                    // 空白だけの値は欄にしない。
                    guard folded[p..<e].contains(where: { !Self.isSpace($0) }) else { continue }
                    // 巻数の欄は、規則の巻の読み手が「巻数だけ」と認めた値でなければ当たらない。
                    if word.isVolume, !isVolume(folded[p..<e]) { continue }
                    fields.append((word, p..<e))
                    if step(t + 1, e) { return true }
                    fields.removeLast()
                }
            }
            failed.insert(t * width + p)
            return false
        }

        return step(0, 0) ? (Match(fields: fields), best) : (nil, best)
    }
}

/// 型の並びと、並びの欄の区切り(1 つのプリセット)。
///
/// 区切りと既定の欄は ファイル全体 → プリセット → 型 の 3 か所に書け、**内側に書いたものが勝つ**
/// (docs/filename-format.md の 4)。ここが持つのは、ファイル全体とプリセットを重ねた後の値。型の分は型が持つ。
public struct FilenameFormats: Sendable, Hashable {
    public static func == (a: FilenameFormats, b: FilenameFormats) -> Bool {
        (a.label, a.note, a.formats, a.separators, a.defaults, a.plain)
            == (b.label, b.note, b.formats, b.separators, b.defaults, b.plain)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(label); hasher.combine(note); hasher.combine(formats)
        hasher.combine(separators); hasher.combine(defaults); hasher.combine(plain)
    }

    /// 画面に出す見出しと説明(無ければプリセットの名前を出す)。
    public var label: String?
    public var note: String?
    public var formats: [FilenameFormat]
    /// 著者の値を分ける文字列(並びの欄は著者だけ)。既定は `,` と `、`(全角のカンマも `,` と同じ)。
    /// `×` `&` `・` は 1 つの名義の中にも現れ、取り違えると著者の先頭(中核の比べる単位)が壊れるので既定に入れない。
    public var separators: [String]
    /// 名前に書かれていない欄に入れる既定の値(プリセットごと)。**名前から読めたときは触らない。**
    ///
    /// 先頭の丸括弧を催しの名前にしている蔵書では、ジャンルがどの名前にも書かれない。そういう蔵書は丸ごと同人誌なので、
    /// プリセットの側でジャンルを決められるようにする(2026-09-20、利用者の判断)。値は JSON が持ち、コードには書かない。
    public var defaults: [BookMetadata.Field: [String]]
    /// 型として読まない文字列(このルールセットの分。型の分は型が持つ)。
    public var plain: PlainText
    /// 巻数とみなせるかの判定(規則の巻の読み手。組み立てのときに渡る)。比べるときは見ない(規則の側で決まるため)。
    public var isVolume: VolumeTest = .none

    public static let defaultSeparators = [",", "，", "、"]

    public init(formats: [FilenameFormat], separators: [String] = Self.defaultSeparators,
                defaults: [BookMetadata.Field: [String]] = [:], label: String? = nil, note: String? = nil,
                plain: PlainText = .none, isVolume: VolumeTest = .none) {
        self.formats = formats
        self.separators = separators
        self.defaults = defaults
        self.plain = plain
        self.isVolume = isVolume
        self.label = label
        self.note = note
    }

    /// 同梱のプリセット(docs/filename-format.md の 5)。**同人誌用と商業誌用に分ける**(2026-09-20、利用者の判断。末尾の丸括弧が
    /// 原作なのは同人誌の慣習で、商業の本では巻数のことが多い)。利用者は使うほうを選び、複製して変える。
    ///
    /// 同人誌用: ターゲットの既定(qooViewer の 12 通り)の `@ignore` の位置へ欄を割り当て(末尾の角括弧は `@info`)、
    /// 末尾が角括弧だけの形を足した 16 通り。タイトル・著者が壊れる型(`@title` だけ、`@title - @author`、
    /// `@title [@author]`)は入れない。
    public static let doujinshiPresetTexts = doujinshiTexts(leading: "(@genre) ")

    /// 同人誌用(頒布会の名前で管理する利用者向け)。**先頭の丸括弧を `@event` として読む**ほかは同じ 16 通り。
    ///
    /// ジャンルの型と催しの型は、先頭の同じ位置を奪い合う(どちらも「(…)」)ので、**1 つの並びには同居できない**
    /// (先に当たったほうで読んでしまう)。どちらで管理しているかは蔵書ごと・フォルダごとに決まっているので、
    /// 並びを分けて本ごとに選べるようにする(2026-09-20、利用者の判断)。
    public static let doujinshiEventPresetTexts = doujinshiTexts(leading: "(@event) ")

    /// 催しの型のプリセットが入れる既定の欄(同梱の規則ファイルにも同じものがある)。
    public static let doujinshiEventDefaults: [BookMetadata.Field: [String]] = [.genre: ["同人誌"]]

    /// 同人誌用の 16 通り。先頭の丸括弧に当てる欄だけが違う(`leading` を空にした 8 通りは、どちらにも入れる)。
    static func doujinshiTexts(leading: String) -> [String] {
        var texts: [String] = []
        for head in [leading, ""] {
            for author in ["[@author (@author)]", "[@author]"] {
                for tail in [" (@source) [@info]", " (@source)", " [@info]", ""] {
                    texts.append("\(head)\(author) @title\(tail)")
                }
            }
        }
        return texts
    }

    /// 商業誌用: 末尾の丸括弧は巻数(数字だけのときに当たる)。原作と、著者の中の丸括弧(同人誌固有)は使わない。
    /// 先頭の丸括弧は、同人誌用と同じくジャンルとして読む(商業の本にもレーベルや分類を書く利用者がいる)。
    public static let commercialPresetTexts: [String] = {
        var texts: [String] = []
        for genre in ["(@genre) ", ""] {
            // 名前が巻数を持つ形では、その手前は**シリーズ名**(`@series`)。`@title` にすると、読んだ巻数と、
            // タイトルから導いた巻数が競合する(2026-09-21、利用者の指摘)。
            texts.append("\(genre)[@author] @series (@volume) [@info]")
            texts.append("\(genre)[@author] @series (@volume)")
            texts.append("\(genre)[@author] @title [@info]")
            texts.append("\(genre)[@author] @title")
        }
        return texts + trailingAuthorTexts
    }()

    /// 著者を末尾に ` - ` で付ける形(「シリーズ名 (12) - 著者」)。丸括弧の前はシリーズ名そのものなので、`@series` で読む
    /// (2026-09-20、利用者の指示)。読んだシリーズと巻数は利用者が確定した値と同じ扱いになり、**タイトルから導く処理を通らない**。
    /// **数字だけの丸括弧のすぐ後ろ**に ` - ` が続くときだけ当たるので、「題名 - 副題」の本の副題を著者に取り違えない
    /// (括弧の無い `@title - @author` は、その取り違えがあるので同梱しない)。
    /// 角括弧で始まる形と両方に当たる名前は、これまでどおり角括弧の形で読むように、並びの末尾に置く。
    static let trailingAuthorTexts = ["@series (@volume) - @author [@info]", "@series (@volume) - @author"]

    public static let doujinshiPreset = FilenameFormats(formats: doujinshiPresetTexts.map { try! FilenameFormat($0) })
    public static let doujinshiEventPreset = FilenameFormats(formats: doujinshiEventPresetTexts.map { try! FilenameFormat($0) },
                                                             defaults: doujinshiEventDefaults)
    public static let commercialPreset = FilenameFormats(formats: commercialPresetTexts.map { try! FilenameFormat($0) })

    /// **読み残し**の位置: タイトルに飲み込まれて、どの欄にもならなかった括弧の組(名前の中の文字の番号)。
    ///
    /// 緩い型(`[@author] @title`)は、末尾の丸括弧ごとタイトルに飲み込んでも「名前全体に合った」ことになる。
    /// だから「型に合った冊数」だけでは、その並びが蔵書に合っているかが分からない(2026-09-21、利用者の指摘。
    /// 同人誌だけのフォルダで、商業誌の並びが 100% と出ていた)。型として読まない語(`plain`)は、残って当たり前なので数えない。
    ///
    /// 見るのは**名前の中のタイトルの部分**で、欄の値ではない。`@title` の無い型(`@series (@volume) - @author`)の
    /// タイトルは型から組み立てたもので、その「(3)」は読み残しではないため。
    public func unreadBrackets(in reading: FormatReading, name: [Character]) -> [Range<Int>] {
        guard let index = reading.formatIndex, formats.indices.contains(index) else { return [] }
        let format = formats[index]
        let groups = reading.spans.filter { $0.word == .title }
            .flatMap { Self.bracketGroups(in: name, within: $0.range) }
        guard let mask = (format.plain.isEmpty ? plain : plain.adding(format.plain)).mask(String(name), name) else { return groups }
        return groups.filter { group in !group.allSatisfy { mask[$0] } }
    }

    /// 名前の中の括弧の組の位置(全角・半角の丸括弧と角括弧。入れ子は外側だけ)。
    static func bracketGroups(in chars: [Character], within range: Range<Int>) -> [Range<Int>] {
        let closing: [Character: Character] = [")": "(", "]": "[", "）": "（", "］": "［"]
        var groups: [Range<Int>] = []
        var open: [(Character, Int)] = []
        for i in range {
            let c = chars[i]
            if "([（［".contains(c) {
                open.append((c, i))
            } else if let want = closing[c], let last = open.last, last.0 == want {
                open.removeLast()
                if open.isEmpty { groups.append(last.1..<(i + 1)) }
            }
        }
        return groups
    }

    /// 名前を読む。合わなければ、名前全体を仮のタイトルにし、最も近い型を添える。
    public func read(_ name: String) -> FormatReading {
        let chars = Array(name)
        var nearest: (index: Int, progress: FilenameFormat.Progress)?
        let mask = plain.mask(name, chars)
        for (index, format) in formats.enumerated() {
            // 型が自分の分を足していれば、その型のときだけ足した形で見る。
            let (match, progress) = format.match(chars, isVolume: isVolume,
                                                 plain: format.plain.isEmpty ? mask : plain.adding(format.plain).mask(name, chars))
            if let match { return reading(chars, match, format: format, formatIndex: index) }
            // どの型も頭の部品から外れた名前(括弧の無い名前など)には、近い型は無いとする(先頭の型を示しても手がかりにならない)。
            if progress.tokens > format.leadingFreeTokens, nearest == nil || nearest!.progress < progress { nearest = (index, progress) }
        }
        let title = TextRules.normalizeDisplay(name)
        var reading = FormatReading(metadata: BookMetadata(title: title), formatIndex: nil,
                                    spans: title.isEmpty ? [] : [FormatReading.Span(word: .title, range: 0..<chars.count)],
                                    nearest: nearest.map { FormatReading.Nearest(formatIndex: $0.index, matchedCharacters: $0.progress.characters) })
        // どの型にも合わなかった名前にも既定の欄は入れる(その蔵書がどういう本かは、型に合ったかどうかで変わらない)。
        applyDefaults(&reading.metadata)
        return reading
    }

    /// 名前から読めなかった欄に、既定を入れる。型の既定が、欄ごとにプリセットの既定より勝つ。
    func applyDefaults(_ metadata: inout BookMetadata, format: FilenameFormat? = nil) {
        let merged = defaults.merging(format?.defaults ?? [:]) { _, inner in inner }
        for (field, values) in merged where metadata.values(field).isEmpty {
            metadata.set(field, to: values)
        }
    }

    func reading(_ chars: [Character], _ match: FilenameFormat.Match, format: FilenameFormat, formatIndex: Int) -> FormatReading {
        var metadata = BookMetadata()
        var spans: [FormatReading.Span] = []
        for (word, range) in match.fields {
            // 値の前後の空白は位置に含めない(色分けで、欄の文字だけを示す)。
            var lower = range.lowerBound, upper = range.upperBound
            while lower < upper, chars[lower].isWhitespace { lower += 1 }
            while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
            spans.append(FormatReading.Span(word: word, range: lower..<upper))
            guard let field = word.field else { continue }
            // 値は表示の形にそろえる(合成済みにし、連なった空白を 1 つにする)。名前の見た目は変えず、欄の値だけ。
            let value = FilenameFormat.foldValue(word, TextRules.normalizeDisplay(String(chars[lower..<upper])))
            if field.isList {
                metadata.set(field, to: metadata.values(field) + split(value, by: format.separators ?? separators))
            } else {
                metadata.set(field, to: [value])
            }
        }
        // `@title` の無い型(`@series (@volume) - @author`)は、型のシリーズと巻数の部分に読んだ値をはめてタイトルにする
        // (「月の庭 (3)」。2026-09-20、利用者の指示)。タイトルは書き出しの題名になるので空にはしない。
        if metadata.title.isEmpty, !metadata.series.isEmpty {
            metadata.set(.title, to: [format.assembledTitle(series: metadata.series, volume: metadata.volume)])
        }
        applyDefaults(&metadata, format: format)
        return FormatReading(metadata: metadata, formatIndex: formatIndex, spans: spans, nearest: nil)
    }

    /// 著者の値を区切りで分ける(前後の空白を除き、空の値は捨てる)。`separators` を省くとプリセットの区切り。
    public func split(_ value: String, by separators: [String]? = nil) -> [String] {
        let separators = separators ?? self.separators
        var parts = [TextRules.normalizeDisplay(value)]
        for separator in separators where !separator.isEmpty {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// 名前 1 つの**読めぐあい**。良いほうから並ぶ(番号の小さいほうが良い)。
public enum FormatOutcome: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
    /// 型に合って、読み残しも無い。
    case read
    /// 型には合ったが、どの欄にもならない括弧がタイトルに残った。
    case leftover
    /// どの型にも合わなかった(名前ぜんぶが仮のタイトル)。
    case unread

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 名前 1 つを読んでみた結果と、**どこが問題か**。
///
/// 型の並びを直すとき、どの名前がまだ読めていないのか、直して何が良くなったのかを見せるために使う
/// (2026-09-21、利用者の指示)。段 2 の指標も同じ判定を使う ―― 画面によって数え方が違うと、比べられなくなる。
public struct FormatCheck: Sendable, Hashable {
    public var outcome: FormatOutcome
    /// 合った型の番号。合わなかったときは、最も近い型(それも無ければ nil)。
    public var formatIndex: Int?
    /// 直すところ(名前の中の文字の番号)。合わなかった名前は**外れた場所から後ろ**、読み残しは残った括弧の組。
    public var problems: [Range<Int>]
    /// 名前のどこがどの欄になったか(合ったときだけ。色分け用)。
    public var spans: [FormatReading.Span]

    public var isRead: Bool { outcome == .read }
}

extension FilenameFormats {
    /// 名前を読んで、読めぐあいと問題の場所まで返す。
    public func check(_ name: String) -> FormatCheck {
        let chars = Array(name)
        let reading = read(name)
        guard reading.formatIndex != nil else {
            // どこで外れたかは、最も近い型がそこまで読めた文字数で分かる(近い型が無ければ、名前ぜんぶが問題)。
            let from = min(reading.nearest?.matchedCharacters ?? 0, max(chars.count - 1, 0))
            return FormatCheck(outcome: .unread, formatIndex: reading.nearest?.formatIndex,
                               problems: chars.isEmpty ? [] : [from..<chars.count], spans: [])
        }
        let leftover = unreadBrackets(in: reading, name: chars)
        return FormatCheck(outcome: leftover.isEmpty ? .read : .leftover, formatIndex: reading.formatIndex,
                           problems: leftover, spans: reading.spans)
    }
}

/// 名前を型で読んだ結果。シリーズと巻は入らない(中核が導く)。
public struct FormatReading: Sendable, Hashable {
    public var metadata: BookMetadata
    /// 一致した型の番号(並びの中、0 から)。nil なら合わなかった(名前全体が仮のタイトル、著者は空)。
    public var formatIndex: Int?
    /// 名前のどこがどの欄か(詳細の色分け)。
    public var spans: [Span]
    /// 合わなかったとき、最も近い型と、その型で頭から何文字まで読めたか(どこで外れたか)。
    public var nearest: Nearest?

    public struct Span: Sendable, Hashable {
        public var word: FormatWord
        /// 名前の中の位置(文字 = Character の番号)。
        public var range: Range<Int>
    }

    public struct Nearest: Sendable, Hashable {
        public var formatIndex: Int
        public var matchedCharacters: Int
    }
}

/// 名前を付けた型の並び(プリセット)。**フォルダごとに使い分けられる**ように、本ごとに名前で選ぶ
/// (2026-09-20、利用者の指示。商業誌と同人誌が混ざったフォルダ構成のため)。
public struct FormatPresets: Sendable, Hashable {
    /// 名前 → 型の並び(同梱は `doujinshi`・`doujinshi-event`・`commercial`)。
    public var presets: [String: FilenameFormats]
    /// 本がプリセットを選ばなかったときに使う名前。
    public var defaultName: String

    public init(presets: [String: FilenameFormats], defaultName: String) {
        self.presets = presets
        self.defaultName = defaultName
    }

    /// 名前で選ぶ(無い名前なら既定、それも無ければ同梱の既定)。
    public subscript(name: String?) -> FilenameFormats {
        presets[name ?? defaultName] ?? presets[defaultName] ?? .commercialPreset
    }

    public var names: [String] { presets.keys.sorted() }

    /// 画面に出す見出し(`label`。書いていなければ名前そのもの)。
    public func title(of name: String) -> String { presets[name]?.label ?? name }

    /// 同梱のプリセット(コードの側の既定。規則ファイルを読む前に使う)。
    public static let bundled = FormatPresets(
        presets: ["doujinshi": .doujinshiPreset, "doujinshi-event": .doujinshiEventPreset,
                  "commercial": .commercialPreset],
        defaultName: "commercial")
}
