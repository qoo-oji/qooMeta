import Foundation

/// 規則の既定値(パッケージに同梱した 2 つの JSON)。
///
/// - `filename-formats.json`: ファイル名をどう区切り、どこがサークル・作者・タイトル・ネタ(関連)かを決めるフォーマット。
///   予約語は Stackroom(StackNest・ShelfRow)に合わせ、照合の処理(Sources/QooFormat、qooLibrary 由来)の予約語へは
///   `reservedWords` の対応表で置き換える。
/// - `series-rules.json`: タイトルからシリーズ名と巻を取り出す規則(比べ方・組の作り方と例外・名前の整え方・
///   版と入手経路・総集編・巻の読み方)。
///
/// どちらも**蔵書の名前を含まない**(一般的な語と記号だけ)。公開リポジトリに置く。
public enum RuleFiles {
    public static let filenameFormats: FilenameFormatRules = load("filename-formats")
    public static let seriesRules: SeriesRules = load("series-rules")

    static func load<T: Decodable>(_ name: String) -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            fatalError("規則のファイルが見つからない: \(name).json")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            fatalError("規則のファイルを読めない: \(name).json: \(error)")
        }
    }
}

public struct FilenameFormatRules: Decodable, Sendable {
    public struct ReservedWord: Decodable, Sendable {
        /// 照合の処理(QooFormat)での予約語。
        public var engine: String
        /// qooMeta の欄(genre / event / circle / authors / title / relation / keyword)。
        public var field: String
    }

    public var version: Int
    /// Stackroom 式の予約語 → 照合の処理の予約語と、qooMeta の欄。
    public var reservedWords: [String: ReservedWord]
    /// 区切りに使う括弧の組(開き, 閉じ)。
    public var delimiters: [[String]]
    /// 作者が複数のときの区切り文字。
    public var authorSeparators: String
    /// 上から順に照合し、最初に一致したものを採る。
    public var formats: [String]
    /// 1 かたまりとして扱う文字列(正規表現)。「(2019)」のような年や「(完結)」を、末尾の丸括弧と取り違えないため。
    public var protectedTokens: [String]
}

public struct SeriesRules: Decodable, Sendable {
    public struct Compare: Decodable, Sendable {
        /// 比べるときに無視する文字(空白と、タイトルの飾りによく使われる記号)。
        public var ignoredCharacters: String
        /// 比べるときに同じ字とみなす異体字(左 → 右)。
        public var variantKanji: [String: String]
    }

    public struct Grouping: Decodable, Sendable {
        /// 語の途中で切れる共通部分は、この文字数以上のときだけ組にする。
        public var minPrefix: Int
        /// 片方のタイトル全体がもう片方の前半と一致する場合の下限。
        public var minWholeTitle: Int
        public var attachSubtitled: Bool
        public var splitByGenre: Bool
        public var rejectHiraganaEndings: Bool
        public var rejectSingleWordPrefixes: Bool
        public var rejectCommonEnglishTitles: Bool
        public var englishDictionary: String
        /// 語の切れ目とみなす文字(この直前で切れた共通部分は「きれいな切れ目」)。
        public var boundaryCharacters: String
    }

    public struct Naming: Decodable, Sendable {
        /// シリーズ名の末尾から落とす文字。
        public var trimTrailing: String
        /// 共通部分の直後にあれば、名前に含める文字。
        public var keepFollowing: String
        /// 閉じ括弧 → 開き括弧。開いたままの括弧があれば、直後の閉じ括弧まで名前に含める。
        public var brackets: [String: String]
        /// 名前の末尾に残ったら外す語(後ろに付く名前を導く語)。
        public var labelIntroducers: [String]
    }

    public struct Editions: Decodable, Sendable {
        public var edition: [String]
        public var editionPatterns: [String]
        public var source: [String]
        public var sourcePatterns: [String]
    }

    public struct Compilation: Decodable, Sendable {
        public var keywords: [String]
    }

    public struct Volume: Decodable, Sendable {
        public struct PositionWords: Decodable, Sendable {
            public var first: [String]
            public var middle: [String]
            public var last: [String]
        }

        /// 巻の番号の前に付く語(`vol` `第` `その` …)。英字の語は後ろの「.」も受け付ける。
        public var prefixes: [String]
        /// 巻の番号の後ろに付く単位。
        public var counters: [String]
        /// 巻だけでできているかを見るときにだけ使う単位。
        public var wholeOnlyCounters: [String]
        /// 漢数字の後ろに付く単位。
        public var kanjiCounters: [String]
        public var positionWords: PositionWords
        /// 「36-37」を合併号とみなす、前後の差の上限。
        public var mergedIssueMaxSpan: Int
        /// シリーズ名より後ろにこの語があれば、1 巻の推定の候補にしない。
        public var notFirstMarkers: [String]
        /// シリーズ名の直後にこの語が付けば、1 巻の推定の候補にしない。
        public var notFirstPrefixes: [String]
    }

    public var version: Int
    public var compare: Compare
    public var grouping: Grouping
    public var naming: Naming
    public var editions: Editions
    public var compilation: Compilation
    public var volume: Volume
}

extension SeriesRules.Volume {
    /// 正規表現の選択肢(長い語を先に)。英字の語には「.」の省略を許す。
    func alternation(_ words: [String], allowDot: Bool = false) -> String {
        words.sorted { $0.count > $1.count }.map { w in
            let escaped = NSRegularExpression.escapedPattern(for: w)
            return allowDot && w.allSatisfy({ $0.isASCII && $0.isLetter }) ? escaped + #"\.?"# : escaped
        }.joined(separator: "|")
    }

    var prefixPattern: String { alternation(prefixes, allowDot: true) }
    /// 漢数字の前に付く語(英字・記号でないもの)。
    var kanjiPrefixPattern: String { alternation(prefixes.filter { !$0.allSatisfy(\.isASCII) }) }
    var positionPattern: String { alternation(positionWords.first + positionWords.middle + positionWords.last) }
}
