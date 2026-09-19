import Foundation

/// なぜその提案になったか。`ProposalOptions.explanations` のときだけ作る。表示の言葉は含まない(符号と規則の ID)。
///
/// 「なぜこの 2 冊がシリーズにならないのか」に答えるためのもの(規則を育てる作業の中心になる問い)。
public struct Explanation: Sendable, Hashable {
    /// 効いた規則の ID(組の作り方・巻の読み手・推定・印・方針)。
    public let appliedRules: [String]
    /// 組になりかけて、ならなかった相手。
    public let nearMisses: [NearMiss]
}

public struct NearMiss: Sendable, Hashable {
    public let otherID: String
    /// タイトルの共通する先頭の長さ(比べる形で)。
    public let sharedPrefixLength: Int
    /// 組にしなかった規則("reject-single-script"、"splitByRelation"、"rejectSameWork"、"sharedPrefix" …)。
    /// "sharedPrefix" は、共通部分が短すぎる・語の途中で切れているなどで、組にする条件を満たさなかったこと。
    public let rejectedBy: String
}

extension ProposalSet {
    public func explanation(for id: String) -> Explanation? { explanations[id] }
}

/// 計算の途中で、説明の材料を書き留める(1 つの単位の計算の中だけで使う)。
final class ExplanationLog: @unchecked Sendable {
    struct Miss { let a: Int, b: Int, length: Int, rule: String }

    var applied: [Int: [String]] = [:]
    var misses: [Miss] = []

    func apply(_ rule: String, to id: Int) {
        if !(applied[id] ?? []).contains(rule) { applied[id, default: []].append(rule) }
    }

    func miss(_ a: Int, _ b: Int, length: Int, rule: String) {
        guard a != b else { return }
        misses.append(Miss(a: a, b: b, length: length, rule: rule))
    }

    /// 本(単位の中の番号)ごとの説明。組になりかけた相手は、同じ相手を 1 度だけ(いちばん長い共通部分のもの)。
    func explanations(inputIDs: [Int: String]) -> [String: Explanation] {
        var nearest: [Int: [Int: Miss]] = [:]
        for m in misses {
            for (me, other) in [(m.a, m.b), (m.b, m.a)] where (nearest[me]?[other]?.length ?? -1) < m.length {
                nearest[me, default: [:]][other] = m
            }
        }
        var result: [String: Explanation] = [:]
        for (id, inputID) in inputIDs {
            let misses = (nearest[id] ?? [:]).sorted { a, b in
                a.value.length != b.value.length ? a.value.length > b.value.length
                    : (inputIDs[a.key] ?? "") < (inputIDs[b.key] ?? "")
            }.compactMap { other, m in
                    inputIDs[other].map { NearMiss(otherID: $0, sharedPrefixLength: m.length, rejectedBy: m.rule) }
                }
            result[inputID] = Explanation(appliedRules: applied[id] ?? [], nearMisses: misses)
        }
        return result
    }
}

extension ProposalSet {
    /// ありふれた言葉の疑い: このシリーズの名前で始まるタイトルを持つ書き手の数(このシリーズの書き手を含む)。
    /// 多いほど、ありふれた言葉がたまたま一致しただけの疑いがある。単位をまたぐ情報なので提案には含めず、
    /// その時点の全体からここで数える(docs/api.md「変えた分だけ計算し直す」)。
    public func prefixCommonness(of id: SeriesID, rules: CompiledRules) -> Int {
        guard let series = series(id) else { return 0 }
        let engine = RuleEngine(rules: rules, vocabulary: Vocabulary())
        let prefix = engine.text.key(series.name)
        guard !prefix.isEmpty else { return 0 }
        var writers = Set<String>()
        for book in proposals where engine.text.key(engine.markers.split(book.parsed.title).base).hasPrefix(prefix) {
            writers.insert(engine.text.key(book.parsed.circle ?? ""))
        }
        return writers.count
    }
}
