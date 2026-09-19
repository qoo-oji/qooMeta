import Foundation

/// 1 冊のメタデータ(qooMeta の欄)。docs/metadata.md の 2。
///
/// 欄は意味の決まったものだけ。どの利用先のどの欄へ何を渡すかは書き出しの対応表で決める(キーワード A〜C のような、利用先の
/// 意味の決まらない入れ物は欄にしない)。利用先の制約(著者が 1 つ・巻が数だけ …)に合わせても削らない。
/// 空の欄は空の文字列・空の並びで表す(「無い」と「空」を分けない。絞り込みでは、どちらも「(空)」に入る)。
public struct BookMetadata: Sendable, Hashable, Codable {
    public var title: String
    /// 著者の並び(読み取った順)。**並びなのは著者だけ**(名義が本当に複数ある: サークル名と作画、原作と作画 …)。
    /// 欄が 1 つの利用先へは先頭だけを渡す。比べる単位の書き手は、この先頭。
    public var authors: [String]
    public var genre: String
    /// イベント(頒布会の名前)。ターゲットの 3 アプリには無い欄で、同梱の型も読まない。先頭の丸括弧に頒布会の名前を書く
    /// 利用者が、型で `(@event)` と書いて使う(ジャンルと取り違えたままにせず、別の欄に分けておけるように)。
    public var event: String
    /// 原作(二次創作の元の作品。型の予約語は `@source`。StackNest の neta・ShelfRow の relation にあたる)。
    public var source: String
    /// 情報(名前の中の付記など。タイトル・著者 … のどれでもない部分)。型の予約語は `@info`。読んだ時点では何も捨てず、
    /// 書き出し先に合う欄が無ければ、書き出しの対応表で捨てる。
    public var info: String
    /// シリーズ。ファイル名からは読まず、中核の規則で導く。
    public var series: String
    /// 巻の表記(「3」「上」「総集編1」)。表記は数に読めなくてもよい。
    public var volume: String
    /// 巻の数(並べ替え用。読めなければ nil)。巻を数でしか持てない利用先へはこれを渡す。
    public var volumeNumber: Double?

    public init(title: String = "", authors: [String] = [], genre: String = "", event: String = "", source: String = "",
                info: String = "", series: String = "", volume: String = "", volumeNumber: Double? = nil) {
        self.title = title
        self.authors = authors
        self.genre = genre
        self.event = event
        self.source = source
        self.info = info
        self.series = series
        self.volume = volume
        self.volumeNumber = volumeNumber
    }

    /// 欄。絞り込み・まとめて書き換える操作・書き出しのプレビューが、欄を 1 つずつ書かずに済むように。
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case title, authors, genre, event, source, info, series, volume

        /// 並びの欄か(著者だけ)。
        public var isList: Bool { self == .authors }
    }

    /// 欄の値。1 つの値の欄は、空なら空の並び(絞り込みの「(空)」)。
    public func values(_ field: Field) -> [String] {
        if field == .authors { return authors }
        let value = self[field]
        return value.isEmpty ? [] : [value]
    }

    /// 1 つの値の欄の値(著者は「、」でつないだもの)。
    public subscript(field: Field) -> String {
        switch field {
        case .title: title
        case .authors: authors.joined(separator: "、")
        case .genre: genre
        case .event: event
        case .source: source
        case .info: info
        case .series: series
        case .volume: volume
        }
    }

    /// 欄を書き換える。著者の並びからは空の値を除く(空の要素は絞り込みで「(空)」と見分けられないので作らない)。
    /// 1 つの値の欄は先頭の値にする。
    ///
    /// 巻の表記を書き換えると、巻の数は捨てる(表記と食い違った数を残さない。読み直すのは呼び出し側)。
    public mutating func set(_ field: Field, to newValues: [String]) {
        let list = newValues.filter { !$0.isEmpty }
        let one = list.first ?? ""
        switch field {
        case .title: title = one
        case .authors: authors = list
        case .genre: genre = one
        case .event: event = one
        case .source: source = one
        case .info: info = one
        case .series: series = one
        case .volume:
            if volume != one { volumeNumber = nil }
            volume = one
        }
    }
}
