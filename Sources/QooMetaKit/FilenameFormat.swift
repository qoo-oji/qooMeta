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
    /// 値に当てはまる形。`@volume` は数字だけ(全角も含む)。ほかは何でもよい。
    var onlyDigits: Bool { self == .volume }
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
        case .missingTitle: "@title が無い"
        case .unbalanced(let c): "括弧の対が合わない: \(c)"
        case .adjacent(let a, let b): "\(a.spelling) と \(b.spelling) のあいだに区切りの文字が要る"
        }
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

    public init(_ text: String) throws(FormatError) {
        self.text = text
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
        word.onlyDigits ? String(value.map(fold)) : value
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
        if !seen.contains(.title) { throw .missingTitle }
        return tokens
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
    func match(_ name: [Character]) -> (match: Match?, progress: Progress) {
        let folded = name.map(Self.fold)
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
                if p < folded.count, folded[p] == c, step(t + 1, p + 1) { return true }
            case .space:
                var end = p
                while end < folded.count, Self.isSpace(folded[end]) { end += 1 }
                for e in stride(from: end, through: p, by: -1) where step(t + 1, e) { return true }
            case .field(let word, let excluded):
                var end = p
                while end < folded.count, !excluded.contains(folded[end]) {
                    // 数字だけの欄(`@volume`)は、数字と空白のあいだで止める。
                    if word.onlyDigits, !folded[end].isNumber, !Self.isSpace(folded[end]) { break }
                    end += 1
                }
                for e in stride(from: end, to: p, by: -1) {
                    // 空白だけの値は欄にしない。
                    guard folded[p..<e].contains(where: { !Self.isSpace($0) }) else { continue }
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

/// 型の並びと、並びの欄の区切り(アプリの設定として 1 組)。
public struct FilenameFormats: Sendable, Hashable {
    public var formats: [FilenameFormat]
    /// 著者の値を分ける文字列(並びの欄は著者だけ)。既定は `,` と `、`(全角のカンマも `,` と同じ)。
    /// `×` `&` `・` は 1 つの名義の中にも現れ、取り違えると著者の先頭(中核の比べる単位)が壊れるので既定に入れない。
    public var separators: [String]
    /// 名前に書かれていない欄に入れる既定の値(プリセットごと)。**名前から読めたときは触らない。**
    ///
    /// 先頭の丸括弧を催しの名前にしている蔵書では、ジャンルがどの名前にも書かれない。そういう蔵書は丸ごと同人誌なので、
    /// プリセットの側でジャンルを決められるようにする(2026-09-20、利用者の判断)。値は JSON が持ち、コードには書かない。
    public var defaults: [BookMetadata.Field: [String]]

    public static let defaultSeparators = [",", "，", "、"]

    public init(formats: [FilenameFormat], separators: [String] = Self.defaultSeparators,
                defaults: [BookMetadata.Field: [String]] = [:]) {
        self.formats = formats
        self.separators = separators
        self.defaults = defaults
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
            for tail in [" (@volume) [@info]", " (@volume)", " [@info]", ""] {
                texts.append("\(genre)[@author] @title\(tail)")
            }
        }
        return texts
    }()

    /// 同梱の既定の並び: 命名の違う本が混ざった蔵書をそのまま読むための 1 本。形ごとに、**数字だけの末尾の丸括弧は巻数**
    /// (`(@volume)`)を先に試し、そうでなければ原作(`(@source)`)として読む。`@volume` は数字だけに当たるので、
    /// 「(12)」は巻数、「(架空の原作)」は原作になる。
    public static let presetTexts: [String] = {
        var texts: [String] = []
        for genre in ["(@genre) ", ""] {
            for author in ["[@author (@author)]", "[@author]"] {
                for tail in [" (@volume) [@info]", " (@volume)", " (@source) [@info]", " (@source)", " [@info]", ""] {
                    texts.append("\(genre)\(author) @title\(tail)")
                }
            }
        }
        return texts
    }()

    public static let preset = FilenameFormats(formats: presetTexts.map { try! FilenameFormat($0) })
    public static let doujinshiPreset = FilenameFormats(formats: doujinshiPresetTexts.map { try! FilenameFormat($0) })
    public static let doujinshiEventPreset = FilenameFormats(formats: doujinshiEventPresetTexts.map { try! FilenameFormat($0) },
                                                             defaults: doujinshiEventDefaults)
    public static let commercialPreset = FilenameFormats(formats: commercialPresetTexts.map { try! FilenameFormat($0) })

    /// 名前を読む。合わなければ、名前全体を仮のタイトルにし、最も近い型を添える。
    public func read(_ name: String) -> FormatReading {
        let chars = Array(name)
        var nearest: (index: Int, progress: FilenameFormat.Progress)?
        for (index, format) in formats.enumerated() {
            let (match, progress) = format.match(chars)
            if let match { return reading(chars, match, formatIndex: index) }
            // どの型も頭の部品から外れた名前(括弧の無い名前など)には、近い型は無いとする(先頭の型を示しても手がかりにならない)。
            if progress.tokens > 0, nearest == nil || nearest!.progress < progress { nearest = (index, progress) }
        }
        let title = TextRules.normalizeDisplay(name)
        var reading = FormatReading(metadata: BookMetadata(title: title), formatIndex: nil,
                                    spans: title.isEmpty ? [] : [FormatReading.Span(word: .title, range: 0..<chars.count)],
                                    nearest: nearest.map { FormatReading.Nearest(formatIndex: $0.index, matchedCharacters: $0.progress.characters) })
        // どの型にも合わなかった名前にも既定の欄は入れる(その蔵書がどういう本かは、型に合ったかどうかで変わらない)。
        applyDefaults(&reading.metadata)
        return reading
    }

    /// 名前から読めなかった欄に、プリセットの既定を入れる。
    func applyDefaults(_ metadata: inout BookMetadata) {
        for (field, values) in defaults where metadata.values(field).isEmpty {
            metadata.set(field, to: values)
        }
    }

    func reading(_ chars: [Character], _ match: FilenameFormat.Match, formatIndex: Int) -> FormatReading {
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
                metadata.set(field, to: metadata.values(field) + split(value))
            } else {
                metadata.set(field, to: [value])
            }
        }
        applyDefaults(&metadata)
        return FormatReading(metadata: metadata, formatIndex: formatIndex, spans: spans, nearest: nil)
    }

    /// 著者の値を区切りで分ける(前後の空白を除き、空の値は捨てる)。
    public func split(_ value: String) -> [String] {
        var parts = [TextRules.normalizeDisplay(value)]
        for separator in separators where !separator.isEmpty {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
    /// 名前 → 型の並び(同梱は `mixed`・`doujinshi`・`doujinshi-event`・`commercial`)。
    public var presets: [String: FilenameFormats]
    /// 本がプリセットを選ばなかったときに使う名前。
    public var defaultName: String

    public init(presets: [String: FilenameFormats], defaultName: String) {
        self.presets = presets
        self.defaultName = defaultName
    }

    /// 名前で選ぶ(無い名前なら既定、それも無ければ同梱の既定)。
    public subscript(name: String?) -> FilenameFormats {
        presets[name ?? defaultName] ?? presets[defaultName] ?? .preset
    }

    public var names: [String] { presets.keys.sorted() }

    /// 同梱のプリセット(コードの側の既定。規則ファイルを読む前に使う)。
    public static let bundled = FormatPresets(
        presets: ["mixed": .preset, "doujinshi": .doujinshiPreset, "doujinshi-event": .doujinshiEventPreset,
                  "commercial": .commercialPreset],
        defaultName: "mixed")
}
