import Foundation

/// ファイル名(拡張子を除いたもの)を部分に分けた結果。
///
/// 想定している形は、同人誌の書庫で広く使われている
/// `(分類) [サークル (作者)] タイトル (ネタ)`。どの部分も省略されうる。
/// 当てはまらない名前は、全体をタイトルとして扱う(`matchedPattern == false`)。
struct NameParts: Sendable, Equatable {
    /// 先頭の丸括弧。頒布イベント名や分類が入る。
    var leading: String
    /// 角括弧の中の、丸括弧より前の部分。
    var circle: String
    /// 角括弧の中の丸括弧。複数人は「、」「,」「&」「/」で区切られる。
    var authors: [String]
    var title: String
    /// 末尾の丸括弧。元になった作品(ネタ)が入る。
    var trailing: String
    var matchedPattern: Bool
    /// 本の種別(qooLibrary の `@mediatype`、旧 `@booktype`)。種別が違う本は同じシリーズにしない。
    /// qooLibrary のフォーマットで読めたときだけ入る(NameParser では空)。
    var mediaType: String?
    /// 頒布イベント(`@event`)。先頭の丸括弧が本の種別の語彙に無いとき。
    var event: String?
    /// 末尾の角括弧(`@keyword`)。
    var keyword: String?
    /// 版の印(フルカラー版・完全版 …)と入手経路の印(DL版・特装版 …)。EditionMarkers。
    var editions: [String]?
    var sources: [String]?
    /// 版・入手経路の印を除いたタイトル。シリーズを組む・巻を読むときはこちらを使う(表示・書き出しは title)。
    var workTitle: String?

    /// どのフォーマットで読めたか(読めなければ fallback)。
    var format: FormatMatch = .fallback("wholeName")

    /// 比べるためのタイトル(印を除いたもの。無ければ title)。
    var baseTitle: String { workTitle ?? title }

    init(leading: String = "", circle: String = "", authors: [String] = [], title: String,
                trailing: String = "", matchedPattern: Bool, mediaType: String? = nil, event: String? = nil,
                keyword: String? = nil) {
        self.leading = leading
        self.circle = circle
        self.authors = authors
        self.title = title
        self.trailing = trailing
        self.matchedPattern = matchedPattern
        self.mediaType = mediaType
        self.event = event
        self.keyword = keyword
    }
}

enum NameParser {
    // (A) [B] T (D) — A・B・D はどれも省略可。T は最短一致なので、末尾の丸括弧は D に取られる。
    // 括弧は全角も受け付ける(値の表記は変えないので、正規化せずに照合する)。
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:[(（]([^()（）]*)[)）]\s*)?(?:[\[［]([^\[\]［］]*)[\]］]\s*)?(.*?)(?:\s*[(（]([^()（）]*)[)）])?$"#)
    private static let circleAuthors = try! NSRegularExpression(
        pattern: #"^(.*?)\s*[(（](.*)[)）]$"#)

    static func parse(baseName: String) -> NameParts {
        let name = TextRules.normalizeDisplay(baseName)
        let ns = name as NSString
        guard let m = pattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
            return NameParts(title: name, matchedPattern: false)
        }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : TextRules.normalizeDisplay(ns.substring(with: r))
        }
        let leading = group(1), bracket = group(2), trailing = group(4)
        var title = group(3)
        // 丸括弧だけの名前((X) のみ)は、括弧の中身をタイトルとして扱う。
        if title.isEmpty, bracket.isEmpty, !trailing.isEmpty, leading.isEmpty {
            title = trailing
            return NameParts(title: title, matchedPattern: false)
        }
        if title.isEmpty {
            return NameParts(title: name, matchedPattern: false)
        }
        let (circle, authors) = splitCircle(bracket)
        let matched = !bracket.isEmpty
        return NameParts(leading: leading, circle: circle, authors: authors, title: title,
                          trailing: trailing, matchedPattern: matched)
    }

    static func splitCircle(_ bracket: String) -> (String, [String]) {
        guard !bracket.isEmpty else { return ("", []) }
        let ns = bracket as NSString
        guard let m = circleAuthors.firstMatch(in: bracket, range: NSRange(location: 0, length: ns.length)) else {
            return (bracket, [])
        }
        let circle = TextRules.normalizeDisplay(ns.substring(with: m.range(at: 1)))
        let inner = ns.substring(with: m.range(at: 2))
        let authors = inner
            .split(whereSeparator: { "、,，&＆/／".contains($0) })
            .map { TextRules.normalizeDisplay(String($0)) }
            .filter { !$0.isEmpty }
        // 「(作者)」だけで角括弧の前半が空なら、作者名をサークル名としても扱う。
        if circle.isEmpty { return (authors.first ?? "", authors) }
        return (circle, authors)
    }
}
