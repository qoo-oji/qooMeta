import Foundation

/// 規則から作った処理の道具一式(比べ方・巻の読み方・印・総集編・英単語の辞書)。
///
/// 処理の各所は、グローバルな状態から規則を読まず、これを値で受け取る(api.md「方針」の 1)。同じ規則でも、例ごとに
/// 方針を変えて確かめられるように、また 1 つのプロセスで別々の規則を並べて使えるように。作ったあとは変わらないので、
/// スレッドをまたいで共有してよい。正規表現の組み立ては 1 度だけ行う。
public struct RuleEngine: Sendable {
    public let rules: CompiledRules
    let text: TextRules
    let volumes: VolumeExtractor
    let markers: EditionMarkers
    let compilation: Compilation
    let english: EnglishWords

    /// - Parameter englishWords: 規則が `"english"` で指す辞書。nil なら、その条件は働かない
    ///   (CompiledRules.compile に辞書の名前を渡さなかったときと同じ)。
    public init(rules: CompiledRules, englishWords: EnglishWords? = nil) {
        self.rules = rules
        text = TextRules(rules.series)
        volumes = VolumeExtractor(rules.series.volume, text: text)
        markers = EditionMarkers(rules.series.editions)
        compilation = Compilation(rules.series.compilation, text: text)
        english = englishWords ?? EnglishWords(words: [])
    }

    /// 同梱の既定値と、macOS の英単語の一覧で作ったもの。
    public static let builtin = RuleEngine(rules: .builtin, englishWords: .system)
}
