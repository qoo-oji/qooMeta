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
public enum EditionMarkers {
    public struct Split: Equatable, Sendable {
        /// 印を除いたタイトル(比べる・巻を読むのに使う)。
        public var base: String
        public var editions: [String]
        public var sources: [String]
    }

    static let editionWords = [
        "フルカラー版", "カラー版", "モノクロ版", "完全版", "新装版", "愛蔵版", "無修正版", "修正版", "改訂版", "旧版", "新版",
    ]
    static let sourceWords = ["初回限定版", "限定版", "特装版", "通常版", "電子版", "デジタル版", "スキャン版"]

    /// 印の正規表現。前後の括弧ごと取り除く。長い語を先に並べる(「フルカラー版」を「カラー版」より先に)。
    /// 「DL版」は全角の「ＤＬ版」も受け付ける。「〇〇語版」(英語版・中国語版 …)は版。
    private static let pattern: NSRegularExpression = {
        func alternation(_ words: [String]) -> String {
            words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        }
        let edition = alternation(editionWords) + #"|[\p{Han}\p{Katakana}ー]{1,6}語版"#
        let source = alternation(sourceWords) + "|[DＤ][LＬ]版"
        return try! NSRegularExpression(
            pattern: #"\s*[\[［【(（]?\s*(?:(?<edition>"# + edition + #")|(?<source>"# + source + #"))\s*[\]］】)）]?"#)
    }()

    public static func split(_ title: String) -> Split {
        let ns = title as NSString
        var editions: [String] = [], sources: [String] = []
        var base = ""
        var last = 0
        for m in pattern.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            base += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let e = m.range(withName: "edition"), s = m.range(withName: "source")
            if e.location != NSNotFound { editions.append(ns.substring(with: e)) }
            if s.location != NSNotFound { sources.append(ns.substring(with: s)) }
        }
        base += ns.substring(from: last)
        base = TextRules.normalizeDisplay(base)
        // 印だけでできたタイトル(「DL版」)なら、元のまま比べる。
        guard !base.isEmpty else { return Split(base: title, editions: [], sources: []) }
        return Split(base: base, editions: editions, sources: sources)
    }
}

/// 総集編の語と、収録範囲の並べ替え。
public enum Compilation {
    /// 「総集編」(「総集篇」とも書く)。
    static let keyword = try! NSRegularExpression(pattern: "総集[編篇]")

    static func keywordRange(in title: String) -> Range<String.Index>? {
        let ns = title as NSString
        guard let m = keyword.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(m.range, in: title)
    }

    /// 総集編の前に書かれた収録範囲・番号(「1~4」「9~11+α」「11」)。
    private static let trailingRange = try! NSRegularExpression(
        pattern: #"\s*(?:第\s*)?(\d+(?:\s*[~〜\-‐]\s*\d+)?(?:\s*[+＋]\s*[α-ωA-Za-zぁ-んァ-ン]+)?)\s*(?:巻)?\s*$"#)

    /// 「X1~4総集編」を「X 総集編 1~4」に並べ替える(シリーズ名は「X 総集編」、範囲はその巻)。当てはまらなければ nil。
    public static func normalizedTitle(_ title: String) -> String? {
        guard let r = keywordRange(in: title), r.lowerBound > title.startIndex else { return nil }
        let head = String(title[..<r.lowerBound])
        let ns = head as NSString
        guard let m = trailingRange.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
              m.range.location > 0 else { return nil }
        let main = TextRules.trimSeriesName(ns.substring(to: m.range.location))
        guard !main.isEmpty else { return nil }
        let range = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
        let rest = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return "\(main) \(title[r]) \(range)" + (rest.isEmpty ? "" : " \(rest)")
    }
}
