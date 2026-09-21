import Foundation

/// 名前を比べるための形。表示用の元の文字列と、比較用の文字列の対応を保つ。
///
/// 比較用の形は NFKC(全角英数・半角カナを揃える)+ 小文字 + 区切り記号と空白を落としたもの。
/// 「タイトルの前半が共通」を見るとき、空白や `~` `-` の有無・全角半角の違いで
/// 共通部分が途切れないようにするため。
///
/// `originalEnd` は「比較用の i 文字目までが、元の文字列のどこまでに当たるか」。
/// 比較用の形で求めた共通部分の長さを、元の表記のシリーズ名へ戻すのに使う。
struct ComparableText: Sendable, Equatable {
    let original: String
    /// 元の表記を文字に分けたもの。切れ目を見るたびに作り直さない(`isCleanCut` は 1 つのタイトルに何十回も呼ばれる)。
    let originalCharacters: [Character]
    let key: [Character]
    /// key[i] の元になった文字の、original での終わりの位置(Character 単位のオフセット)。
    let originalEnd: [Int]
    /// 比べ方と名前の整え方(規則から作ったもの)。
    let rules: TextRules

    static func == (a: ComparableText, b: ComparableText) -> Bool {
        a.original == b.original && a.key == b.key && a.originalEnd == b.originalEnd
    }

    init(_ original: String, rules: TextRules) {
        self.original = original
        self.rules = rules
        let characters = Array(original)
        var key: [Character] = []
        var ends: [Int] = []
        key.reserveCapacity(characters.count)
        ends.reserveCapacity(characters.count)
        for (offset, ch) in characters.enumerated() {
            if let same = Self.alreadyFolded(ch), let scalar = same.unicodeScalars.first?.value {
                // 1 つの符号でできた文字は、符号の番号で引く(文字のままだと、1 文字ごとに文字列としてハッシュを取る)。
                if !rules.ignoredScalars.contains(scalar) {
                    key.append(rules.variantScalars.isEmpty ? same : rules.variantScalars[scalar] ?? same)
                    ends.append(offset + 1)
                }
                continue
            }
            let folded = String(ch).precomposedNFKC.lowercased()
            for f in folded where !rules.isIgnoredInComparison(f) {
                let f = rules.variantFolding[f] ?? f
                key.append(f)
                ends.append(offset + 1)
            }
        }
        originalCharacters = characters
        self.key = key
        self.originalEnd = ends
    }

    /// 揃えても変わらないと分かっている文字は、そのまま(英字は小文字に)返す。それ以外は nil(ふつうの道で揃える)。
    ///
    /// 揃える道は 1 文字ごとに Foundation を往復するので、名前の比べる形を作るのが計算の 3 割を占めていた
    /// (2026-09-21 の計測)。題名の文字のほとんどは、揃えても変わらない: ASCII、ひらがな・カタカナ(合成済みの 1 字)、漢字。
    /// **変わりうる字は入れない**(半角カナ・全角英数・互換漢字・濁点の結合文字・「ヿ」「゛」など)。
    static func alreadyFolded(_ ch: Character) -> Character? {
        let scalars = ch.unicodeScalars
        guard let first = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex else { return nil }
        switch first.value {
        case 0x41...0x5A: return Character(UnicodeScalar(UInt8(first.value) + 0x20))
        case 0x20...0x40, 0x5B...0x7E: return ch
        case 0x3041...0x3096, 0x309D...0x309E, 0x30A1...0x30FA, 0x30FC...0x30FE, 0x4E00...0x9FFF: return ch
        default: return nil
        }
    }

