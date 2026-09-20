import Foundation

/// タイトルに付いた「版」と「入手経路」の印(利用者との取り決め、docs/design.md「版と入手経路」)。
///
/// - **版**: 色・収録内容・修正・言語などが違う(フルカラー版、完全版、無修正版、英語版 …)。
///   同じ作品の版違いであって、続き物(シリーズ)ではない。
/// - **入手経路**: 内容は色も含めて同一で、手に入れた経路だけが違う(DL版、電子版、特装版・通常版 …)。
///   特装版・通常版は付録の違いで本体は同じなので、こちらに入れる(両方をそろえる人は稀で、分けると困る)。
///
/// どちらの印も、シリーズを組むときはタイトルから除いて比べる。印を除いて同じタイトルになる本は同じ作品の 1 冊と
/// 数え、版違い・入手経路違いだけの組はシリーズにしない(SeriesGrouper)。
final class EditionMarkers: Sendable {
    struct Split: Equatable, Sendable {
        /// 印を除いたタイトル(比べる・巻を読むのに使う)。
        var base: String
        var editions: [String]
        var sources: [String]
    }

    /// 印の正規表現。前後の括弧ごと取り除く。長い語を先に並べる(「フルカラー版」を「カラー版」より先に)。
    /// 「DL版」は全角の「ＤＬ版」も受け付ける。「〇〇語版」(英語版・中国語版 …)は版。
    /// 印の規則(markers.edition / markers.source)を止めると、その語は空になる。両方とも空なら印は探さない。
    private let pattern: NSRegularExpression?
    /// 比べるタイトルから除く印(方針 `sameWork`)。`separateBooks` の印は見分けて付けるが、タイトルには残す。
    private let stripsEditions: Bool
    private let stripsSources: Bool
    /// 「フルカラー総集編」は独立した 1 冊で、版違いでも総集編でもない(利用者の判断)。印の語のすぐ後ろに区切り無しで
    /// 総集編の語が続く形は、印として外さずタイトルの一部として残す(外すと「X 総集編」になり、総集編として組まれてしまう)。
    /// 語と有効無効は規則 grouping.compilation.conditions.reject-edition-prefix が決める。
    private let editionPrefixes: Set<String>
    private let compilationWords: [String]

