import Foundation

/// 1 冊のメタデータ(qooMeta の欄)。docs/metadata.md の 2。
///
/// 欄は、ターゲットの 3 アプリ(qooViewer・StackNest・ShelfRow)が管理に使う欄の和集合だけ。どの利用先へ何を渡すかは
/// 書き出しで決めるので、ここでは利用先の制約(著者が 1 つ・巻が数だけ …)に合わせて削らない。
/// 空の欄は空の文字列・空の並びで表す(「無い」と「空」を分けない。値の列では、どちらも「(空)」の行に入る)。
public struct BookMetadata: Sendable, Hashable, Codable {
    public var title: String
    /// 著者の並び(読み取った順)。名義が複数あるので並びにする。欄が 1 つの利用先へは先頭だけを渡す。
    /// 比べる単位の書き手は、この先頭。
    public var authors: [String]
    public var genres: [String]
    /// 関連(ファイル名の型の予約語は `@source`。StackNest・ShelfRow の relation)。
    public var relations: [String]
    public var keywordsA: [String]
    public var keywordsB: [String]
    public var keywordsC: [String]
    /// 種類(ShelfRow の `@type`)。
    public var type: String
    public var memo: String
    /// シリーズ。ファイル名からは読まず、中核の規則で導く。
    public var series: String
    /// 巻の表記(「3」「上」「総集編1」)。表記は数に読めなくてもよい。
    public var volume: String
    /// 巻の数(並べ替え用。読めなければ nil)。巻を数でしか持てない利用先へはこれを渡す。
    public var volumeNumber: Double?

    public init(title: String = "", authors: [String] = [], genres: [String] = [], relations: [String] = [],
                keywordsA: [String] = [], keywordsB: [String] = [], keywordsC: [String] = [], type: String = "",
                memo: String = "", series: String = "", volume: String = "", volumeNumber: Double? = nil) {
        self.title = title
        self.authors = authors
        self.genres = genres
        self.relations = relations
        self.keywordsA = keywordsA
        self.keywordsB = keywordsB
        self.keywordsC = keywordsC
        self.type = type
        self.memo = memo
        self.series = series
        self.volume = volume
        self.volumeNumber = volumeNumber
    }

    /// 欄。値の列・まとめて書き換える操作・書き出しのプレビューが、欄を 1 つずつ書かずに済むように。
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case title, authors, genres, relations, keywordsA, keywordsB, keywordsC, type, memo, series, volume

        /// 並びの欄か(値の列では、並びの要素ごとに 1 冊と数える)。
        public var isList: Bool {
            switch self {
            case .authors, .genres, .relations, .keywordsA, .keywordsB, .keywordsC: true
            case .title, .type, .memo, .series, .volume: false
            }
        }
    }

    /// 欄の値。1 つの値の欄は、空なら空の並び(値の列の「(空)」)。
    public func values(_ field: Field) -> [String] {
        func one(_ s: String) -> [String] { s.isEmpty ? [] : [s] }
        return switch field {
        case .title: one(title)
        case .authors: authors
        case .genres: genres
        case .relations: relations
        case .keywordsA: keywordsA
        case .keywordsB: keywordsB
        case .keywordsC: keywordsC
        case .type: one(type)
        case .memo: one(memo)
        case .series: one(series)
        case .volume: one(volume)
        }
    }

    /// 欄を書き換える。空の値は並びから除く(空の要素を持つ並びは、値の列で「(空)」と見分けられないので作らない)。
    /// 1 つの値の欄は、値を「、」でつないだものにする。
    ///
    /// 巻の表記を書き換えると、巻の数は捨てる(表記と食い違った数を残さない。読み直すのは呼び出し側)。
    public mutating func set(_ field: Field, to newValues: [String]) {
        let list = newValues.filter { !$0.isEmpty }
        let joined = list.joined(separator: "、")
        switch field {
        case .title: title = joined
        case .authors: authors = list
        case .genres: genres = list
        case .relations: relations = list
        case .keywordsA: keywordsA = list
        case .keywordsB: keywordsB = list
        case .keywordsC: keywordsC = list
        case .type: type = joined
        case .memo: memo = joined
        case .series: series = joined
        case .volume:
            if volume != joined { volumeNumber = nil }
            volume = joined
        }
    }
}
