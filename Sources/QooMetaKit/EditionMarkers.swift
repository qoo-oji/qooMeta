import Foundation

// タイトルに付いた「版」と「発行形態」の印(利用者との取り決め、docs/design.md「版と発行形態」)。
//
// - **版**: 色・収録内容・修正・言語などが違う(フルカラー版、完全版、無修正版、英語版 …)。
//   同じ作品の版違いであって、続き物(シリーズ)ではない。
// - **発行形態**: 内容は色も含めて同一で、手に入れた経路だけが違う(DL版、電子版、特装版・通常版 …)。
//   特装版・通常版は付録の違いで本体は同じなので、こちらに入れる(両方をそろえる人は稀で、分けると困る)。
//
// どちらの印も、シリーズを組むときはタイトルから除いて比べる。印を除いて同じタイトルになる本は同じ作品の 1 冊と
// 数え、版違い・発行形態違いだけの組はシリーズにしない(SeriesGrouper)。

/// 語の規則(series-rules.json の `markers`)。タイトルの中の「役目のある語」を見つける、ただ 1 つの場所。
///
/// **決まりは 1 つ: 並びの上の規則から順に語を探し、上の規則が取った所には、下の規則は反応しない**(先に当たった規則が勝つ。
/// ファイアウォールの規則表や .gitignore、字句解析の規則の並びと同じ、よくある仕組み)。だから例外は、特別な仕組みではなく
/// 「守りたい規則より上に置いた、何もしない規則(`treat: keep`)」として書ける。
///
/// 「フルカラー総集編」は独立した 1 冊で、版違いでも総集編でもない(利用者の判断 2026-09-20)。はじめは総集編の規則にだけ
/// 付いた例外の条件として作ったが、ほかの語には使えず、どの規則が何を止めているのかも読み取りにくかった(利用者の指摘)。
/// いまは並びの先頭の `keep` の規則(`plain`)の語の 1 つで、版の印も総集編も、その下にあるので反応しない。
final class WordRules: Sendable {
    /// 規則が取った語。
    struct Claim: Sendable {
        var treat: SeriesRules.WordRule.Treatment
        /// 語そのものの位置(UTF-16)。取り合いはこの範囲で見る。
        var word: NSRange
        /// 語の前後の括弧と空白まで含めた位置(印をタイトルから外すときに使う)。
        var whole: NSRange
    }

    /// `firstScalars` は、その規則の語の頭の符号(正規表現を持つ規則は nil = 絞れない)。タイトルにどれも無ければ、
    /// その規則の語は入りえないので、正規表現をかけない。語の規則は 1 冊に何度もかかり、ほとんどのタイトルは
    /// どの語も持たない(2026-09-21 の計測で、計算の 15% が空振りの正規表現だった)。
    private let rules: [(treat: SeriesRules.WordRule.Treatment, pattern: NSRegularExpression, firstScalars: Set<UInt32>?)]

    init(_ rules: [SeriesRules.WordRule]) {
        self.rules = rules.compactMap { rule in
            // 長い語を先に並べる(「フルカラー版」を「カラー版」より先に)。
            let words = rule.words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            let all = words + rule.patterns
            guard !all.isEmpty else { return nil }
            // 印は前後の括弧ごと外すので、括弧と空白も一緒に読む(「DL版」は全角の「ＤＬ版」も規則の正規表現が受け付ける)。
            let source = #"\s*[\[［【(（]?\s*(?<word>"# + all.joined(separator: "|") + #")\s*[\]］】)）]?"#
            let firsts: Set<UInt32>? = rule.patterns.isEmpty
                ? Set(rule.words.compactMap { $0.unicodeScalars.first?.value }) : nil
            return (try? NSRegularExpression(pattern: source)).map { (rule.treat, $0, firsts) }
        }
    }

    /// 「そのまま読む語」の規則があるか(無ければ、巻の読み手は語を探す手間を省く)。
    var keepsAny: Bool { rules.contains { $0.treat == .keep } }

    /// 「そのまま読む語」の位置だけ(巻の読み手が使う。巻の読み手は語の規則より後ろの段階なので、並びの中の位置は問わない)。
    func keptRanges(in text: String) -> [NSRange] {
        let present = Set(text.unicodeScalars.lazy.map(\.value))
        return rules.filter { $0.treat == .keep && !($0.firstScalars?.isDisjoint(with: present) ?? false) }.flatMap { rule in
            (BudgetedRegex.matches(rule.pattern, in: text, budget: BudgetedRegex.defaultBudget) ?? [])
                .map { $0.range(withName: "word") }.filter { $0.location != NSNotFound }
        }
    }

