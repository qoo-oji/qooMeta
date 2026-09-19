import Foundation

/// 一般的な英単語かどうか。macOS に標準で入っている単語の一覧(`/usr/share/dict/words`、Webster 第 2 版)で引く。
///
/// 使い道は 1 つ: **ありふれた英語だけでできたタイトル**どうしを、
/// 先頭の 1 語が一致しただけでシリーズにしないため(利用者の指摘)。一覧が無い環境では、どの語も一般語と
/// みなさない(組を作る側に倒す。これまでと同じ動き)。
public struct EnglishWords: Sendable {
    let words: Set<String>

    public init(words: some Sequence<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    /// 規則は辞書を名前(`"english"`)で指すだけで、パスを持たない(規則ファイルから利用側のファイルを読ませないため)。
    /// 実体の置き場所はここで決める(roadmap 段階 1 で、読み込み口を本体の外のモジュールへ移す)。
    public static let path = "/usr/share/dict/words"

    public static var isAvailable: Bool { FileManager.default.isReadableFile(atPath: path) }

    /// macOS の単語の一覧(無ければ nil)。大きい(約 24 万語)ので 1 度だけ読む。
    public static let system: EnglishWords? = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return EnglishWords(words: text.split(separator: "\n").map(String.init))
    }()

    /// 一覧は語形変化をほとんど持たないので、よくある語尾(複数形・過去形・進行形)を外しても引く。
    public func isCommon(_ token: String) -> Bool {
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
    public func isCommonEnglishOnly(_ title: String) -> Bool {
        let tokens = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy(isCommon)
    }
}
