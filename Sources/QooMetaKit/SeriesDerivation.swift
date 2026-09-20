import Foundation

/// qooMeta の欄(`BookMetadata`)から、中核でシリーズと巻を導く。
///
/// 段階 5 で画面の骨組みに中核を仮につなぐための入口(docs/roadmap.md)。欄から中核の入口(`CoreBook`)への詰め方は、
/// 段階 6 で前段を差し替えるときの形と同じ: 書き手は著者の並びの先頭(無ければ空)、ジャンル・原作はその値、
/// 比べるタイトルはタイトルに `compareTitle` をかけたもの。
public struct SeriesDerivation: Sendable {
    public struct Book: Sendable, Hashable {
        public var id: String
        public var metadata: BookMetadata
        public var confirmation: Confirmation

        public init(id: String, metadata: BookMetadata, confirmation: Confirmation = .none) {
            self.id = id
            self.metadata = metadata
            self.confirmation = confirmation
        }
    }

    /// 1 冊の結果。シリーズに入らなければ `seriesID` と `series` は nil。
    public struct Result: Sendable, Hashable {
        public var seriesID: SeriesID?
        public var series: String?
        public var volume: Volume?
    }

    let engine: RuleEngine

    public init(rules: CompiledRules, dictionaries: [String: WordSet]) {
        engine = RuleEngine(rules: rules, dictionaries: dictionaries)
    }

    /// 入力の順を保って計算する(同じ入力なら毎回同じ結果)。ID が重なった本は後のものを捨てる。
    public func derive(_ books: [Book]) -> [String: Result] {
        var seen = Set<String>()
        let cores = books.enumerated().compactMap { order, book -> CoreBook? in
            guard seen.insert(book.id).inserted else { return nil }
            return core(book, order: order)
        }
        var results: [String: Result] = [:]
        for (unitKey, members) in Dictionary(grouping: cores, by: engine.unitKey) {
            let unit = engine.computeUnit(members)
            let names = Dictionary(unit.series.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
            for member in members {
                let book = unit.books[member.id]
                let key = book?.seriesKey
                results[member.id] = Result(seriesID: key.map { engine.seriesID(unitKey, $0) }, series: key.flatMap { names[$0] },
                                            volume: book?.volume?.volume)
            }
        }
        return results
    }

    func core(_ book: Book, order: Int) -> CoreBook {
        let m = book.metadata
        let title = TextRules.normalizeDisplay(m.title)
        let compared = engine.compareTitle(title)
        return CoreBook(id: book.id, order: order, title: title, compareTitle: compared.text,
                        writerKey: engine.text.key(m.authors.first ?? ""), genre: m.genre,
                        source: m.source, hasEditionMarks: !compared.editions.isEmpty,
                        hasSourceMarks: !compared.sources.isEmpty, confirmation: book.confirmation,
                        volumeHead: engine.volumeHead(compareTitle: compared.text))
    }
}
