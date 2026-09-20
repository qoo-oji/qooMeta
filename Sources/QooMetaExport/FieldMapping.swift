import Foundation
import QooMetaKit

/// 書き出し先のアプリ。
///
/// **読み方は 1 つ、書き出し先ごとの違いはここで振り分ける**(2026-09-20 の決定。docs/metadata.md
/// 「書き出し先ごとの欄の対応」)。ファイル名は同じ型の並びで qooMeta の欄に読み、どの欄をどの欄へ渡すかだけを
/// 書き出し先ごとに決める。直した内容は作業ファイルに残るので、使うアプリを乗り換えたら出力し直せばよい。
public enum ExportTarget: String, Sendable, Hashable, Codable, CaseIterable {
    case qooViewer
    /// StackNest(Stackroom XML を取り込む)。
    case stackNest
    /// ShelfRow(同じ Stackroom XML を取り込むが、読む欄が違う)。
    case shelfRow

    public var label: String {
        switch self {
        case .qooViewer: "qooViewer"
        case .stackNest: "StackNest"
        case .shelfRow: "ShelfRow"
        }
    }

    /// 書き出す形式(StackNest と ShelfRow は同じ Stackroom XML)。
    public var format: ExportFormat {
        switch self {
        case .qooViewer: .qooViewerJSON
        case .stackNest, .shelfRow: .stackroomXML
        }
    }

    /// 選べる行き先(**そのアプリの取り込みが実際に読む欄だけ**)。
    ///
    /// 2026-09-20 に、StackNest(`StackroomFormat/BookRecord.swift`・`LibraryStore/LibraryImporter.swift`)と
    /// ShelfRow(`ShelfRow/LibraryImporter.swift`)の取り込みのコードを読んで数え直した。読まない欄へ渡すと、
    /// 書き出しは成功するのに値だけが消えるので、**行き先に出さない**。
    ///
    /// - ShelfRow は `Genre` を読まない(取り込みでジャンルは必ず空になる)。シリーズ・巻数・キーワード C の欄も持たない。
    ///   ShelfRow の「メモ」に入るのは `Neta`。
    /// - StackNest に `Memo` という欄は無い(本体はメモを持つが、Stackroom XML からは渡らない)。
    public var slots: [ExportSlot] {
        switch self {
        case .qooViewer: [.title, .author, .series, .seriesIndex]
        case .shelfRow: [.title, .author, .neta, .keywordA, .keywordB]
        case .stackNest: [.title, .author, .genre, .series, .volume, .neta, .keywordA, .keywordB, .keywordC]
        }
    }

    /// 取り込みが読む Stackroom XML のキー(書き出しの確かめに使う)。
    public var readableStackroomKeys: Set<String> {
        switch self {
        case .qooViewer: []
        // ShelfRow/LibraryImporter.swift が bookData から読むキー。
        case .shelfRow: ["ID", "Path", "Title", "Author", "My Rate", "Unseen", "Pages", "Book Type", "File Type",
                         "Cover Image Name", "Cover Image Path", "Keyword A", "Keyword B", "Neta", "Date Added", "Play Date"]
        // StackNest/StackroomFormat/BookRecord.swift の CodingKeys。
        case .stackNest: ["ID", "Title", "Author", "Genre", "Path", "Cover Image Path", "Cover Image Name", "Date Added",
                          "Play Date", "Book Type", "File Type", "Pages", "My Rate", "Unseen",
                          "Keyword A", "Keyword B", "Keyword C", "Neta", "Series", "Volume"]
        }
    }

    /// 並びの欄(著者)を、いくつ渡せるか。
    public var takesAllAuthors: Bool {
        // StackNest は Author をカンマ区切りの複数値として扱い、値ごとに絞り込める。ほかは 1 つだけ。
        self == .stackNest
    }
}

public enum ExportFormat: String, Sendable, Hashable, Codable {
    case stackroomXML, qooViewerJSON
}

