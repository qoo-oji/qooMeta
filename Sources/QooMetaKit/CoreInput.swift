import Foundation

/// 中核(シリーズと巻を導く部分)の入口。docs/roadmap.md「中核の入口」。
///
/// 中核が本について読むのは、ここにあるものだけ。名前をどう欄に分けたか(型・括弧の位置・フォルダ名)は知らない。
/// 前段(名前の読み方)を作り直しても、ここへ同じ値を詰めれば中核の結果は変わらない。
struct CoreBook: Sendable {
    /// 利用側の ID。
    let id: String
    /// 入力の中の順番(単位の中の並びと、決まった順の元)。
    let order: Int
    /// 表示のタイトル(巻の同じ本を並べる最後の手がかり)。
    let title: String
    /// 比べるタイトル(版・入手経路の印を除き、総集編の語順を直したもの)。
    let compareTitle: String
    /// 書き手のキー(比べる形)。空なら、書き手の空の本どうしで 1 つの単位になる。
    let writerKey: String
    /// ジャンル(方針 differentGenre で単位を分ける)。
    let genre: String
    /// 関連(方針 differentRelation で組を分ける)。
    let relation: String
    /// 版・入手経路の印があったか(説明に書くだけ。組には効かない)。
    let hasEditionMarks: Bool
    let hasSourceMarks: Bool
    let confirmation: Confirmation
    /// 「タイトル + 巻」の形なら、巻を除いた頭の長さ(比べる形で)。
    let volumeHead: Int?
}

extension RuleEngine {
    /// 比べる単位。書き手 + ジャンル(**ジャンルが違う本は同じシリーズにしない**。方針 differentGenre)。
    /// ジャンルの空の本は書き手だけで比べる。
    func unitKey(_ book: CoreBook) -> String {
        let genre = rules.series.grouping.splitByGenre ? text.key(book.genre) : ""
        return genre.isEmpty ? book.writerKey : "\(book.writerKey)\u{1}\(genre)"
    }

    /// タイトルから比べるタイトルを作る(版・入手経路の印を除き、総集編の語順を直す)。中核の一部で、前段が何であっても
    /// タイトルの値にこれをかける。印は、比べるタイトルから除かないとき(方針 separateBooks)も見分けて返す。
    func compareTitle(_ title: String) -> (text: String, editions: [String], sources: [String]) {
        let split = markers.split(title)
        return (compilation.normalizedTitle(split.base) ?? split.base, split.editions, split.sources)
    }

    /// 「タイトル + 巻」の形なら、巻を除いた頭の長さ(比べる形で)。
    func volumeHead(compareTitle: String) -> Int? {
        SeriesGrouper(engine: self).volumeHeadLength(text.comparable(compareTitle), minLength: 1)
    }
}
