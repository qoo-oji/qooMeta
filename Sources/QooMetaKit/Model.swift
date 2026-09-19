import Foundation

// 計算の途中で使う形。公開する形は API.swift(docs/api.md)。

/// 計算の途中の 1 冊。比べる単位(書き手 + ジャンル)の中だけで作り、単位の中の番号(`id`、1 から)で指す。
/// 中身は中核の入口(`CoreBook`)から写す。名前をどう読んだかは知らない。
struct WorkingBook: Sendable {
    /// 単位の中の番号(入力の順)。組の名前の元にする本を決めるとき(いちばん小さい番号)にも使う。
    var id: Int
    /// 利用側の ID。
    var inputID: String
    /// 表示のタイトル(巻の同じ本を並べる最後の手がかり)。
    var title: String
    /// 比べるタイトル(`CoreBook.compareTitle`)。組を作る・巻を読むのはこちら。
    var compareTitle: String
    var source: String = ""
    var genre: String = ""
    /// 版・入手経路の印があったか(説明に書くだけ)。
    var hasEditionMarks = false
    var hasSourceMarks = false
    /// 書き手のキー(比べる形)。
    var writerKey: String
    var confirmation: Confirmation = .none
    /// 所属する組(CandidateGroup.id)。
    var groupID: Int?
    /// 最終的なシリーズ名。空ならシリーズなし。
    var series: String = ""
    /// 巻。数字とは限らない(「上」「前編」など)。
    var volumeText: String = ""
    /// 巻を数値として読めたときの値(並べ替え用)。
    var volumeNumber: Double?
    /// 巻をタイトルから読んだのではなく、推定したか(ProposalFinalizer.inferFirstVolumes)。
    var volumeInferred: Bool?
    /// 巻を利用者が確定させたか。
    var volumeConfirmed = false
    /// 「タイトル + 巻」の形なら、巻を除いた頭の長さ(下ごしらえで 1 度だけ求めたもの。nil なら求めていない)。
    var volumeHead: Int??
}

/// 規則で作ったシリーズの組(同じ書き手の、タイトルの前半が共通する本の組)。
struct CandidateGroup: Sendable {
    var id: Int
    var writerKey: String
    var memberIDs: [Int]
    /// シリーズ名(共通する前半部分を元の表記で。確定した名前があればそれ)。
    var ruleName: String
    /// 全員が語の切れ目で切れているか(途中で切れた共通部分は、偶然の一致の疑いがある)。
    var cleanBoundary: Bool
    /// この前半部分で始まるタイトルを持つ書き手の数(単位の中で数える。提案には含めない)。
    var writersSharingPrefix: Int
    /// 1 冊でもシリーズにする組(本編のシリーズがある総集編、確定したシリーズ)。
    var allowsSingle: Bool?
    /// どの規則で組になったか。
    var evidence: SeriesProposal.Evidence = .volumeHead
    /// 総集編の組か。
    var isCompilation = false

    init(id: Int, writerKey: String, memberIDs: [Int], ruleName: String, cleanBoundary: Bool, writersSharingPrefix: Int) {
        self.id = id
        self.writerKey = writerKey
        self.memberIDs = memberIDs
        self.ruleName = ruleName
        self.cleanBoundary = cleanBoundary
        self.writersSharingPrefix = writersSharingPrefix
    }
}

/// 1 つの単位の計算の途中の状態。
struct WorkingDocument: Sendable {
    var books: [WorkingBook]
    var groups: [CandidateGroup]
}
