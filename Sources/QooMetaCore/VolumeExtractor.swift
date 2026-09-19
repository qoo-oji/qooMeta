import Foundation

/// シリーズ名より後ろの部分から、巻を読み取る。
///
/// **読めないものは作らない。** 番号の無いシリーズの順番を推測で埋めると、利用者には
/// 推測と事実の区別が付かなくなる。読めるのは次の形だけ:
/// - 数字(`2` `Vol.3` `ver2` `#4` `第5話` `その6` `Part 7`)。数字の直後が語なら読まない(「2人の…」は巻ではない)
/// - 漢数字(`第三話` `その二`)
/// - 「第」+ 数字 + 任意の漢字 1 字の単位(`第1幕` `第三部` `第2夜`)
/// - ローマ数字(`I` `II` `Ⅳ`。大文字だけ)
/// - 位置の語(`上` `中` `下` `前編` `中編` `後編`)。数値にはしない(Stackroom の Volume は空のまま)。
public enum VolumeExtractor {
    public struct Volume: Equatable, Sendable {
        public var text: String
        public var number: Double?
    }

    private static let numeric = try! NSRegularExpression(
        pattern: #"^(?:vol(?:ume)?\.?|ver(?:sion)?\.?|no\.?|#|第|その|part|ep\.?)?\s*(\d+(?:\.\d+)?)(?:巻|話|号|章|弾|つめ|つ目|冊目|作目|$|\s|[~\-・!?.)])"#,
        options: [.caseInsensitive])
    private static let kanji = try! NSRegularExpression(
        pattern: #"^(?:(?:第|その)([一二三四五六七八九十]+)|([一二三四五六七八九十]+)(?:巻|話|号|章))"#)
    private static let position = try! NSRegularExpression(
        pattern: #"^(前編|中編|後編|上巻|中巻|下巻|上|中|下)(?:$|\s)"#)

    /// 巻の前に付く区切り。シリーズ名の末尾から落とす記号(TextRules.trailingTrim)に加えて「!」「?」と閉じ括弧も落とす
    /// (「X! ver2」)。シリーズ名の側では「!」を落とさない(「ご懐妊!!」のような名前がある)。
    static let leadingSeparators = TextRules.trailingTrim.union(.whitespaces).union(CharacterSet(charactersIn: "!?！？】」』》〉)）]］>"))

    public static func extract(fromRemainder remainder: String) -> Volume? {
        let s = remainder.precomposedNFKC
            .trimmingCharacters(in: leadingSeparators)
        guard !s.isEmpty else { return nil }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        // 「第」が付いていれば、数字の後ろの単位は何でもよい(「第1幕」「第三部」「第2夜」)。
        if let m = ordinal.firstMatch(in: s, range: range) {
            let text = ns.substring(with: m.range(at: 1))
            let number = Double(text) ?? kanjiNumber(text).map(Double.init)
            if let number { return Volume(text: text, number: number) }
        }
        if let m = numeric.firstMatch(in: s, range: range) {
            let text = ns.substring(with: m.range(at: 1))
            return Volume(text: text, number: Double(text))
        }
        if let m = kanji.firstMatch(in: s, range: range) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let text = ns.substring(with: r)
            return Volume(text: text, number: kanjiNumber(text).map(Double.init))
        }
        if let m = roman.firstMatch(in: s, range: range) {
            let text = ns.substring(with: m.range(at: 1))
            if let n = romanNumber(text) { return Volume(text: text, number: Double(n)) }
        }
        if let m = position.firstMatch(in: s, range: range) {
            return Volume(text: ns.substring(with: m.range(at: 1)), number: nil)
        }
        return nil
    }

    /// 「第」+ 数字 + 任意の漢字 1 字の単位。
    private static let ordinal = try! NSRegularExpression(
        pattern: #"^第\s*(\d+(?:\.\d+)?|[一二三四五六七八九十]+)\s*(?:\p{Han}|$|\s|[~\-・!?.)])"#)
    private static let wholeOrdinal = try! NSRegularExpression(
        pattern: #"^第\s*(?:\d+(?:\.\d+)?|[一二三四五六七八九十]+)\s*\p{Han}?$"#)

    /// ローマ数字の巻(「X II」)。大文字だけ(NFKC で「Ⅱ」も「II」になる)。1〜39。
    private static let roman = try! NSRegularExpression(
        pattern: #"^(?:vol\.?\s*)?(X{0,3}(?:IX|IV|V?I{0,3}))(?:$|\s|[~\-・!?.)])"#)

    static func romanNumber(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0, previous = 0
        for ch in s.reversed() {
            guard let v = values[ch] else { return nil }
            total += v < previous ? -v : v
            previous = max(previous, v)
        }
        return total > 0 ? total : nil
    }

    /// 残りの部分が**巻だけ**でできているか(「21」「第3巻」「Vol.5」「上」。「#4 おまけ」は違う)。
    public static func isWholeVolume(_ remainder: String) -> Bool {
        let s = remainder.precomposedNFKC.trimmingCharacters(in: leadingSeparators)
        guard !s.isEmpty else { return false }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        if wholeVolume.firstMatch(in: s, range: range) != nil { return true }
        if wholeOrdinal.firstMatch(in: s, range: range) != nil { return true }
        // ローマ数字だけ(「II」)。
        if let m = roman.firstMatch(in: s, range: range), m.range.length == ns.length || m.range(at: 1).length == ns.length {
            return romanNumber(ns.substring(with: m.range(at: 1))) != nil
        }
        return false
    }

    private static let wholeVolume = try! NSRegularExpression(
        pattern: #"^(?:(?:vol(?:ume)?\.?|ver(?:sion)?\.?|no\.?|#|第|その|part|ep\.?)\s*)?(?:\d+(?:\.\d+)?|[一二三四五六七八九十]+)\s*(?:巻|話|号|章|集|弾|つめ|つ目|冊目|作目)?$|^(?:前編|中編|後編|上巻|中巻|下巻|上|中|下)$"#,
        options: [.caseInsensitive])

    static func kanjiNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0
        for ch in s {
            if ch == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else if let d = digits[ch] {
                current = d
            } else {
                return nil
            }
        }
        let value = total + current
        return value > 0 ? value : nil
    }
}

/// 候補の判定を本ごとの値へ反映する。
public enum ProposalFinalizer {
    /// - Parameter useAI: false なら端末内モデルの判定を無視し、規則の候補だけで決める(比較用)。
    public static func finalize(_ document: inout ProposalDocument, useAI: Bool = true) {
        var seriesByBook: [Int: String] = [:]
        var groupByBook: [Int: Int] = [:]
        for group in document.groups {
            var name = group.ruleName
            var excluded = Set<Int>()
            if useAI, let verdict = group.aiVerdict {
                guard verdict.isSeries else { continue }
                if !verdict.seriesName.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = TextRules.normalizeDisplay(verdict.seriesName)
                }
                excluded = Set(verdict.excludedIDs)
            }
            let kept = group.memberIDs.filter { !excluded.contains($0) }
            guard kept.count >= 2, !name.isEmpty else { continue }
            for id in kept { seriesByBook[id] = name; groupByBook[id] = group.id }
        }
        for i in document.books.indices {
            let series = seriesByBook[document.books[i].id] ?? ""
            document.books[i].series = series
            document.books[i].groupID = groupByBook[document.books[i].id]
            document.books[i].volumeText = ""
            document.books[i].volumeNumber = nil
            document.books[i].volumeInferred = nil
            guard !series.isEmpty else { continue }
            let title = ComparableText(document.books[i].parsed.title)
            let nameKey = ComparableText(series).key
            // シリーズ名がタイトルの前半に当たらない(モデルが言い換えた)ときは、巻を読まない。
            guard title.key.starts(with: nameKey) else { continue }
            let remainder = title.originalRemainder(afterKeyLength: nameKey.count)
            if let volume = VolumeExtractor.extract(fromRemainder: remainder) {
                document.books[i].volumeText = volume.text
                document.books[i].volumeNumber = volume.number
            }
        }
        readLeadingKanjiNumerals(&document)
        inferFirstVolumes(&document)
    }

    /// 漢数字で始まるだけの巻(「X 二〇」「X 三〇」のように、漢数字の直後に単位が無い形)を読む。
    ///
    /// 漢数字の直後に「巻」「話」などが無い形は、1 冊だけ見ると「X 三人の夜」「X 十字架」のような普通の言葉と
    /// 区別できない。**同じシリーズの中で、巻の読めない本が 2 冊以上、互いに違う漢数字で始まっているときだけ**読む
    /// (利用者の指摘。番号を言葉遊びに埋め込んだ同人誌のシリーズ)。
    static func readLeadingKanjiNumerals(_ document: inout ProposalDocument) {
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        for (_, indices) in Dictionary(grouping: seriesBooks, by: { document.books[$0].groupID ?? -1 }) {
            var found: [(index: Int, text: String, number: Int)] = []
            for i in indices where document.books[i].volumeText.isEmpty {
                let title = ComparableText(document.books[i].parsed.title)
                let name = ComparableText(document.books[i].series).key
                guard title.key.starts(with: name) else { continue }
                let remainder = title.originalRemainder(afterKeyLength: name.count)
                    .trimmingCharacters(in: VolumeExtractor.leadingSeparators)
                let digits = String(remainder.prefix { "一二三四五六七八九十".contains($0) })
                guard !digits.isEmpty, let n = VolumeExtractor.kanjiNumber(digits) else { continue }
                found.append((i, digits, n))
            }
            guard found.count >= 2, Set(found.map(\.number)).count == found.count else { continue }
            for f in found {
                document.books[f.index].volumeText = f.text
                document.books[f.index].volumeNumber = Double(f.number)
            }
        }
    }

    /// 番号の無い 1 冊を 1 巻とみなす。同人誌では 1 冊目に番号を付けず、2 冊目から「2」を付けることが多い(利用者の指摘)。
    ///
    /// 条件(同じ書き手・同じシリーズの中で): 2 以上の巻の数字がある / 1 巻が無い / 巻が読めない本が**ちょうど 1 冊**、
    /// または巻が読めない本のうちタイトルがシリーズ名だけの本が**ちょうど 1 冊**。
    /// ただし、その 1 冊のタイトルに総集編・番外編のような「1 冊目ではない」ことを示す語があるときは推定しない。
    /// 推定した巻には `volumeInferred` を付け、一覧・見直し表で区別できるようにする。
    /// シリーズ名の直後に付くと「1 冊目ではない」ことを示す英字(「Xex」「X SP」)。途中に含まれるだけでは見ない。
    static let notFirstVolumePrefixes = ["ex", "extra", "sp", "special", "after", "omake"]

    static let notFirstVolumeMarkers = ["総集編", "番外編", "外伝", "特別編", "おまけ", "再録", "anthology", "アンソロジー"]

    static func inferFirstVolumes(_ document: inout ProposalDocument) {
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        // 同じ名前でも、分ける分類の組は別のシリーズ(SeriesGrouper.separateCategories)なので、組の番号でまとめる。
        let bySeries = Dictionary(grouping: seriesBooks) { document.books[$0].groupID ?? -1 }
        for (_, indices) in bySeries {
            let numbers = indices.compactMap { document.books[$0].volumeNumber }
            let unread = indices.filter { document.books[$0].volumeText.isEmpty }
            guard numbers.contains(where: { $0 >= 2 }), !numbers.contains(1), !unread.isEmpty else { continue }
            // 「1 冊目ではない」語は、シリーズ名より後ろの部分だけで探す(シリーズ名そのものに「総集編」が
            // 含まれることがある。「X 総集編」「X 総集編 02」…の番号の無い 1 冊は 1 巻)。
            func remainder(_ i: Int) -> String {
                let title = ComparableText(document.books[i].parsed.title).key
                let name = ComparableText(document.books[i].series).key
                return title.starts(with: name) ? String(title.dropFirst(name.count)) : String(title)
            }
            let plausible = unread.filter { i in
                let r = remainder(i)
                return !notFirstVolumeMarkers.contains(where: { r.contains($0) })
                    && !notFirstVolumePrefixes.contains(where: { r.hasPrefix($0) })
            }
            // 候補が 1 冊ならそれ。2 冊以上なら、タイトルがシリーズ名だけの 1 冊(「X」)。
            // どれも決められなければ推定しない。
            let exact = plausible.filter { remainder($0).isEmpty }
            let candidates = plausible.count == 1 ? plausible : exact
            guard candidates.count == 1 else { continue }
            let i = candidates[0]
            // ほかの巻がゼロ埋め(「02」「03」)なら、同じ桁数にそろえる(「01」)。
            let padded = indices.compactMap { i -> Int? in
                let t = document.books[i].volumeText
                return t.count > 1 && t.hasPrefix("0") && t.allSatisfy(\.isNumber) ? t.count : nil
            }
            let width = padded.max() ?? 1
            // ほかの巻がローマ数字(「II」「III」)なら「I」にする。
            let usesRoman = indices.contains { j in
                let t = document.books[j].volumeText
                return !t.isEmpty && t.allSatisfy { "IVX".contains($0) }
            }
            document.books[i].volumeText = usesRoman ? "I" : String(repeating: "0", count: max(0, width - 1)) + "1"
            document.books[i].volumeNumber = 1
            document.books[i].volumeInferred = true
        }
    }
}