/// 書き出し先の欄(行き先)。Stackroom XML の欄の名前と、qooViewer の JSON の欄。
public enum ExportSlot: String, Sendable, Hashable, Codable, CaseIterable {
    case title, author, genre, series
    /// 巻数の数の欄(Stackroom の Volume)。数に読めない表記は渡せない。
    case volume
    /// 巻数の表記の欄(qooViewer の seriesIndex)。
    case seriesIndex
    /// Stackroom の Neta。StackNest では「ネタ」の欄、**ShelfRow では「メモ」の欄**になる
    /// (ShelfRow の取り込みが `Neta` をメモへ入れる)。
    case neta
    case keywordA, keywordB, keywordC

    public var label: String {
        switch self {
        case .title: "タイトル"
        case .author: "著者"
        case .genre: "ジャンル"
        case .series: "シリーズ"
        case .volume: "巻数(数)"
        case .seriesIndex: "巻数(表記)"
        case .neta: "ネタ"
        case .keywordA: "キーワード A"
        case .keywordB: "キーワード B"
        case .keywordC: "キーワード C"
        }
    }

    /// 画面に出す名前。同じ欄でも、取り込む側での呼び名が違うことがある。
    public func label(in target: ExportTarget) -> String {
        if self == .neta, target == .shelfRow { return "メモ(Neta)" }
        return label
    }

    /// Stackroom XML のキー(qooViewer の欄には無い)。
    var stackroomKey: String? {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .genre: "Genre"
        case .series: "Series"
        case .volume: "Volume"
        case .neta: "Neta"
        case .keywordA: "Keyword A"
        case .keywordB: "Keyword B"
        case .keywordC: "Keyword C"
        case .seriesIndex: nil
        }
    }
}

/// 欄の対応表: qooMeta の欄 → 書き出し先の欄。**書いていない欄は落ちる**(書き出しのプレビューで印を付ける)。
///
/// 既定を持ち、利用者が変えられる(アプリの設定として持つ。作業ファイルには入れない)。
public struct FieldMapping: Sendable, Hashable, Codable {
    public var target: ExportTarget
    /// qooMeta の欄 → 行き先。巻数はソート用(`.volumeSort`)と表示用(`.volume`)を分けて持つ。
    public var slots: [Key: ExportSlot]

    /// 対応表の左側(qooMeta の欄。巻数だけは 2 つに分かれる)。
    public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
        case title, authors, genre, event, source, info, series
        /// 巻数(表示用。名前のとおりの表記)。
        case volume
        /// 巻数(ソート用。シリーズの中の位置)。
        case volumeSort

        public var label: String {
            switch self {
            case .title: "タイトル"
            case .authors: "著者"
            case .genre: "ジャンル"
            case .event: "イベント"
            case .source: "原作"
            case .info: "情報"
            case .series: "シリーズ"
            case .volume: "巻数(表示)"
            case .volumeSort: "巻数(ソート)"
            }
        }

        /// 本の欄の値(表示用と ソート用の巻数はここで分ける)。
        public func values(_ metadata: BookMetadata) -> [String] {
            switch self {
            case .title: metadata.values(.title)
            case .authors: metadata.authors
            case .genre: metadata.values(.genre)
            case .event: metadata.values(.event)
            case .source: metadata.values(.source)
            case .info: metadata.values(.info)
            case .series: metadata.values(.series)
            case .volume: metadata.values(.volume)
            case .volumeSort: metadata.volumeSort.map { [Self.number($0)] } ?? []
            }
        }

        static func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    public init(target: ExportTarget, slots: [Key: ExportSlot]) {
        self.target = target
        self.slots = slots
    }

