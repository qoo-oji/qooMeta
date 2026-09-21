import Foundation

/// 規則と辞書から作った処理の道具一式(比べ方・巻の読み方・印・総集編・ファイル名の型・英単語の辞書)。
///
/// 処理の各所は、グローバルな状態から規則を読まず、これを値で受け取る(api.md「方針」の 1)。同じ規則でも、例ごとに
/// 方針を変えて確かめられるように、また 1 つのプロセスで別々の規則を並べて使えるように。作ったあとは変わらないので、
/// スレッドをまたいで共有してよい。正規表現の組み立ては 1 度だけ行う。
struct RuleEngine: Sendable {
    let rules: CompiledRules
    let text: TextRules
    let volumes: VolumeExtractor
    let markers: EditionMarkers
    let compilation: Compilation
    let english: EnglishWords
    /// 語の規則(印・総集編・巻の読み手が同じものを使う)。
    let words: WordRules

    init(rules: CompiledRules, dictionaries: [String: WordSet]) {
        self.rules = rules
        text = TextRules(rules.series)
        let words = WordRules(rules.series.editions.wordRules)
        self.words = words
        volumes = VolumeExtractor(rules.series.volume, text: text, words: words)
        markers = EditionMarkers(rules.series.editions, words: words)
        compilation = Compilation(words: words, text: text)
        english = EnglishWords(dictionaries["english"])
    }
}