    /// 印の一覧は series-rules.json の markers。総集編の規則は、上の「すぐ後ろに続く形」の判定にだけ使う。
    init(_ rules: SeriesRules.Editions, compilation: SeriesRules.Compilation) {
        stripsEditions = rules.stripsEditions
        stripsSources = rules.stripsSources
        editionPrefixes = Set(compilation.editionPrefixes)
        compilationWords = compilation.editionPrefixes.isEmpty ? [] : compilation.keywords
        func alternation(_ words: [String]) -> [String] {
            words.isEmpty ? [] : [words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")]
        }
        let edition = (alternation(rules.edition) + rules.editionPatterns).joined(separator: "|")
        let source = (alternation(rules.source) + rules.sourcePatterns).joined(separator: "|")
        // 空の選択肢は空文字列に一致してしまうので、決して一致しない形(`(?!)`)にする。
        guard !edition.isEmpty || !source.isEmpty else { pattern = nil; return }
        pattern = try! NSRegularExpression(
            pattern: #"\s*[\[［【(（]?\s*(?:(?<edition>"# + (edition.isEmpty ? "(?!)" : edition) + #")|(?<source>"#
                + (source.isEmpty ? "(?!)" : source) + #"))\s*[\]］】)）]?"#)
    }

    func split(_ title: String) -> Split {
        guard let pattern else { return Split(base: TextRules.normalizeDisplay(title), editions: [], sources: []) }
        let ns = title as NSString
        var editions: [String] = [], sources: [String] = []
        var base = ""
        var last = 0
        // 印の正規表現は利用者が書き足せるので、照合に時間の上限を設ける(越えたら印は無いものとして扱う)。
        guard let matches = BudgetedRegex.matches(pattern, in: title, budget: BudgetedRegex.defaultBudget) else {
            return Split(base: TextRules.normalizeDisplay(title), editions: [], sources: [])
        }
        for m in matches {
            base += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let matched = ns.substring(with: m.range)
            last = m.range.location + m.range.length
            let e = m.range(withName: "edition"), s = m.range(withName: "source")
            // 「フルカラー版総集編」のように、印の語のすぐ後ろに(括弧も空白も挟まずに)総集編の語が続く形は、印にしない。
            // 一致が印の語で終わっていること(閉じ括弧や空白を巻き込んでいないこと)が「区切り無し」の条件。
            if e.location != NSNotFound, e.location + e.length == m.range.location + m.range.length,
               editionPrefixes.contains(ns.substring(with: e)),
               compilationWords.contains(where: ns.substring(from: last).hasPrefix) {
                base += matched
                continue
            }
            if e.location != NSNotFound { editions.append(ns.substring(with: e)) }
            if s.location != NSNotFound { sources.append(ns.substring(with: s)) }
            if (e.location != NSNotFound && !stripsEditions) || (s.location != NSNotFound && !stripsSources) {
                base += ns.substring(with: m.range)
            }
        }
        base += ns.substring(from: last)
        base = TextRules.normalizeDisplay(base)
        // 印だけでできたタイトル(「DL版」)なら、元のまま比べる。
        guard !base.isEmpty else { return Split(base: title, editions: [], sources: []) }
        return Split(base: base, editions: editions, sources: sources)
    }
}

/// 総集編の語と、収録範囲の並べ替え。
final class Compilation: Sendable {
    /// 「総集編」(「総集篇」とも書く)。series-rules.json の grouping.compilation.words。
    let keyword: NSRegularExpression
    let text: TextRules
    /// すぐ前に区切り無しで続いたら総集編と見なさない語(規則 grouping.compilation.conditions.reject-edition-prefix)。
    private let editionPrefixes: [String]

    init(_ rules: SeriesRules.Compilation, text: TextRules) {
        let words = rules.keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        keyword = try! NSRegularExpression(pattern: words.isEmpty ? "(?!)" : words.joined(separator: "|"))
        editionPrefixes = rules.editionPrefixes
        self.text = text
    }

    /// 総集編の語の位置。「フルカラー総集編」のように、版の語が区切り無しですぐ前に続く形は総集編と見なさない
    /// (独立した 1 冊。利用者の判断 2026-09-20)。同じ名前にほかの総集編の語があれば、そちらを見る。
    func keywordRange(in title: String) -> Range<String.Index>? {
        let ns = title as NSString
        for m in keyword.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: title) else { continue }
            if editionPrefixes.contains(where: title[..<r.lowerBound].hasSuffix) { continue }
            return r
        }
        return nil
    }

    /// 総集編の前に書かれた収録範囲・番号(「1~4」「9~11+α」「11」)。
    private static let trailingRange = try! NSRegularExpression(
        pattern: #"\s*(?:第\s*)?(\d+(?:\s*[~〜\-‐]\s*\d+)?(?:\s*[+＋]\s*[α-ωA-Za-zぁ-んァ-ン]+)?)\s*(?:巻)?\s*$"#)

    /// 「X1~4総集編」を「X 総集編 1~4」に並べ替える(シリーズ名は「X 総集編」、範囲はその巻)。当てはまらなければ nil。
    func normalizedTitle(_ title: String) -> String? {
        guard let r = keywordRange(in: title), r.lowerBound > title.startIndex else { return nil }
        let head = String(title[..<r.lowerBound])
        let ns = head as NSString
        guard let m = Self.trailingRange.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
              m.range.location > 0 else { return nil }
        let main = text.trimSeriesName(ns.substring(to: m.range.location))
        guard !main.isEmpty else { return nil }
        let range = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
        let rest = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return "\(main) \(title[r]) \(range)" + (rest.isEmpty ? "" : " \(rest)")
    }
}

/// 時間の上限つきの照合(QooFormat の SafeRegex と同じ仕組み。規則の正規表現による計算の暴走を止める)。
enum BudgetedRegex {
    /// 1 回の照合の上限(QooFormat の AppLimits.Format.regexMatchBudget と同じ)。
    static let defaultBudget: TimeInterval = 0.02

    /// すべての一致。上限を越えたら nil。
    static func matches(_ regex: NSRegularExpression, in text: String, budget: TimeInterval) -> [NSTextCheckingResult]? {
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(max(budget, 0) * 1_000_000_000)
        var found: [NSTextCheckingResult] = []
        var abandoned = false
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(location: 0, length: (text as NSString).length)) { result, flags, stop in
            if flags.contains(.progress) {
                if DispatchTime.now().uptimeNanoseconds &- started > limit {
                    abandoned = true
                    stop.pointee = true
                }
                return
            }
            if let result { found.append(result) }
        }
        return abandoned ? nil : found
    }
}