    /// タイトルの中で規則が取った語(位置の順)。正規表現は利用者が書き足せるので、照合に時間の上限を設ける
    /// (越えた規則は、語が無いものとして扱う)。
    func claims(in title: String) -> [Claim] {
        // 同じ計算の中では、同じ文字列に 1 度だけ正規表現をかける(`ComputationCache`)。語の規則は `TextRules` と
        // 同じ規則から作るので、持ち主の見分けは要らない(計算の入口で、規則ごとに別の作り置きになる)。
        if let cache = ComputationCache.current {
            if let found = cache.claims[title] { return found }
            let found = uncachedClaims(in: title)
            if cache.claims.count < ComputationCache.limit { cache.claims[title] = found }
            return found
        }
        return uncachedClaims(in: title)
    }

    private func uncachedClaims(in title: String) -> [Claim] {
        var claims: [Claim] = []
        var present: Set<UInt32>?
        for rule in rules {
            if let firsts = rule.firstScalars {
                if present == nil { present = Set(title.unicodeScalars.lazy.map(\.value)) }
                if firsts.isDisjoint(with: present!) { continue }
            }
            guard let matches = BudgetedRegex.matches(rule.pattern, in: title, budget: BudgetedRegex.defaultBudget) else { continue }
            for m in matches {
                let word = m.range(withName: "word")
                guard word.location != NSNotFound, word.length > 0,
                      !claims.contains(where: { NSIntersectionRange($0.word, word).length > 0 }) else { continue }
                claims.append(Claim(treat: rule.treat, word: word, whole: m.range))
            }
        }
        return claims.sorted { $0.word.location < $1.word.location }
    }
}

final class EditionMarkers: Sendable {
    struct Split: Equatable, Sendable {
        /// 印を除いたタイトル(比べる・巻を読むのに使う)。
        var base: String
        var editions: [String]
        var sources: [String]
        /// 「シリーズに入れない語」(`treat: standalone`)がある。
        var standsAlone = false
    }

    private let words: WordRules
    /// 比べるタイトルから除く印(方針 `sameWork`)。`separateBooks` の印は見分けて付けるが、タイトルには残す。
    private let stripsEditions: Bool
    private let stripsSources: Bool

    init(_ rules: SeriesRules.Editions, words: WordRules) {
        stripsEditions = rules.stripsEditions
        stripsSources = rules.stripsSources
        self.words = words
    }

    func split(_ title: String) -> Split {
        let ns = title as NSString
        var editions: [String] = [], sources: [String] = []
        var base = ""
        var last = 0
        var standsAlone = false
        for claim in words.claims(in: title) {
            let strips: Bool
            if claim.treat == .standalone { standsAlone = true }
            switch claim.treat {
            case .edition: editions.append(ns.substring(with: claim.word)); strips = stripsEditions
            case .source: sources.append(ns.substring(with: claim.word)); strips = stripsSources
            case .keep, .compilation, .standalone: strips = false
            }
            // 外す範囲が前の印の範囲と重なることがある(あいだの空白を両方が読む)。重なった分は二度外さない。
            guard strips, claim.whole.location + claim.whole.length > last else { continue }
            let start = max(claim.whole.location, last)
            base += ns.substring(with: NSRange(location: last, length: start - last))
            last = claim.whole.location + claim.whole.length
        }
        base += ns.substring(from: last)
        base = TextRules.normalizeDisplay(base)
        // 印だけでできたタイトル(「DL版」)なら、元のまま比べる。
        guard !base.isEmpty else { return Split(base: title, editions: [], sources: [], standsAlone: standsAlone) }
        return Split(base: base, editions: editions, sources: sources, standsAlone: standsAlone)
    }
}

/// 総集編の語と、収録範囲の並べ替え。
final class Compilation: Sendable {
    let text: TextRules
    private let words: WordRules

    init(words: WordRules, text: TextRules) {
        self.words = words
        self.text = text
    }

    /// 総集編の語の位置(語の規則のうち `treat: compilation` が取った、最初の語)。上の規則が取った所の語
    /// (「フルカラー総集編」の中の「総集編」)は、総集編と見なさない。
    func keywordRange(in title: String) -> Range<String.Index>? {
        words.claims(in: title).first { $0.treat == .compilation }.flatMap { Range($0.word, in: title) }
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
