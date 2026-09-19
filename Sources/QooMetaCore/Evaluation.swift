import Foundation

/// 正解付きのデータで、シリーズの候補づくりを採点する。
///
/// 入力は 1 行 1 冊の JSON(`author` `title` `series`)。`title` はファイル名のタイトル部分に当たる文字列
/// (巻を含む)、`series` は正解のシリーズ(作品)名。公開データ(NDL サーチの書誌など)から作る
/// (scripts/corpus/)。**利用者の蔵書から作ったデータをここへ入れる場合も、結果として出るのは集計だけ。**
public struct LabeledBook: Codable, Sendable {
    public var author: String
    public var title: String
    public var series: String
}

public enum Evaluator {
    public struct Score: Sendable {
        public var books = 0
        public var authors = 0
        /// 正解で同じシリーズの本の組(同じ書き手の中)。
        public var truePairs = 0
        /// 候補で同じ組になった本の組。
        public var predictedPairs = 0
        public var correctPairs = 0
        /// 正解のシリーズが 2 冊以上ある本のうち、候補のシリーズ名が正解と一致した冊数。
        public var nameMatches = 0
        public var namedBooks = 0
        /// 誤って同じ組にした本の組の例(公開データの分析用。利用者の蔵書では使わない)。
        public var falsePairs: [(LabeledBook, LabeledBook)] = []
        /// 正解では同じシリーズなのに、別の組(または組なし)にした例。
        public var missedPairs: [(LabeledBook, LabeledBook)] = []

        public var precision: Double { predictedPairs == 0 ? 0 : Double(correctPairs) / Double(predictedPairs) }
        public var recall: Double { truePairs == 0 ? 0 : Double(correctPairs) / Double(truePairs) }
    }

    public static func load(_ url: URL) throws -> [LabeledBook] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            try? decoder.decode(LabeledBook.self, from: Data($0.utf8))
        }
    }

    /// - Parameter nameFor: 候補の組からシリーズ名を決める(規則の名前、切り方を変えた名前など)。
    public static func score(_ labeled: [LabeledBook], grouper: SeriesGrouper, examples: Int = 0,
                             nameFor: (SeriesGroup) -> String = { $0.ruleName }) -> Score {
        let files = labeled.enumerated().map { i, b in
            BookFile(path: "/corpus/\(i)", relativePath: "\(i)", baseName: "[\(b.author)] \(b.title)", fileExtension: "cbz")
        }
        let books = BookScanner.proposals(from: files, engine: grouper.engine)
        let groups = grouper.group(books)
        var predicted: [Int: Int] = [:]  // 本の id → 組の id
        var name: [Int: String] = [:]
        for g in groups {
            for id in g.memberIDs { predicted[id] = g.id; name[id] = nameFor(g) }
        }
        var score = Score()
        score.books = labeled.count
        score.authors = Set(books.map(\.circleKey)).count
        let norm: (String) -> [Character] = { grouper.engine.text.comparable($0).key }
        let truthKey = labeled.map { norm($0.series) }
        let seriesSize = Dictionary(grouping: books.indices, by: { "\(books[$0].circleKey)\u{1}\(String(truthKey[$0]))" })
            .mapValues(\.count)
        for (_, idx) in Dictionary(grouping: books.indices, by: { books[$0].circleKey }) {
            for a in 0..<idx.count {
                for b in (a + 1)..<idx.count {
                    let i = idx[a], j = idx[b]
                    let same = truthKey[i] == truthKey[j]
                    let pred = predicted[books[i].id] != nil && predicted[books[i].id] == predicted[books[j].id]
                    if same { score.truePairs += 1 }
                    if pred { score.predictedPairs += 1 }
                    if same && pred { score.correctPairs += 1 }
                    if pred && !same && score.falsePairs.count < examples, Int.random(in: 0..<50) == 0 {
                        score.falsePairs.append((labeled[i], labeled[j]))
                    }
                    if same && !pred && score.missedPairs.count < examples, Int.random(in: 0..<5) == 0 {
                        score.missedPairs.append((labeled[i], labeled[j]))
                    }
                }
            }
        }
        for i in books.indices where seriesSize["\(books[i].circleKey)\u{1}\(String(truthKey[i]))", default: 0] >= 2 {
            score.namedBooks += 1
            if let n = name[books[i].id], norm(n) == truthKey[i] { score.nameMatches += 1 }
        }
        return score
    }
}

/// シリーズ名の切り方の候補(比較のため)。
public enum SeriesNaming {
    /// 共通部分の最初の区切り(空白・記号・数字)の手前で切る。2 文字未満になるなら切らない。
    public static func firstCut(_ name: String, minLength: Int = 2, engine: RuleEngine = .builtin) -> String {
        for (i, ch) in name.enumerated() where i >= minLength && engine.text.isBoundary(ch) {
            return engine.text.trimSeriesName(String(name.prefix(i)))
        }
        return name
    }
}