    // 対応表は利用者が手で書き換えられるので、JSON では `{"target": "...", "slots": {"欄": "行き先"}}` の形にする
    // (Swift の既定の書き方だと、鍵と値が交互に並ぶ配列になって読めない)。
    enum CodingKeys: String, CodingKey { case target, slots }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(ExportTarget.self, forKey: .target)
        let raw = try c.decodeIfPresent([String: String].self, forKey: .slots) ?? [:]
        slots = raw.reduce(into: [:]) { result, pair in
            guard let key = Key(rawValue: pair.key), let slot = ExportSlot(rawValue: pair.value) else { return }
            result[key] = slot
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .slots)
    }

    /// 書いていない欄を既定のままにする(利用者の差分を重ねる)。
    public func merging(_ changes: [Key: ExportSlot?]) -> FieldMapping {
        var result = self
        for (key, slot) in changes { result.slots[key] = slot }
        return result
    }

    /// 既定の対応(docs/metadata.md「書き出し先ごとの欄の対応」)。利用者はこれを出発点に変える。
    public static func standard(for target: ExportTarget) -> FieldMapping {
        switch target {
        case .qooViewer:
            // qooViewer が持つのはこの 4 つだけ。ジャンル・イベント・原作・情報は落ちる。
            FieldMapping(target: target, slots: [.title: .title, .authors: .author, .series: .series, .volume: .seriesIndex])
        case .stackNest:
            // 巻数の欄は数なので、ソート用をそのまま渡す。表記は空いている欄(キーワード C)へ。
            // StackNest に「メモ」の欄は無いので、情報はキーワード A へ。イベントは既定では落とす(キーワード B へ回せる)。
            FieldMapping(target: target, slots: [.title: .title, .authors: .author, .genre: .genre, .source: .neta,
                                                 .info: .keywordA, .series: .series, .volumeSort: .volume,
                                                 .volume: .keywordC])
        case .shelfRow:
            // ShelfRow が読むのは タイトル・著者・キーワード A・キーワード B・Neta(= メモ)だけ。
            // ジャンルの欄は取り込みで読まれないので、キーワード A へ回す。情報は Neta へ入れると「メモ」になる。
            // 原作は既定では渡さない(空いている行き先が残っていない。キーワード B と入れ替えられる)。
            FieldMapping(target: target, slots: [.title: .title, .authors: .author, .genre: .keywordA,
                                                 .info: .neta, .volume: .keywordB])
        }
    }

    /// その欄の行き先(落ちるなら nil)。行き先がその書き出し先に無ければ落ちる。
    public func slot(for key: Key) -> ExportSlot? {
        guard let slot = slots[key], target.slots.contains(slot) else { return nil }
        return slot
    }

    /// 行き先 → その欄へ入れる qooMeta の欄(同じ行き先に 2 つ割り当てたら、Key の並びの先のものが勝つ)。
    var keysBySlot: [ExportSlot: Key] {
        var result: [ExportSlot: Key] = [:]
        for key in Key.allCases {
            guard let slot = slot(for: key) else { continue }
            if let existing = result[slot], Key.allCases.firstIndex(of: existing)! < Key.allCases.firstIndex(of: key)! { continue }
            result[slot] = key
        }
        return result
    }
}

/// 書き出しのプレビュー: どの欄がどこへ行き、どの欄が落ちるか(落ちる欄は、値を持つ冊数も数える)。
public struct ExportPreview: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public let key: FieldMapping.Key
        /// 行き先(落ちるなら nil)。
        public let slot: ExportSlot?
        /// その欄に値のある冊数。
        public let booksWithValue: Int
        /// 値があるのに落ちる冊数(= 落ちる欄なら booksWithValue、そうでなければ 0)。
        public var droppedBooks: Int { slot == nil ? booksWithValue : 0 }
        /// 並びの欄で、先頭だけが渡る冊数(著者が 2 人以上の本)。
        public let truncatedBooks: Int
    }

    public let target: ExportTarget
    public let bookCount: Int
    public let rows: [Row]

    /// 値があるのに落ちる欄だけ(画面の印)。
    public var droppedRows: [Row] { rows.filter { $0.slot == nil && $0.booksWithValue > 0 } }
}

public extension Exporter {
    /// 書き出す前に、欄がどこへ行き、どこで落ちるかを数える(本の名前は含まない)。
    static func preview(_ set: ProposalSet, mapping: FieldMapping) -> ExportPreview {
        let rows = FieldMapping.Key.allCases.map { key in
            var withValue = 0, truncated = 0
            for book in set.proposals {
                let values = key.values(book.metadata)
                if !values.isEmpty { withValue += 1 }
                if key == .authors, values.count > 1, !mapping.target.takesAllAuthors { truncated += 1 }
            }
            return ExportPreview.Row(key: key, slot: mapping.slot(for: key), booksWithValue: withValue,
                                     truncatedBooks: truncated)
        }
        return ExportPreview(target: mapping.target, bookCount: set.proposals.count, rows: rows)
    }
}