    /// 比較用の先頭 `length` 文字に当たる元の文字列。
    ///
    /// 閉じ括弧は比較用の形では飛ばすので、そのままだと「【X】…」の共通部分が「【X」で切れる(利用者の指摘)。
    /// 開いたままの括弧があれば、直後に続く対応する閉じ括弧までを含める。
    func originalPrefix(keyLength length: Int) -> String {
        guard length > 0 else { return "" }
        let end = originalEnd[min(length, originalEnd.count) - 1]
        let chars = originalCharacters
        var prefix = Array(chars[..<end])
        var i = end
        while i < chars.count, let open = rules.closingToOpening[chars[i]],
              prefix.filter({ $0 == open }).count > prefix.filter({ $0 == chars[i] }).count {
            prefix.append(chars[i])
            i += 1
        }
        // 直後の「!」「?」も名前の一部として含める(利用者の指摘)。
        // 比較用の形では飛ばしているので、含めないと名前が「！」の手前で切れる。
        while i < chars.count, rules.keepFollowing.contains(chars[i]) {
            prefix.append(chars[i])
            i += 1
        }
        return String(prefix)
    }

    /// 比較用の先頭 `length` 文字より後ろの元の文字列。
    func originalRemainder(afterKeyLength length: Int) -> String {
        guard length > 0 else { return original }
        let end = originalEnd[min(length, originalEnd.count) - 1]
        // 分けてある文字から作る(文字列を頭から数え直さない。1 つのタイトルに、切れ目の数だけ呼ばれる)。
        return String(originalCharacters[end...])
    }
}

/// 比べ方と、シリーズ名の整え方(series-rules.json の compare と naming から作る)。作ったあとは変わらない。
final class TextRules: Sendable {
    /// 比較のときに無視する文字(空白と、タイトルの飾りによく使われる記号)。compare.ignored。
    let ignoredInComparison: Set<Character>
    /// 比較のときに同じ字とみなす異体字(左 → 右)。NFKC では揃わない。表記ゆれでシリーズが割れた実例
    /// (1 巻だけ異体字)から始めた。書き出す名前の表記は変えない(比較用の形にだけ使う)。compare.variants。
    let variantFolding: [Character: Character]
    /// 上の 2 つのうち、1 つの符号でできた文字の分(符号の番号で引く。`ComparableText.init` の速い道が使う)。
    let ignoredScalars: Set<UInt32>
    let variantScalars: [UInt32: Character]
    /// 閉じ括弧 → 開き括弧。naming.includeClosingBrackets(止めていれば空)。
    let closingToOpening: [Character: Character]
    /// シリーズ名の末尾に残ると不自然な文字(区切りの途中で切れたときに落とす)。naming.trimTrailing。
    /// 巻の前の区切り(VolumeExtractor.leadingSeparators)にも使うので、規則を止めてもここは空にしない。
    let trailingTrim: CharacterSet
    /// シリーズ名の末尾から落とす文字(規則 trimTrailing を止めていれば空白だけ)。
    let seriesNameTrim: CharacterSet
    /// 共通部分の直後にあれば名前に含める文字(「!」「?」)。naming.includeFollowing。
    let keepFollowing: Set<Character>
    /// 語の区切りとみなす記号。compare.boundaries。
    let boundaryCharacters: Set<Character>
    /// 後ろに付く名前を導く語。シリーズ名の末尾に残ったときだけ外す。naming.dropLastWord。
    let labelIntroducers: Set<String>

    init(_ rules: SeriesRules) {
        func pairs(_ map: [String: String]) -> [Character: Character] {
            Dictionary(map.compactMap { k, v in
                guard let a = k.first, let b = v.first, k.count == 1, v.count == 1 else { return nil }
                return (a, b)
            }, uniquingKeysWith: { a, _ in a })
        }
        ignoredInComparison = Set(rules.compare.ignoredCharacters)
        variantFolding = pairs(rules.compare.variantKanji)
        ignoredScalars = Set(ignoredInComparison.compactMap { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first?.value : nil })
        variantScalars = Dictionary(variantFolding.compactMap { key, value in
            key.unicodeScalars.count == 1 ? key.unicodeScalars.first.map { ($0.value, value) } : nil
        }, uniquingKeysWith: { a, _ in a })
        closingToOpening = pairs(rules.naming.brackets)
        var trim = CharacterSet.whitespaces
        trim.insert(charactersIn: rules.naming.trimTrailing)
        trailingTrim = trim
        seriesNameTrim = rules.naming.trimTrailingEnabled ? trim : .whitespaces
        keepFollowing = Set(rules.naming.keepFollowing)
        boundaryCharacters = Set(rules.compare.boundaryCharacters)
        labelIntroducers = Set(rules.naming.labelIntroducers.map { $0.lowercased() })
    }

