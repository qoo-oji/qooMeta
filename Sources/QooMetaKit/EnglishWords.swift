import Foundation

/// 一般的な英単語かどうか。単語の一覧は利用側が渡す(macOS の一覧は QooMetaRules の SystemDictionaries.english)。
///
/// 使い道は 1 つ: **ありふれた英語だけでできたタイトル**どうしを、
/// 先頭の 1 語が一致しただけでシリーズにしないため(利用者の指摘)。一覧が無い環境では、どの語も一般語と
/// みなさない(組を作る側に倒す。これまでと同じ動き)。
struct EnglishWords: Sendable {
    /// 規則が `"english"` で指す辞書(利用側が Vocabulary で渡す)。
    let words: WordSet

    init(_ words: WordSet?) {
        self.words = words ?? WordSet([])
    }

    /// 一覧は語形変化をほとんど持たないので、よくある語尾(複数形・過去形・進行形)を外しても引く。
    func isCommon(_ token: String) -> Bool {
        let t = token.precomposedNFKC.lowercased()
        guard t.count >= 2, t.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        if words.contains(t) { return true }
        var candidates: [String] = []
        if t.hasSuffix("ies") { candidates.append(String(t.dropLast(3)) + "y") }
        if t.hasSuffix("es") { candidates.append(String(t.dropLast(2))) }
        if t.hasSuffix("s") { candidates.append(String(t.dropLast())) }
        if t.hasSuffix("ed") { candidates += [String(t.dropLast(2)), String(t.dropLast())] }
        if t.hasSuffix("ing") { candidates += [String(t.dropLast(3)), String(t.dropLast(3)) + "e"] }
        return candidates.contains { $0.count >= 2 && words.contains($0) }
    }

    /// タイトル全体が一般的な英単語だけでできているか(区切りの記号は無視する)。
    func isCommonEnglishOnly(_ title: String) -> Bool {
        let tokens = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy(isCommon)
    }
}
