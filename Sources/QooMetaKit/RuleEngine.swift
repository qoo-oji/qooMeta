import Foundation

/// 規則と語彙から作った処理の道具一式(比べ方・巻の読み方・印・総集編・ファイル名の読み方・英単語の辞書)。
///
/// 処理の各所は、グローバルな状態から規則を読まず、これを値で受け取る(api.md「方針」の 1)。同じ規則でも、例ごとに
/// 方針を変えて確かめられるように、また 1 つのプロセスで別々の規則を並べて使えるように。作ったあとは変わらないので、
/// スレッドをまたいで共有してよい。正規表現の組み立ては 1 度だけ行う。
struct RuleEngine: Sendable {
    let rules: CompiledRules
    let vocabulary: Vocabulary
    let text: TextRules
    let volumes: VolumeExtractor
    let markers: EditionMarkers
    let compilation: Compilation
    let english: EnglishWords
    let parser: QooLibraryNameParser

    init(rules: CompiledRules, vocabulary: Vocabulary) {
        self.rules = rules
        self.vocabulary = vocabulary
        text = TextRules(rules.series)
        volumes = VolumeExtractor(rules.series.volume, text: text)
        markers = EditionMarkers(rules.series.editions)
        compilation = Compilation(rules.series.compilation, text: text)
        english = EnglishWords(vocabulary.dictionaries["english"])
        // フォーマットは組み立てのときに確かめてあるので、ここでは失敗しない。
        parser = try! QooLibraryNameParser(mediaTypes: vocabulary.genres, rules: rules.formats)
    }
}
