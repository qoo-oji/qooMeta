import Foundation

// 公開する形(docs/api.md「型と関数」)。表示の言葉は含めず、値と符号で返す。

// MARK: - 語彙と辞書

/// 語の集合(比べる形にそろえて持つ)。同じ中身なら等しい。
public struct WordSet: Sendable, Hashable {
    let words: Set<String>

    public init(_ words: some Sequence<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    public static func == (a: WordSet, b: WordSet) -> Bool { a.words.count == b.words.count && a.words == b.words }
    public func hash(into hasher: inout Hasher) { hasher.combine(words.count) }

    public var count: Int { words.count }
    func contains(_ word: String) -> Bool { words.contains(word) }
}

/// 利用者ごとの語彙と辞書。蔵書の語を含むので、利用側の設定に置く。
public struct Vocabulary: Sendable, Hashable {
    /// 先頭の括弧のうち、本の種別とみなす語。
    public var genres: [String]
    /// 規則が名前で指す辞書(`"english"` など)。
    public var dictionaries: [String: WordSet]

    public init(genres: [String] = [], dictionaries: [String: WordSet] = [:]) {
        self.genres = genres
        self.dictionaries = dictionaries
    }
}

// MARK: - 入力

public struct BookInput: Sendable, Hashable {
    /// 利用側の ID(中身は解釈しない)。
    public var id: String
    /// 拡張子を除いたファイル名(またはフォルダ名)。
    public var name: String
    /// 入っているフォルダ名(近い順、任意)。サークルの無い名前は、いちばん近いフォルダが書き手になる。
    public var folders: [String]
    public var confirmation: Confirmation

    public init(id: String, name: String, folders: [String] = [], confirmation: Confirmation = .none) {
        self.id = id
        self.name = name
        self.folders = folders
        self.confirmation = confirmation
    }
}

/// 利用者が確定させた内容。
public enum Confirmation: Sendable, Hashable, Codable {
    case none
    /// 欄の値を確定した(nil の欄は未確定)。シリーズについては何も言っていない。
    case fields(ConfirmedFields)
    /// このシリーズの本だと確定した。volume が nil なら巻は未確定。
    case series(name: String, volume: String?, fields: ConfirmedFields = .init())
    /// シリーズの本ではないと確定した。
    case notInSeries(fields: ConfirmedFields = .init())

    public var fields: ConfirmedFields {
        switch self {
        case .none: .init()
        case .fields(let f), .series(_, _, let f), .notInSeries(let f): f
        }
    }
}

public struct ConfirmedFields: Sendable, Hashable, Codable {
    public var circle: String?, authors: [String]?, title: String?, relation: String?, genre: String?

    public init(circle: String? = nil, authors: [String]? = nil, title: String? = nil, relation: String? = nil,
                genre: String? = nil) {
        self.circle = circle
        self.authors = authors
        self.title = title
        self.relation = relation
        self.genre = genre
    }
}

/// 入力の上限。細工された名前(極端に長い、大量のフォルダ)で計算を止められないようにする。
public struct InputLimits: Sendable, Hashable {
    public var maxNameLength = 1_000
    public var maxFolders = 32
    public var maxFolderNameLength = 1_000
    public var maxBooks = 1_000_000

    public init() {}
    public static let `default` = InputLimits()
}

/// 扱わなかった入力。
public struct InputIssue: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable { case emptyName, nameTooLong, tooManyFolders, folderNameTooLong,
                                                          duplicateID, tooManyBooks }
    public let id: String
    public let reason: Reason
}

public struct ProposalOptions: Sendable, Hashable {
    public var limits: InputLimits = .default

    public init(limits: InputLimits = .default) { self.limits = limits }
    public static let `default` = ProposalOptions()
}

public struct ProposalProgress: Sendable, Hashable {
    /// 計算を終えた単位(書き手 + 本の種別)の数と、全体の数。
    public let completedUnits: Int
    public let totalUnits: Int
}

// MARK: - 出力

/// ファイル名を欄に分けた結果。
public struct ParsedName: Sendable, Hashable {
    public var genre: String?, event: String?, circle: String?, authors: [String]
    /// タイトル(版・入手経路の印を含む、ファイル名のとおりの表記)。
    public var title: String
    public var relation: String?, keyword: String?
    public var editions: [String], sources: [String]
    public var format: FormatMatch
    /// 1 冊だけで読める巻(「X 第3巻」)。シリーズ名は推定しない。
    public var standaloneVolume: Volume?
}

/// どのフォーマットで読めたか。
public enum FormatMatch: Sendable, Hashable {
    /// プロファイルの ID と、その中のフォーマットの番号(0 から)。
    case format(profile: String, index: Int)
    /// どのフォーマットにも一致せず、括弧の位置だけで読んだ(`simpleBrackets`)か、名前全体をタイトルにした(`wholeName`)。
    case fallback(String)
}

public struct Volume: Sendable, Hashable {
    /// 表記(「36-37」「上」「後編1」)。
    public let text: String
    /// 並べ替え用(36、1、3.1)。
    public let sortKey: Double?
    /// 推定した巻(番号の無い 1 冊を 1 巻とみなした)。
    public let inferred: Bool

    public init(text: String, sortKey: Double?, inferred: Bool = false) {
        self.text = text
        self.sortKey = sortKey
        self.inferred = inferred
    }
}

/// シリーズの ID。**その `ProposalSet` の中でだけ意味を持つ**(本を足すと変わりうる)。利用側は保存しない。
public struct SeriesID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public static func < (a: SeriesID, b: SeriesID) -> Bool { a.rawValue < b.rawValue }
}

public struct BookProposal: Sendable, Hashable {
    public enum Flag: String, Sendable, Hashable, CaseIterable {
        case inferredVolume, edition, source, compilation, magazineIssue, confirmed
    }

    public let id: String
    public let parsed: ParsedName
    public let seriesID: SeriesID?
    public let volume: Volume?
    public let flags: Set<Flag>
}

public struct SeriesProposal: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case series, compilation, magazineYear }

    public enum Evidence: Sendable, Hashable {
        /// 「タイトル + 巻」を頭でまとめた(1 段目)。
        case volumeHead
        /// 先頭の共通部分でまとめた(2 段目)。`cleanCut` なら全員が語の切れ目で切れている。
        case sharedPrefix(cleanCut: Bool)
        /// 総集編の語でまとめた。
        case compilation
        /// 利用者が確定させた名前でまとめた。
        case confirmed
    }

    public let id: SeriesID
    public let name: String
    public let kind: Kind
    /// 巻の順。
    public let memberIDs: [String]
    public let evidence: Evidence
}

public struct ProposalSet: Sendable {
    /// 入力と同じ順。
    public let proposals: [BookProposal]
    /// 決まった順(書き手 → 名前 → 最小の本の ID)。
    public let series: [SeriesProposal]
    public let rulesHash: String
    /// 上限を超えた名前など、扱わなかった入力。
    public let rejected: [InputIssue]

    let indexByID: [String: Int]
    let seriesByID: [SeriesID: Int]

    init(proposals: [BookProposal], series: [SeriesProposal], rulesHash: String, rejected: [InputIssue]) {
        self.proposals = proposals
        self.series = series
        self.rulesHash = rulesHash
        self.rejected = rejected
        indexByID = Dictionary(proposals.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        seriesByID = Dictionary(series.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    public subscript(id: String) -> BookProposal? { indexByID[id].map { proposals[$0] } }
    public func series(_ id: SeriesID) -> SeriesProposal? { seriesByID[id].map { series[$0] } }
}