    /// 比べるための形。**同じ計算の中では、同じ文字列から 1 度だけ作る**(`ComputationCache`)。
    func comparable(_ s: String) -> ComparableText {
        guard let cache = ComputationCache.current, cache.owner == ObjectIdentifier(self) else {
            return ComparableText(s, rules: self)
        }
        if let made = cache.comparable[s] { return made }
        let made = ComparableText(s, rules: self)
        if cache.comparable.count < ComputationCache.limit { cache.comparable[s] = made }
        return made
    }

    /// 比べるための形の文字列(キー)。
    func key(_ s: String) -> String { String(comparable(s).key) }

    /// 長音記号「ー」は語の一部なので、ダッシュ類と違って落とさない。
    func isIgnoredInComparison(_ ch: Character) -> Bool {
        ignoredInComparison.contains(ch)
    }

    /// 語の区切りとみなす文字(この直前で切れた共通部分は「きれいな切れ目」)。
    func isBoundary(_ ch: Character) -> Bool {
        // ASCII は表を引かずに決める(文字の性質を引くのは重く、切れ目の判定は 1 冊に何十回も走る)。
        if let ascii = ch.asciiValue {
            if ascii == 0x20 || (0x09...0x0D).contains(ascii) || (0x30...0x39).contains(ascii) { return true }
            return boundaryCharacters.contains(ch)
        }
        if ch.isWhitespace || ch.isNumber { return true }
        return boundaryCharacters.contains(ch)
    }

    /// 表示用の整え方。**元の表記(全角・半角)は変えない**(書き出す値は利用者のファイル名の表記に従う)。
    /// 空白の連続を 1 つにし、前後の空白を落とし、合成済みの形(NFC)に揃えるだけ。規則には依らない。
    static func normalizeDisplay(_ s: String) -> String {
        let n = s.precomposedNFC
        let collapsed = n.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// シリーズ名の**末尾だけ**から区切りの記号を落とす。`trimmingCharacters(in:)` は前後の両方を削るので使わない
    /// (先頭の「【」まで削っていた。利用者の指摘)。
    func trimSeriesName(_ s: String) -> String {
        var scalars = Substring(s.trimmingCharacters(in: .whitespaces)).unicodeScalars
        while let last = scalars.last, seriesNameTrim.contains(last) { scalars.removeLast() }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        // 末尾の 1 語が、後ろに付く名前を導く語(「side」「part」など)なら外す。「X side A」「X side B」の
        // 共通部分は「X side」だが、シリーズ名は「X」(利用者の指摘)。
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if words.count >= 2, let last = words.last, labelIntroducers.contains(String(last).precomposedNFKC.lowercased()) {
            return trimSeriesName(words.dropLast().joined(separator: " "))
        }
        return trimmed
    }
}

extension String {
    /// 揃えた形(NFKC)。**揃えても変わらないと分かっている文字だけの文字列は、そのまま返す**
    /// ―― 揃えるには Foundation を往復する。巻の読み手は、1 つのタイトルの切れ目ごとにこれを呼ぶ。
    var precomposedNFKC: String { isAlreadyNormalized ? self : precomposedStringWithCompatibilityMapping }

    /// 合成済みの形(NFC)。同じ近道。
    var precomposedNFC: String { isAlreadyNormalized ? self : precomposedStringWithCanonicalMapping }

    /// どの符号も、揃えても(NFC でも NFKC でも)変わらず、隣と合成もしないと分かっている範囲にあるか。
    /// ASCII、ひらがな・カタカナ(合成済みの 1 字)、長音符、漢字。**結合文字(濁点の U+3099 など)・全角英数・半角カナ・
    /// 互換漢字・全角の空白は範囲の外**なので、1 つでもあれば、ふつうの道で揃える。
    var isAlreadyNormalized: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x00...0x7E, 0x3041...0x3096, 0x309D...0x309E, 0x30A1...0x30FA, 0x30FC...0x30FE, 0x4E00...0x9FFF: continue
            default: return false
            }
        }
        return true
    }
}
