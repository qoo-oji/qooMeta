import Foundation

/// 複数の本の確定した内容を、まとめて組み立てる(docs/api.md「まとめて編集」)。**値を返すだけ**で、何も保存しない
/// (保存と取り消しは利用側)。返した内容を `ProposalIndex.apply`(`BookInput.confirmation` の更新)に渡すと、錨の効果で
/// ほかの本の提案も変わる。確定の前に波及を見せたいときは `ProposalIndex.preview` を使う。
///
/// `current` は今の確定した内容。渡すと、変えない欄(確定した欄の値・巻)を保つ。
public enum BulkEdit {
    public struct Numbering: Sendable, Hashable {
        public enum Padding: Sendable, Hashable {
            /// そのシリーズの今の表記に合わせる(「02」「03」なら 2 桁)。
            case matchSeries
            case none
            case width(Int)
        }

        public var start = 1
        public var step = 1
        public var padding: Padding = .matchSeries

        public init(start: Int = 1, step: Int = 1, padding: Padding = .matchSeries) {
            self.start = start
            self.step = step
            self.padding = padding
        }
    }

    public enum Order: Sendable, Hashable {
        /// タイトル順(数字は数として比べる)。
        case title
        /// ファイル名順。
        case name
        /// 日付順(利用側が渡す。本体はファイルを見ない)。日付の無い本は後ろ。
        case date
        /// 今の巻の順。巻の無い本は後ろ。
        case currentVolume
    }

    /// 選んだ本のタイトルから、シリーズ名の候補を返す(共通部分を語の切れ目まで縮め、規則の名前の整え方に通したもの。
    /// 無ければ nil)。版・入手経路の印は除いて比べる。1 冊なら、「タイトル + 巻」の頭か、タイトルそのもの。
    public static func suggestedSeriesName(for ids: [String], in set: ProposalSet, rules: CompiledRules) -> String? {
        let engine = RuleEngine(rules: rules, vocabulary: Vocabulary())
        let titles = ids.compactMap { set[$0] }.map { engine.text.comparable(engine.markers.split($0.parsed.title).base) }
        guard let first = titles.first else { return nil }
        var length = first.key.count
        if titles.count == 1 {
            length = SeriesGrouper(engine: engine).volumeHeadLength(first, minLength: 1) ?? length
        } else {
            for t in titles.dropFirst() { length = min(length, SeriesGrouper.commonPrefixLength(first.key, t.key)) }
            // 語の途中で切れるなら、全員が語の切れ目で切れるところまで縮める。
            while length > 0, !titles.allSatisfy({ SeriesGrouper.isCleanCut($0, at: length) }) { length -= 1 }
        }
        guard length > 0 else { return nil }
        let name = engine.text.trimSeriesName(first.originalPrefix(keyLength: length))
        return name.isEmpty ? nil : name
    }

    /// 選んだ本に同じシリーズ名を設定する(巻は今の値を保つ)。
    public static func setSeries(_ name: String, for ids: [String], in set: ProposalSet,
                                 current: [String: Confirmation] = [:]) -> [String: Confirmation] {
        ids.reduce(into: [:]) { result, id in
            guard set[id] != nil else { return }
            result[id] = .series(name: name, volume: volumeText(id, set, current), fields: fields(id, current))
        }
    }

    /// 欄の値をまとめて設定する(nil の欄は触らない)。
    public static func setFields(_ fields: ConfirmedFields, for ids: [String], in set: ProposalSet,
                                 current: [String: Confirmation] = [:]) -> [String: Confirmation] {
        ids.reduce(into: [:]) { result, id in
            guard set[id] != nil else { return }
            var merged = Self.fields(id, current)
            if let v = fields.circle { merged.circle = v }
            if let v = fields.authors { merged.authors = v }
            if let v = fields.title { merged.title = v }
            if let v = fields.relation { merged.relation = v }
            if let v = fields.genre { merged.genre = v }
            result[id] = switch current[id] ?? .none {
            case .none, .fields: .fields(merged)
            case .series(let name, let volume, _): .series(name: name, volume: volume, fields: merged)
            case .notInSeries: .notInSeries(fields: merged)
            }
        }
    }

