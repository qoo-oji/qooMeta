import Foundation

// 公開する形(docs/api.md「型と関数」)。表示の言葉は含めず、値と符号で返す。

// MARK: - 語彙と辞書

/// 語の集合(比べる形にそろえて持つ)。同じ中身なら等しい。
///
/// **語を 1 本のバイトの並びに詰めて持ち、二分探索で引く。** 文字列の集合(`Set<String>`)で持つと、macOS の英単語の
/// 一覧(約 24 万語)が 12 MB を超え、アプリも CLI も起動のたびにそれを抱えていた(2026-09-21 の計測。詰めると 3 MB 台)。
/// 引くのは英字だけのタイトルを見るときだけなので、二分探索で足りる。
public struct WordSet: Sendable, Hashable {
    /// 語(小文字、UTF-8)を、バイトの順に並べて区切りなしでつないだもの。
    private let bytes: [UInt8]
    /// 語ごとの始まりの位置(最後に、全体の長さ)。
    private let starts: [UInt32]

    public init(_ words: some Sequence<String>) {
        self.init(slices: words.map { Array($0.lowercased().utf8) })
    }

    /// 1 行 1 語のテキストから作る(大きな一覧向け。語ごとに文字列を作らない)。
    public init(lines data: Data) {
        var slices: [[UInt8]] = []
        var line: [UInt8] = []
        var isASCII = true
        func flush() {
            guard !line.isEmpty else { return }
            // ASCII はその場で小文字に。ほかの字を含む行だけ、文字列として小文字にする。
            slices.append(isASCII ? line : Array(String(decoding: line, as: UTF8.self).lowercased().utf8))
            line.removeAll(keepingCapacity: true)
            isASCII = true
        }
        for byte in data {
            if byte == 0x0A || byte == 0x0D { flush(); continue }
            if byte >= 0x80 { isASCII = false }
            line.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte)
        }
        flush()
        self.init(slices: slices)
    }

    private init(slices: [[UInt8]]) {
        let sorted = slices.sorted { $0.lexicographicallyPrecedes($1) }
        var bytes: [UInt8] = [], starts: [UInt32] = []
        bytes.reserveCapacity(sorted.reduce(0) { $0 + $1.count })
        var previous: [UInt8]?
        for word in sorted where word != previous {
            starts.append(UInt32(bytes.count))
            bytes += word
            previous = word
        }
        starts.append(UInt32(bytes.count))
        self.bytes = bytes
        self.starts = starts
    }

    public var count: Int { starts.count - 1 }

    /// 語の全体(要る所でだけ文字列に戻す)。
    var allWords: [String] {
        (0..<count).map { String(decoding: bytes[Int(starts[$0])..<Int(starts[$0 + 1])], as: UTF8.self) }
    }

    /// その語があるか(渡す側が小文字にそろえる。前からの決まり)。
    func contains(_ word: String) -> Bool {
        var word = word
        return word.withUTF8 { target in
            var low = 0, high = count
            while low < high {
                let middle = (low + high) / 2
                let candidate = bytes[Int(starts[middle])..<Int(starts[middle + 1])]
                if candidate.elementsEqual(target) { return true }
                if candidate.lexicographicallyPrecedes(target) { low = middle + 1 } else { high = middle }
            }
            return false
        }
    }
}

// MARK: - 入力

public struct BookInput: Sendable, Hashable {
    /// 利用側の ID(中身は解釈しない)。
    public var id: String
    /// 拡張子を除いたファイル名(またはフォルダ名)。
    public var name: String
    public var confirmation: Confirmation
    /// どの型の並び(プリセット)で読むか。nil なら既定。**フォルダごとに使い分けられる**ように、本ごとに持つ
    /// (2026-09-20、利用者の指示。商業誌と同人誌が混ざったフォルダ構成のため)。どのフォルダにどれを使うかは利用側が決める。
    public var preset: String?

    /// フォルダ名は読まない(2026-09-19 決定。3 つのアプリはどれも読まない)。フォルダは、プリセットを選ぶ手がかりにだけ使う。
    public init(id: String, name: String, preset: String? = nil, confirmation: Confirmation = .none) {
        self.id = id
        self.name = name
        self.preset = preset
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

/// 確定した欄の値(書いていない欄は未確定)。並びの欄は値の並び、1 つの値の欄は先頭だけを使う。
public struct ConfirmedFields: Sendable, Hashable, Codable {
    public var values: [BookMetadata.Field: [String]]

    public init(_ values: [BookMetadata.Field: [String]] = [:]) {
        self.values = values
    }

    public subscript(field: BookMetadata.Field) -> [String]? {
        get { values[field] }
        set { values[field] = newValue }
    }

    /// 確定した欄を metadata へ重ねる。
    public func applied(to metadata: BookMetadata) -> BookMetadata {
        var result = metadata
        for (field, value) in values { result.set(field, to: value) }
        return result
    }
}

/// 入力の上限。細工された名前(極端に長い、大量のフォルダ)で計算を止められないようにする。
public struct InputLimits: Sendable, Hashable {
    public var maxNameLength = 1_000
    public var maxBooks = 1_000_000

    public init() {}
    public static let `default` = InputLimits()
}

/// 扱わなかった入力。
public struct InputIssue: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable { case emptyName, nameTooLong, duplicateID, tooManyBooks }
    public let id: String
    public let reason: Reason
}

public struct ProposalOptions: Sendable, Hashable {
    /// 説明(Explanation)を作る。費用がかかるので既定は無し。
    public var explanations = false
    public var limits: InputLimits = .default

    public init(explanations: Bool = false, limits: InputLimits = .default) {
        self.explanations = explanations
        self.limits = limits
    }
    public static let `default` = ProposalOptions()
}

public struct ProposalProgress: Sendable, Hashable {
    /// 計算を終えた単位(書き手 + ジャンル)の数と、全体の数。
    public let completedUnits: Int
    public let totalUnits: Int
}

// MARK: - 出力

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
        /// 語の規則(`treat: standalone`)でシリーズに入れなかった。
        case standalone
    }

    public let id: String
    /// 入力の名前(並べ替え「ファイル名順」に使う)。
    public let name: String
    /// 名前を型で読んだ結果(欄・一致した型・名前のどこがどの欄か)。確定した欄は重ねていない。
    public let reading: FormatReading
    /// 提案の欄(読んだ欄 + 確定した欄 + 中核が導いたシリーズと巻数)。
    public let metadata: BookMetadata
    public let seriesID: SeriesID?
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
    /// 本の ID → 説明(ProposalOptions.explanations のときだけ)。
    let explanations: [String: Explanation]

    init(proposals: [BookProposal], series: [SeriesProposal], rulesHash: String, rejected: [InputIssue],
         explanations: [String: Explanation] = [:]) {
        self.proposals = proposals
        self.series = series
        self.rulesHash = rulesHash
        self.rejected = rejected
        self.explanations = explanations
        indexByID = Dictionary(proposals.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        seriesByID = Dictionary(series.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    public subscript(id: String) -> BookProposal? { indexByID[id].map { proposals[$0] } }
    public func series(_ id: SeriesID) -> SeriesProposal? { seriesByID[id].map { series[$0] } }
}
