import Foundation

/// 1 冊のメタデータ(qooMeta の欄)。docs/metadata.md の 2。
///
/// 欄は意味の決まったものだけ。どの利用先のどの欄へ何を渡すかは書き出しの対応表で決める(キーワード A〜C のような、利用先の
/// 意味の決まらない入れ物は欄にしない)。利用先の制約(著者が 1 つ・巻が数だけ …)に合わせても削らない。
/// 空の欄は空の文字列・空の並びで表す(「無い」と「空」を分けない。絞り込みでは、どちらも「(空)」に入る)。
///
/// **シリーズと巻数のほかの欄は、値をいくつでも持てる**(2026-09-27、利用者の指示。情報を 2 つ付けたい、など)。
/// 先頭の値は下の欄(`title` `genre` …)に、2 つ目からは `moreValues` に入る。中核(シリーズと巻を導く処理)が読むのは
/// 先頭だけ。著者は前から並び(`authors`)。シリーズと巻数は中核が導く「主のシリーズ」1 つで、利用者が足したシリーズは
/// `alternateSeries` に別に持つ(中核は読まない)。
public struct BookMetadata: Sendable, Hashable, Codable {
    public var title: String
    /// 著者の並び(読み取った順)。名前から最初から複数読める欄は著者だけ(名義が本当に複数ある: サークル名と作画、
    /// 原作と作画 …)。欄が 1 つの利用先へは先頭だけを渡す。比べる単位の書き手は、この先頭。
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
    /// 巻数(表示用)。名前に書かれていた表記(「第01巻」「上」「総集編2」)。数に読めなくてもよい。
    public var volume: String
    /// 巻数(ソート用)。シリーズの中の位置(「第01巻」なら 1.0)。名前から分かる順番だけを入れ、分からなければ nil
    /// (総集編を本編に含めても、オフセットで作った数は入れない。2026-09-22 にオフセットを捨てた)。
    public var volumeSort: Double?
    /// タイトル・ジャンル・イベント・原作・情報の、2 つ目からの値(利用者が足したもの。名前からは読まない)。
    /// 先頭の値が空のまま、ここにだけ値が入ることはない(`set` が詰める)。
    public var moreValues: [Field: [String]]
    /// 利用者が足したシリーズ(2 つ目から。主のシリーズ `series` の下に並ぶ)。**中核は読まない** ―― 組み分けにも、
    /// 見比べの錨にもならないラベル。巻数(ソート用)は、確定していなければ巻数(表示用)を巻の読み手に通して決める。
    public var alternateSeries: [AlternateSeries]

    public init(title: String = "", authors: [String] = [], genre: String = "", event: String = "", source: String = "",
                info: String = "", series: String = "", volume: String = "", volumeSort: Double? = nil,
                moreValues: [Field: [String]] = [:], alternateSeries: [AlternateSeries] = []) {
        self.title = title
        self.authors = authors
        self.genre = genre
        self.event = event
        self.source = source
        self.info = info
        self.series = series
        self.volume = volume
        self.volumeSort = volumeSort
        self.moreValues = moreValues.filter { $0.key.takesMoreValues && !$0.value.isEmpty }
        self.alternateSeries = alternateSeries
    }

    /// 欄。絞り込み・まとめて書き換える操作・書き出しのプレビューが、欄を 1 つずつ書かずに済むように。
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case title, authors, genre, event, source, info, series, volume

        /// 名前から並びとして読む欄か(著者だけ。区切りで分ける)。
        public var isList: Bool { self == .authors }

        /// 値をいくつも持てる欄か(シリーズと巻数のほか全部)。シリーズと巻数は中核が導く 1 つで、足したシリーズは
        /// `alternateSeries` に組で持つ。
        public var holdsSeveral: Bool { self != .series && self != .volume }

