import Foundation

/// 名前を比べるための形。表示用の元の文字列と、比較用の文字列の対応を保つ。
///
/// 比較用の形は NFKC(全角英数・半角カナを揃える)+ 小文字 + 区切り記号と空白を落としたもの。
/// 「タイトルの前半が共通」を見るとき、空白や `~` `-` の有無・全角半角の違いで
/// 共通部分が途切れないようにするため。
///
/// `originalEnd` は「比較用の i 文字目までが、元の文字列のどこまでに当たるか」。
/// 比較用の形で求めた共通部分の長さを、元の表記のシリーズ名へ戻すのに使う。
public struct ComparableText: Sendable, Equatable {
    public let original: String
    public let key: [Character]
    /// key[i] の元になった文字の、original での終わりの位置(Character 単位のオフセット)。
    public let originalEnd: [Int]

    public init(_ original: String) {
        self.original = original
        var key: [Character] = []
        var ends: [Int] = []
        for (offset, ch) in original.enumerated() {
            let folded = String(ch).precomposedNFKC.lowercased()
            for f in folded where !TextRules.isIgnoredInComparison(f) {
                let f = TextRules.variantFolding[f] ?? f
                key.append(f)
                ends.append(offset + 1)
            }
        }
        self.key = key
        self.originalEnd = ends
    }

    /// 比較用の先頭 `length` 文字に当たる元の文字列。
    ///
    /// 閉じ括弧は比較用の形では飛ばすので、そのままだと「【X】…」の共通部分が「【X」で切れる(利用者の指摘)。
    /// 開いたままの括弧があれば、直後に続く対応する閉じ括弧までを含める。
    public func originalPrefix(keyLength length: Int) -> String {
        guard length > 0 else { return "" }
        let end = originalEnd[min(length, originalEnd.count) - 1]
        let chars = Array(original)
        var prefix = Array(chars[..<end])
        var i = end
        while i < chars.count, let open = TextRules.closingToOpening[chars[i]],
              prefix.filter({ $0 == open }).count > prefix.filter({ $0 == chars[i] }).count {
            prefix.append(chars[i])
            i += 1
        }
        // 直後の「!」「?」も名前の一部として含める(利用者の指摘)。
        // 比較用の形では飛ばしているので、含めないと名前が「！」の手前で切れる。
        while i < chars.count, "!?！？".contains(chars[i]) {
            prefix.append(chars[i])
            i += 1
        }
        return String(prefix)
    }

    /// 比較用の先頭 `length` 文字より後ろの元の文字列。
    public func originalRemainder(afterKeyLength length: Int) -> String {
        guard length > 0 else { return original }
        let end = originalEnd[min(length, originalEnd.count) - 1]
        return String(original.dropFirst(end))
    }
}

public enum TextRules {
    /// 比較のときに無視する文字(空白と、タイトルの飾りによく使われる記号)。
    static let ignoredInComparison: Set<Character> = [
        " ", "\u{3000}", "\t", "~", "〜", "～", "-", "‐", "―", "・", "･", "!", "?", ".", "。", "、", ",",
        "「", "」", "『", "』", "【", "】", "<", ">", "〈", "〉", "《", "》", "♪", "☆", "★", "♡", "♥", "…", ":", "：",
        "'", "\"", "“", "”", "’",
    ]

    /// 比較のときに同じ字とみなす異体字(左 → 右)。NFKC では揃わない。表記ゆれでシリーズが割れた実例
    /// (1 巻だけ「凜」、2 巻以降が「凛」)から足した。書き出す名前の表記は変えない(比較用の形にだけ使う)。
    static let variantFolding: [Character: Character] = [
        "凜": "凛", "髙": "高", "﨑": "崎", "嵜": "崎", "邊": "辺", "邉": "辺", "澤": "沢", "濱": "浜", "嶋": "島",
        "櫻": "桜", "瀨": "瀬", "國": "国", "廣": "広", "眞": "真", "齋": "斎", "齊": "斉", "德": "徳", "惠": "恵",
        "晝": "昼", "戀": "恋", "藝": "芸", "體": "体", "與": "与", "舘": "館", "槇": "槙", "冨": "富", "桒": "桑",
    ]

    /// 長音記号「ー」は語の一部なので、ダッシュ類と違って落とさない。
    static func isIgnoredInComparison(_ ch: Character) -> Bool {
        ignoredInComparison.contains(ch)
    }

    /// 閉じ括弧 → 開き括弧。
    static let closingToOpening: [Character: Character] = [
        "】": "【", "」": "「", "』": "『", "》": "《", "〉": "〈", ")": "(", "）": "（", "]": "[", "］": "［", ">": "<",
    ]

    /// シリーズ名の末尾に残ると不自然な文字(区切りの途中で切れたときに落とす)。
    static let trailingTrim: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.insert(charactersIn: "~〜～-‐―・･:：、,。.「『【<〈《(（")
        return set
    }()

    /// 語の区切りとみなす文字(この直前で切れた共通部分は「きれいな切れ目」)。
    static func isBoundary(_ ch: Character) -> Bool {
        if ch.isWhitespace || ch.isNumber { return true }
        return "~〜～-‐―・･!?！？.。、,:：「」『』【】<>〈〉《》()（）♪☆★♡♥…#＃".contains(ch)
    }

    /// 表示用の整え方。**元の表記(全角・半角)は変えない**(書き出す値は利用者のファイル名の表記に従う)。
    /// 空白の連続を 1 つにし、前後の空白を落とし、合成済みの形(NFC)に揃えるだけ。
    public static func normalizeDisplay(_ s: String) -> String {
        let n = s.precomposedStringWithCanonicalMapping
        let collapsed = n.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// シリーズ名の**末尾だけ**から区切りの記号を落とす。`trimmingCharacters(in:)` は前後の両方を削るので使わない
    /// (先頭の「【」まで削っていた。利用者の指摘)。
    static func trimSeriesName(_ s: String) -> String {
        var scalars = Substring(s.trimmingCharacters(in: .whitespaces)).unicodeScalars
        while let last = scalars.last, trailingTrim.contains(last) { scalars.removeLast() }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        // 末尾の 1 語が、後ろに付く名前を導く語(「side」「part」など)なら外す。「X side A」「X side B」の
        // 共通部分は「X side」だが、シリーズ名は「X」(利用者の指摘)。
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if words.count >= 2, let last = words.last, labelIntroducers.contains(String(last).precomposedNFKC.lowercased()) {
            return trimSeriesName(words.dropLast().joined(separator: " "))
        }
        return trimmed
    }

    /// 後ろに付く名前を導く語(英語の区切り語)。シリーズ名の末尾に残ったときだけ外す。
    static let labelIntroducers: Set<String> = [
        "side", "part", "episode", "ep", "chapter", "act", "phase", "stage", "season", "route", "file", "case",
        "vol", "vol.", "volume", "ver", "ver.", "version", "no", "no.", "#", "第", "その",
    ]
}

extension String {
    var precomposedNFKC: String { precomposedStringWithCompatibilityMapping }
}
