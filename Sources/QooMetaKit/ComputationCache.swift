import Foundation

/// 1 つの計算(1 つの単位の組み立て、1 冊の下ごしらえ)の中だけの作り置き。
///
/// 同じタイトルから、比べる形(`ComparableText`)と語の位置(`WordRules.claims`)を何度も作っていた ―― 組を作る所、
/// 巻を読む所、1 巻を推定する所、残りを巻数にする所 … がそれぞれ作り直す。手元の蔵書で測ると、比べる形が計算の 3 割、
/// 語の位置(正規表現)が 1 割強を占めていた(2026-09-21)。
///
/// **規則ごと・計算ごとに別のものを使う**: 計算の入口(`RuleEngine.scoped`)で作り、その計算のあいだだけ
/// タスクローカルで見える。計算が終われば捨てるので、冊数に比べてメモリが伸びない(全冊ぶんを持ち続けない)。
/// 1 つの計算は 1 つのスレッドで同期に走るので、錠は要らない。
final class ComputationCache: @unchecked Sendable {
    @TaskLocal static var current: ComputationCache?

    /// どの規則(`TextRules`)の作り置きか。違う規則の計算が入れ子になっても、取り違えない。
    let owner: ObjectIdentifier
    var comparable: [String: ComparableText] = [:]
    var claims: [String: [WordRules.Claim]] = [:]

    /// 覚えておく数の上限。書き手の読めない蔵書は全体が 1 つの単位になるので、上限が無いと、その計算のあいだ
    /// 全冊ぶんを抱える。越えた分は、これまでどおりその場で作る。
    static let limit = 20_000

    init(owner: ObjectIdentifier) { self.owner = owner }
}

extension RuleEngine {
    /// この計算のあいだだけ、作り置きを効かせる。
    func scoped<T>(_ body: () -> T) -> T {
        if let current = ComputationCache.current, current.owner == ObjectIdentifier(text) { return body() }
        return ComputationCache.$current.withValue(ComputationCache(owner: ObjectIdentifier(text)), operation: body)
    }
}