        /// 2 つ目からの値を `moreValues` に持つ欄か(著者は `authors` の並びそのもの)。
        var takesMoreValues: Bool { holdsSeveral && !isList }
    }

    /// 利用者が足したシリーズ 1 つ(名前・巻数(表示用)・巻数(ソート用)の組)。
    public struct AlternateSeries: Sendable, Hashable, Codable {
        public var name: String
        public var volume: String
        /// 巻数(ソート用)。確定した内容(`ConfirmedFields.alternateSeries`)では、nil なら巻数(表示用)から読む。
        public var volumeSort: Double?

        public init(name: String, volume: String = "", volumeSort: Double? = nil) {
            self.name = name
            self.volume = volume
            self.volumeSort = volumeSort
        }
    }

    /// 巻数(ソート用)を文字にする(整数なら小数点を付けない)。
    ///
    /// **`Int(value)` で直さない。** 名前の中の長い数字の並び(20 桁の番号など)も巻として読めるので、数は
    /// Int の範囲を超えうる。範囲の外の Double を Int にすると、そこでアプリが落ちる(2026-09-21 の監査)。
    public static func volumeSortText(_ value: Double) -> String {
        if value == value.rounded(), let whole = Int(exactly: value) { return String(whole) }
        return String(value)
    }

    /// 欄の値(並び)。空なら空の並び(絞り込みの「(空)」)。シリーズと巻数は主のシリーズの 1 つだけ
    /// (足したシリーズは `alternateSeries`)。
    public func values(_ field: Field) -> [String] {
        if field == .authors { return authors }
        let value = self[field]
        let more = moreValues[field] ?? []
        return value.isEmpty ? more : [value] + more
    }

    /// 欄の先頭の値(著者は「、」でつないだもの)。並べ替えの鍵や、1 つしか受けない所に使う。
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

    /// 欄を書き換える。空の値は除く(空の要素は絞り込みで「(空)」と見分けられないので作らない)。
    /// 値をいくつも持てる欄は、先頭を欄に、2 つ目からを `moreValues` に入れる。シリーズと巻数は先頭の値だけ。
    ///
    /// 巻数(表示用)を書き換えると、巻数(ソート用)は捨てる(表記と食い違った数を残さない。読み直すのは呼び出し側)。
    public mutating func set(_ field: Field, to newValues: [String]) {
        let list = newValues.filter { !$0.isEmpty }
        let one = list.first ?? ""
        if field.takesMoreValues { moreValues[field] = list.count > 1 ? Array(list.dropFirst()) : nil }
        switch field {
        case .title: title = one
        case .authors: authors = list
        case .genre: genre = one
        case .event: event = one
        case .source: source = one
        case .info: info = one
        case .series: series = one
        case .volume:
            // 表示用を書き換えたら、ソート用は捨てる(食い違った数を残さない。読み直すのは呼び出し側)。
            if volume != one { volumeSort = nil }
            volume = one
        }
    }

    // MARK: - JSON

    // 足した値・足したシリーズは、あるときだけ書く(前の版が書いたファイルも、前の版が読むファイルも同じ形のまま)。
    // 2 つ目からの値は `{"info": ["…"]}` の形にする(Swift の既定の書き方だと、鍵と値が交互に並ぶ配列になって読めない)。
    enum CodingKeys: String, CodingKey {
        case title, authors, genre, event, source, info, series, volume, volumeSort, moreValues, alternateSeries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let more = try c.decodeIfPresent([String: [String]].self, forKey: .moreValues) ?? [:]
        self.init(title: try c.decode(String.self, forKey: .title),
                  authors: try c.decode([String].self, forKey: .authors),
                  genre: try c.decode(String.self, forKey: .genre),
                  event: try c.decode(String.self, forKey: .event),
                  source: try c.decode(String.self, forKey: .source),
                  info: try c.decode(String.self, forKey: .info),
                  series: try c.decode(String.self, forKey: .series),
                  volume: try c.decode(String.self, forKey: .volume),
                  volumeSort: try c.decodeIfPresent(Double.self, forKey: .volumeSort),
                  moreValues: more.reduce(into: [:]) { result, pair in
                      guard let field = Field(rawValue: pair.key) else { return }
                      result[field] = pair.value.filter { !$0.isEmpty }
                  },
                  alternateSeries: try c.decodeIfPresent([AlternateSeries].self, forKey: .alternateSeries) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encode(genre, forKey: .genre)
        try c.encode(event, forKey: .event)
        try c.encode(source, forKey: .source)
        try c.encode(info, forKey: .info)
        try c.encode(series, forKey: .series)
        try c.encode(volume, forKey: .volume)
        try c.encodeIfPresent(volumeSort, forKey: .volumeSort)
        if !moreValues.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: moreValues.map { ($0.key.rawValue, $0.value) }), forKey: .moreValues)
        }
        if !alternateSeries.isEmpty { try c.encode(alternateSeries, forKey: .alternateSeries) }
    }
}
