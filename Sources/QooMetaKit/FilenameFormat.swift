import Foundation

// ファイル名フォーマット(docs/filename-format.md の 1・2・5)。
//
// 書き方はターゲットの 3 アプリ(qooViewer・StackNest・ShelfRow)と同じ: 予約語で欄の位置を書き、予約語以外の文字はそのまま
// 照合し、空白は「0 文字以上の空白」。型の並びを上から照合し、名前全体に一致した最初の型で読む。qooMeta で足すのは、
// 全角と半角の括弧を同じとみなすことと、どの型にも合わなかった名前に最も近い型を示すことだけ。
// シリーズと巻は読まない(中核の規則で導く)。フォルダ名も読まない。

/// 予約語。
public enum FormatWord: String, Sendable, Hashable, CaseIterable, Codable {
    case title, author, genre, source, keywordA, keywordB, keywordC, type, ignore

    /// 書いたときの綴り(`@title`)。
    public var spelling: String { "@" + rawValue }

    /// 入る欄(`@ignore` は捨てるので nil)。`@source` は関連(StackNest・ShelfRow の `@relation`)。
    public var field: BookMetadata.Field? {
        switch self {
        case .title: .title
        case .author: .authors
        case .genre: .genres
        case .source: .relations
        case .keywordA: .keywordsA
        case .keywordB: .keywordsB
        case .keywordC: .keywordsC
        case .type: .type
        case .ignore: nil
        }
    }

    /// 1 つの型に何度でも書けるか(名義が複数ある著者と、読まない部分だけ)。
    public var repeatable: Bool { self == .author || self == .ignore }
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

    /// 全角の括弧を半角に畳む(名前の揺れで、意味は同じ)。
    static func fold(_ c: Character) -> Character {
        switch c {
        case "（": "("
        case "）": ")"
        case "［": "["
        case "］": "]"
        default: c
        }
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
                while end < folded.count, !excluded.contains(folded[end]) { end += 1 }
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
    /// 並びの欄(著者・ジャンル・関連・キーワード)の値を分ける文字列。既定は `,` と `、`(全角のカンマも `,` と同じ)。
    /// `×` `&` `・` は 1 つの名義の中にも現れ、取り違えると著者の先頭(中核の比べる単位)が壊れるので既定に入れない。
    public var separators: [String]

    public static let defaultSeparators = [",", "，", "、"]

    public init(formats: [FilenameFormat], separators: [String] = Self.defaultSeparators) {
        self.formats = formats
        self.separators = separators
    }

    /// 同梱の並び(docs/filename-format.md の 5)。ターゲットの既定(qooViewer の 12 通り)の `@ignore` の位置へ欄を割り当て、
    /// 末尾が角括弧だけの形を足した 16 通り。具体的な型を上に置く。タイトル・著者が壊れる型(`@title` だけ、
    /// `@title - @author`、`@title [@author]`)は入れない。
    public static let presetTexts: [String] = {
        var texts: [String] = []
        for genre in ["(@genre) ", ""] {
            for author in ["[@author (@author)]", "[@author]"] {
                for tail in [" (@source) [@ignore]", " (@source)", " [@ignore]", ""] {
                    texts.append("\(genre)\(author) @title\(tail)")
                }
            }
        }
        return texts
    }()

    public static let preset = FilenameFormats(formats: presetTexts.map { try! FilenameFormat($0) })

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
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormatReading(metadata: BookMetadata(title: title), formatIndex: nil,
                             spans: title.isEmpty ? [] : [FormatReading.Span(word: .title, range: 0..<chars.count)],
                             nearest: nearest.map { FormatReading.Nearest(formatIndex: $0.index, matchedCharacters: $0.progress.characters) })
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
            let value = String(chars[lower..<upper])
            if field.isList {
                metadata.set(field, to: metadata.values(field) + split(value))
            } else {
                metadata.set(field, to: [value])
            }
        }
        return FormatReading(metadata: metadata, formatIndex: formatIndex, spans: spans, nearest: nil)
    }

    /// 並びの欄の値を区切りで分ける(前後の空白を除き、空の値は捨てる)。
    func split(_ value: String) -> [String] {
        var parts = [value]
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