    /// 並べた順に、上から巻を振る。シリーズ名は今の値(無ければ seriesName。どちらも無ければその本は何もしない)。
    public static func numberSequentially(_ orderedIDs: [String], in set: ProposalSet, seriesName: String? = nil,
                                          numbering: Numbering = .init(),
                                          current: [String: Confirmation] = [:]) -> [String: Confirmation] {
        var result: [String: Confirmation] = [:]
        for (i, id) in orderedIDs.enumerated() {
            guard let book = set[id], let name = currentSeriesName(id, set, current) ?? seriesName else { continue }
            let number = numbering.start + i * numbering.step
            let width: Int = switch numbering.padding {
            case .none: 0
            case .width(let w): w
            case .matchSeries: seriesPadding(book, set)
            }
            let digits = String(abs(number))
            let text = (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
            result[id] = .series(name: name, volume: text, fields: fields(id, current))
        }
        return result
    }

    /// シリーズから外す。
    public static func removeFromSeries(_ ids: [String], in set: ProposalSet,
                                        current: [String: Confirmation] = [:]) -> [String: Confirmation] {
        ids.reduce(into: [:]) { result, id in
            guard set[id] != nil else { return }
            result[id] = .notInSeries(fields: fields(id, current))
        }
    }

    /// 確定を取り消して、提案に戻す。
    public static func revertToProposal(_ ids: [String]) -> [String: Confirmation] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Confirmation.none) })
    }

    /// 提案をそのまま確定する(欄・シリーズ・巻)。シリーズに入っていない本は「シリーズではない」と確定する。
    public static func acceptProposals(_ ids: [String], in set: ProposalSet) -> [String: Confirmation] {
        ids.reduce(into: [:]) { result, id in
            guard let book = set[id] else { return }
            let p = book.parsed
            let fields = ConfirmedFields(circle: p.circle, authors: p.authors, title: p.title, relation: p.relation, genre: p.genre)
            if let series = book.seriesID.flatMap({ set.series($0) }) {
                result[id] = .series(name: series.name, volume: book.volume?.text, fields: fields)
            } else {
                result[id] = .notInSeries(fields: fields)
            }
        }
    }

    /// 巻だけを消す(「巻は無い」と確定する。シリーズは今の値を保つ)。シリーズに入っていない本は何もしない。
    public static func clearVolumes(_ ids: [String], in set: ProposalSet,
                                    current: [String: Confirmation] = [:]) -> [String: Confirmation] {
        ids.reduce(into: [:]) { result, id in
            guard let name = currentSeriesName(id, set, current) else { return }
            result[id] = .series(name: name, volume: "", fields: fields(id, current))
        }
    }

    /// 並べ方の候補(連番の前の並べ替え)。同じ値の本は ID の順。
    public static func sorted(_ ids: [String], by order: Order, in set: ProposalSet, dates: [String: Date] = [:]) -> [String] {
        func natural(_ a: String, _ b: String) -> ComparisonResult {
            a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive])
        }
        return ids.sorted { a, b in
            let x = set[a], y = set[b]
            let result: ComparisonResult
            switch order {
            case .title: result = natural(x?.parsed.title ?? "", y?.parsed.title ?? "")
            case .name: result = natural(x?.name ?? "", y?.name ?? "")
            case .date:
                switch (dates[a], dates[b]) {
                case let (p?, q?): result = p == q ? .orderedSame : (p < q ? .orderedAscending : .orderedDescending)
                case (_?, nil): result = .orderedAscending
                case (nil, _?): result = .orderedDescending
                default: result = .orderedSame
                }
            case .currentVolume:
                switch (x?.volume?.sortKey, y?.volume?.sortKey) {
                case let (p?, q?): result = p == q ? .orderedSame : (p < q ? .orderedAscending : .orderedDescending)
                case (_?, nil): result = .orderedAscending
                case (nil, _?): result = .orderedDescending
                default: result = .orderedSame
                }
            }
            return result == .orderedSame ? a < b : result == .orderedAscending
        }
    }

    // MARK: - 内部

    static func fields(_ id: String, _ current: [String: Confirmation]) -> ConfirmedFields {
        (current[id] ?? .none).fields
    }

    /// 今のシリーズ名(確定した名前、無ければ提案)。
    static func currentSeriesName(_ id: String, _ set: ProposalSet, _ current: [String: Confirmation]) -> String? {
        if case .series(let name, _, _) = current[id] ?? .none { return name }
        return set[id]?.seriesID.flatMap { set.series($0)?.name }
    }

    /// 今の巻の表記(確定した巻、無ければ提案。推定した巻は確定させない)。
    static func volumeText(_ id: String, _ set: ProposalSet, _ current: [String: Confirmation]) -> String? {
        if case .series(_, let volume?, _) = current[id] ?? .none { return volume }
        guard let volume = set[id]?.volume, !volume.inferred else { return nil }
        return volume.text
    }

    /// そのシリーズの今の表記のゼロ埋めの桁数(無ければ 0)。
    static func seriesPadding(_ book: BookProposal, _ set: ProposalSet) -> Int {
        guard let series = book.seriesID.flatMap({ set.series($0) }) else { return 0 }
        return series.memberIDs.compactMap { set[$0]?.volume?.text }
            .filter { $0.count > 1 && $0.hasPrefix("0") && $0.allSatisfy(\.isNumber) }
            .map(\.count).max() ?? 0
    }
}
