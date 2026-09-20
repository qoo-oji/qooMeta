import Foundation

/// シリーズ名より後ろの部分から、巻を読み取る。
///
/// **読めないものは作らない。** 番号の無いシリーズの順番を推測で埋めると、利用者には
/// 推測と事実の区別が付かなくなる。読めるのは次の形だけ:
/// - 数字(`2` `Vol.3` `ver2` `#4` `第5話` `その6` `Part 7`)。数字の直後が語なら読まない(「2人の…」は巻ではない)
/// - 漢数字(`第三話` `その二`)
/// - 「第」+ 数字 + 任意の漢字 1 字の単位(`第1幕` `第三部` `第2夜`)。`第04-1章` は分冊(数は 4.1)
/// - ローマ数字(`I` `II` `Ⅳ`。大文字だけ)
/// - 位置の語(`上` `中` `下` `前編` `中編` `後編`)。数はシリーズの中の文脈で決める(ProposalFinalizer.numberPositionWords)
/// - ギリシャ文字の小文字 1 字(`α` = 1)
/// - 雑誌の号・月号(`36号` `03月号`)と合併号(`36-37号`。表記は範囲、数は最初の号)。年はシリーズ名の側に残す
///   (「週刊〇〇 2025年」を 1 年ぶんのシリーズにする。利用者の判断)
final class VolumeExtractor: Sendable {
    struct Volume: Equatable, Sendable {
        var text: String
        var number: Double?
        /// 読んだ読み手の ID(説明に使う)。
        var reader = ""
    }

    /// 巻の読み方の語の一覧は series-rules.json の volume.readers(prefixes / counters / …)。
    let rules: SeriesRules.Volume
    static let kanjiDigits = "〇零一二三四五六七八九十百千壱弐参肆伍陸柒捌玖拾佰仟"

    /// 語の一覧を空にしたとき、空の選択肢が何にでも一致しないよう、決して一致しない形にする。
    static func nonEmpty(_ pattern: String) -> String { pattern.isEmpty ? "(?!)" : pattern }

    private let numeric: NSRegularExpression
    private let kanji: NSRegularExpression
    private let position: NSRegularExpression
    /// 巻だけでできている形。止めた読み手の形は含めない。
    private let wholeVolume: NSRegularExpression

    /// 巻の前に付く区切り。シリーズ名の末尾から落とす記号(TextRules.trailingTrim)に加えて「!」「?」と閉じ括弧も落とす
    /// (「X! ver2」)。シリーズ名の側では「!」を落とさない(「ご懐妊!!」のような名前がある)。
    let leadingSeparators: CharacterSet

    /// 雑誌の年と号(方針 magazines = whole のときだけ読む)。「2025年36-37号」「2011年10・11月号」「2011年03月号」「2022 Vol.01」「2022-01」。
    /// 数は 年 × 100 + 号(雑誌全体を 1 つのシリーズにしたときに、年をまたいで並べるため)。
    private static let magazineIssue = try! NSRegularExpression(
        pattern: #"^((?:19|20)\d{2})\s*(?:年\s*(\d{1,2})(?:\s*[-‐~〜・]\s*(\d{1,2}))?\s*(?:月号|月|号)|(?:vol\.?|no\.?|#)\s*(\d{1,3})|[-‐_.]\s*(\d{1,2})(?=$|\s))(?=$|\s|[~\-・!?.()\[\]【】])"#,
        options: [.caseInsensitive])

    init(_ rules: SeriesRules.Volume, text: TextRules) {
        self.rules = rules
        let nonEmpty = Self.nonEmpty, kanjiDigits = Self.kanjiDigits
        numeric = try! NSRegularExpression(
            pattern: #"^(?:"# + nonEmpty(rules.prefixPattern) + #")?\s*(\d+(?:\.\d+)?)(?:[-‐~〜](\d+))?(?:"#
                + nonEmpty(rules.alternation(rules.counters)) + #"|$|\s|[~\-・!?.)])"#,
            options: [.caseInsensitive])
        kanji = try! NSRegularExpression(
            pattern: #"^(?:(?:"# + nonEmpty(rules.kanjiPrefixPattern) + #")(["# + kanjiDigits + #"]+)|(["# + kanjiDigits + #"]+)(?:"#
                + nonEmpty(rules.alternation(rules.kanjiCounters)) + #"))"#)
        position = try! NSRegularExpression(
            pattern: #"^((?:"# + nonEmpty(rules.positionPattern) + #")(?:\s*\d{1,2})?)(?:$|\s)"#)
        let values = [
            rules.reads(.number) ? #"\d+(?:\.\d+)?(?:[-‐~〜]\d+)?"# : nil,
            rules.reads(.kanji) ? "[" + kanjiDigits + "]+" : nil,
            rules.reads(.greek) ? "[α-ω]" : nil,
        ].compactMap { $0 }
        let counted = #"^(?:(?:"# + nonEmpty(rules.prefixPattern) + #")\s*)?(?:"# + nonEmpty(values.joined(separator: "|"))
            + #")\s*(?:"# + nonEmpty(rules.alternation(rules.counters + rules.wholeOnlyCounters)) + #")?$"#
        let positionOnly = #"^(?:"# + nonEmpty(rules.reads(.position) ? rules.positionPattern : "") + #")(?:\s*\d{1,2})?$"#
        wholeVolume = try! NSRegularExpression(pattern: counted + "|" + positionOnly, options: [.caseInsensitive])
        leadingSeparators = text.trailingTrim.union(.whitespaces).union(CharacterSet(charactersIn: "!?！？】」』》〉)）]］>"))
    }

    /// 読み手を優先の順に試し、最初に読めたものを採る(規則で止めた読み手は飛ばす)。
    func extract(fromRemainder remainder: String) -> Volume? {
        let s = remainder.precomposedNFKC
            .trimmingCharacters(in: leadingSeparators)
        guard !s.isEmpty else { return nil }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        if rules.magazinesWhole, var volume = readMagazineIssue(s, ns, range) {
            volume.reader = "magazines"
            return volume
        }
        for reader in rules.readers {
            if var volume = read(reader, s, ns, range) {
                volume.reader = reader.rawValue
                return volume
            }
        }
        return nil
    }

    private func readMagazineIssue(_ s: String, _ ns: NSString, _ range: NSRange) -> Volume? {
        guard let m = Self.magazineIssue.firstMatch(in: s, range: range) else { return nil }
        let year = Int(ns.substring(with: m.range(at: 1)))!
        guard let issue = [2, 4, 5].lazy.compactMap({ i -> Int? in
            m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i)))
        }).first else { return nil }
        return Volume(text: ns.substring(with: m.range), number: Double(year * 100 + issue))
    }

    private func read(_ reader: SeriesRules.Reader, _ s: String, _ ns: NSString, _ range: NSRange) -> Volume? {
        switch reader {
        case .ordinal:
            // 「第」が付いていれば、数字の後ろの単位は何でもよい(「第1幕」「第三部」「第2夜」)。
            guard let m = Self.ordinal.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            guard let number = Double(text) ?? Self.kanjiNumber(text).map(Double.init) else { return nil }
            // 「第04-1章」: 後ろが前以下なら分冊(4.1、4.2 …)。前より大きければ合併(「第1-2巻」。数は最初)。
            if m.range(at: 2).location != NSNotFound, let sub = Int(ns.substring(with: m.range(at: 2))) {
                let range = "\(text)-\(ns.substring(with: m.range(at: 2)))"
                if Double(sub) <= number, sub > 0 {
                    return Volume(text: range, number: number + Double(sub) / (sub < 10 ? 10 : 100))
                }
                return Volume(text: range, number: number)
            }
            return Volume(text: text, number: number)
        case .number:
            guard let m = numeric.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            // 合併号(「36-37号」)。表記は範囲のまま、数は最初の号。範囲として読めなければ最初の数だけ。
            if m.range(at: 2).location != NSNotFound, let upper = Int(ns.substring(with: m.range(at: 2))),
               isMergedIssue(Double(text), upper) {
                return Volume(text: "\(text)-\(ns.substring(with: m.range(at: 2)))", number: Double(text))
            }
            return Volume(text: text, number: Double(text))
        case .kanji:
            guard let m = kanji.firstMatch(in: s, range: range) else { return nil }
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let text = ns.substring(with: r)
            return Volume(text: text, number: Self.kanjiNumber(text).map(Double.init))
        case .greek:
            guard let m = Self.greek.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            return Self.greekNumber(text).map { Volume(text: text, number: Double($0)) }
        case .roman:
            guard let m = Self.roman.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            return Self.romanNumber(text).map { Volume(text: text, number: Double($0)) }
        case .position:
            guard let m = position.firstMatch(in: s, range: range) else { return nil }
            return Volume(text: ns.substring(with: m.range(at: 1)), number: nil)
        }
    }

    /// 「第」+ 数字 + 任意の漢字 1 字の単位。
    private static let ordinal = try! NSRegularExpression(
        pattern: #"^第\s*(\d+(?:\.\d+)?|[〇零一二三四五六七八九十百千壱弐参肆伍陸柒捌玖拾佰仟]+)(?:[-‐](\d+))?\s*(?:\p{Han}|$|\s|[~\-・!?.)])"#)
    private static let wholeOrdinal = try! NSRegularExpression(
        pattern: #"^第\s*(?:\d+(?:\.\d+)?|[〇零一二三四五六七八九十百千壱弐参肆伍陸柒捌玖拾佰仟]+)(?:[-‐]\d+)?\s*\p{Han}?$"#)

    private static let greek = try! NSRegularExpression(pattern: #"^([α-ω])(?:$|\s|[~\-・!?.)])"#)

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
    func isWholeVolume(_ remainder: String) -> Bool {
        // 巻の後ろの括弧書き(「Vol.01 [注記]」「3 (完)」)は除いて見る。
        var t = remainder.precomposedNFKC
        while let r = t.range(of: #"\s*[\[(【][^\[\]()【】]*[\])】]\s*$"#, options: .regularExpression), r.lowerBound > t.startIndex {
            t = String(t[..<r.lowerBound])
        }
        let s = t.trimmingCharacters(in: leadingSeparators)
        guard !s.isEmpty else { return false }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        if rules.magazinesWhole, let m = Self.magazineIssue.firstMatch(in: s, range: range), m.range.length == ns.length {
            return true
        }
        // 「第」付き(分冊の「第04-1章」を含む)は先に見る。下の範囲の判定は合併号のためのもので、分冊には当てない。
        if rules.reads(.ordinal), Self.wholeOrdinal.firstMatch(in: s, range: range) != nil { return true }
        if wholeVolume.firstMatch(in: s, range: range) != nil {
            // 範囲(「36-37」)は合併号として読めるときだけ。「2021-01」は範囲ではない(年と月)。
            if let r = s.range(of: #"(\d+)[-‐~〜](\d+)"#, options: .regularExpression) {
                let parts = s[r].split(whereSeparator: { "-‐~〜".contains($0) })
                return isMergedIssue(Double(parts[0]), Int(parts[1]))
            }
            return true
        }
        // ローマ数字だけ(「II」)。
        if rules.reads(.roman), let m = Self.roman.firstMatch(in: s, range: range), m.range.length == ns.length || m.range(at: 1).length == ns.length {
            return Self.romanNumber(ns.substring(with: m.range(at: 1))) != nil
        }
        return false
    }


    /// 漢数字を数にする。大字(壱弐参…)・百・千・〇にも対応する(StackNest の NumeralNormalizer(MIT)の表に倣った)。
    static func kanjiNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = [
            "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
            "壱": 1, "弐": 2, "参": 3, "肆": 4, "伍": 5, "陸": 6, "柒": 7, "捌": 8, "玖": 9,
        ]
        let powers: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "拾": 10, "佰": 100, "仟": 1000]
        var total = 0, current = 0
        for ch in s {
            if let p = powers[ch] {
                total += (current == 0 ? 1 : current) * p
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

    /// 「36-37」が合併号(続く号をまとめたもの)として読めるか。後ろが前より大きく、差が小さいときだけ。
    func isMergedIssue(_ lower: Double?, _ upper: Int?) -> Bool {
        guard let lower, let upper else { return false }
        return Double(upper) > lower && Double(upper) - lower <= Double(rules.mergedIssueMaxSpan)
    }

    /// 数字だけの文字列か(算用数字・漢数字)。末尾の丸括弧が原作か巻かの判定に使う。
    static func isNumeralOnly(_ s: String) -> Bool {
        let t = s.precomposedNFKC.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return Double(t) != nil || kanjiNumber(t) != nil
    }

    /// ギリシャ文字の小文字 1 字の巻(「X α」「X β」。StackNest に倣った)。α = 1 … ω = 24。
    static func greekNumber(_ s: String) -> Int? {
        let letters = Array("αβγδεζηθικλμνξοπρστυφχψω")
        guard s.count == 1, let i = letters.firstIndex(of: s.first!) else { return nil }
        return i + 1
    }
}

/// 候補の判定を本ごとの値へ反映する。
enum ProposalFinalizer {
    /// 確定した巻の表記(利用者の確定、または型が読んだ `@volume`)。
    static func confirmedVolume(_ confirmation: Confirmation) -> String? {
        // 利用者が「巻は無い」と確定したとき(空の表記)も、確定として扱う(推定し直さない)。
        if case .series(_, let volume?, _) = confirmation { return volume }
        if let read = confirmation.fields[.volume]?.first, !read.isEmpty { return read }
        return nil
    }

    /// 組を本ごとの値(シリーズ名・巻)へ反映する。
    static func finalize(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog? = nil) {
        var seriesByBook: [Int: String] = [:]
        var groupByBook: [Int: Int] = [:]
        for group in document.groups {
            let name = group.ruleName
            guard group.memberIDs.count >= (group.allowsSingle == true ? 1 : 2), !name.isEmpty else { continue }
            for id in group.memberIDs { seriesByBook[id] = name; groupByBook[id] = group.id }
        }
        for i in document.books.indices {
            let series = seriesByBook[document.books[i].id] ?? ""
            document.books[i].series = series
            document.books[i].groupID = groupByBook[document.books[i].id]
            document.books[i].volumeText = ""
            document.books[i].volumeNumber = nil
            document.books[i].volumeInferred = nil
            guard !series.isEmpty else { continue }
            // 確定した巻(利用者が直した値、または型が名前から直に読んだ `@volume`)はそのまま使う。
            // 並べ替え用の数は、表記を巻の読み手に通して決める(「上」は文脈で後から)。
            if let volume = confirmedVolume(document.books[i].confirmation) {
                document.books[i].volumeText = volume
                document.books[i].volumeNumber = engine.volumes.extract(fromRemainder: " " + volume)?.number
                document.books[i].volumeConfirmed = true
                continue
            }
            let title = engine.text.comparable(document.books[i].compareTitle)
            let nameKey = engine.text.comparable(series).key
            // シリーズ名がタイトルの前半に当たらない(利用者が別の名前に確定した)ときは、巻を読まない。
            guard title.key.starts(with: nameKey) else { continue }
            let remainder = title.originalRemainder(afterKeyLength: nameKey.count)
            if let volume = engine.volumes.extract(fromRemainder: remainder) {
                document.books[i].volumeText = volume.text
                document.books[i].volumeNumber = volume.number
                log?.apply(volume.reader, to: document.books[i].id)
            }
        }
        if engine.rules.series.compilation.placement == .inMainSeries, engine.rules.series.compilation.volumeAfterRange {
            placeCompilationsAfterRange(&document, engine: engine, log: log)
        }
        if engine.volumes.rules.sharedLeadingKanjiEnabled { readLeadingKanjiNumerals(&document, engine: engine, log: log) }
        numberPositionWords(&document, engine: engine)
        if engine.volumes.rules.inferFirstVolume { inferFirstVolumes(&document, engine: engine, log: log) }
    }

    /// 本編に含めた総集編(方針 compilations = inMainSeries)の巻を、収録範囲の最後の巻の直後にする
    /// (方針 compilationVolume = afterRange。「X 総集編 1~4」は 4.5)。範囲が読めなければ巻を付けない(並びは末尾)。
    static func placeCompilationsAfterRange(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        for i in document.books.indices
        where !document.books[i].series.isEmpty && document.books[i].volumeText.isEmpty && !document.books[i].volumeConfirmed {
            let title = engine.text.comparable(document.books[i].compareTitle)
            let name = engine.text.comparable(document.books[i].series).key
            guard title.key.starts(with: name) else { continue }
            let remainder = title.originalRemainder(afterKeyLength: name.count)
                .trimmingCharacters(in: engine.volumes.leadingSeparators)
            guard let r = engine.compilation.keywordRange(in: remainder), r.lowerBound == remainder.startIndex else { continue }
            // 範囲の最後の数(「1~4」の 4、「9~11+α」の 11)。
            let range = String(remainder[r.upperBound...]).precomposedNFKC.prefix { $0 != "+" }
            guard let last = range.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).last.flatMap({ Int($0) })
            else { continue }
            document.books[i].volumeText = remainder
            document.books[i].volumeNumber = Double(last) + 0.5
            log?.apply("compilationVolume", to: document.books[i].id)
        }
    }

    /// 「上」「中」「下」(「前編」「中編」「後編」)を数にする。**組の中に「中」があるかで決める**:
    /// あれば 上=1・中=2・下=3、無ければ 上=1・下=2(StackNest の FilenameParser の文脈判定に倣った)。
    /// 巻の表記(volumeText)は文字のまま残し、数(volumeNumber)だけを入れる。
    static func numberPositionWords(_ document: inout WorkingDocument, engine: RuleEngine) {
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        for (_, indices) in Dictionary(grouping: seriesBooks, by: { document.books[$0].groupID ?? -1 }) {
            // 位置の語の後ろの番号(「後編1」「後編2」)は分冊。数は位置 + 番号 / 10(後編1 = 3.1)。
            func split(_ t: String) -> (word: String, sub: Int?) {
                let word = String(t.prefix { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
                return (word, Int(t.drop { !$0.isNumber }))
            }
            func kind(_ t: String) -> Int? {
                let word = split(t).word, positions = engine.volumes.rules.positionWords
                if positions.first.contains(word) { return 0 }
                if positions.middle.contains(word) { return 1 }
                if positions.last.contains(word) { return 2 }
                return nil
            }
            let kinds = indices.compactMap { i -> (Int, Int)? in
                guard document.books[i].volumeNumber == nil, let k = kind(document.books[i].volumeText) else { return nil }
                return (i, k)
            }
            guard !kinds.isEmpty else { continue }
            let hasMiddle = kinds.contains { $0.1 == 1 }
            for (i, k) in kinds {
                let base = Double(k == 2 ? (hasMiddle ? 3 : 2) : k + 1)
                let sub = split(document.books[i].volumeText).sub.map { Double($0) / ($0 < 10 ? 10 : 100) } ?? 0
                document.books[i].volumeNumber = base + sub
            }
        }
    }

    /// 漢数字で始まるだけの巻(「X 二〇」「X 三〇」のように、漢数字の直後に単位が無い形)を読む。
    ///
    /// 漢数字の直後に「巻」「話」などが無い形は、1 冊だけ見ると「X 三人の夜」「X 十字架」のような普通の言葉と
    /// 区別できない。**同じシリーズの中で、巻の読めない本が 2 冊以上、互いに違う漢数字で始まっているときだけ**読む
    /// (利用者の指摘。番号を言葉遊びに埋め込んだ同人誌のシリーズ)。
    static func readLeadingKanjiNumerals(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        for (_, indices) in Dictionary(grouping: seriesBooks, by: { document.books[$0].groupID ?? -1 }) {
            var found: [(index: Int, text: String, number: Int)] = []
            for i in indices where document.books[i].volumeText.isEmpty && !document.books[i].volumeConfirmed {
                let title = engine.text.comparable(document.books[i].compareTitle)
                let name = engine.text.comparable(document.books[i].series).key
                guard title.key.starts(with: name) else { continue }
                let remainder = title.originalRemainder(afterKeyLength: name.count)
                    .trimmingCharacters(in: engine.volumes.leadingSeparators)
                let digits = String(remainder.prefix { "一二三四五六七八九十".contains($0) })
                guard !digits.isEmpty, let n = VolumeExtractor.kanjiNumber(digits) else { continue }
                found.append((i, digits, n))
            }
            guard found.count >= engine.volumes.rules.sharedLeadingKanjiMinBooks, Set(found.map(\.number)).count == found.count
            else { continue }
            for f in found {
                document.books[f.index].volumeText = f.text
                document.books[f.index].volumeNumber = Double(f.number)
                log?.apply("sharedLeadingKanji", to: document.books[f.index].id)
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
    /// (語の一覧は volume.inference.firstVolume の excludePrefixes と excludeMarkers)
    static func inferFirstVolumes(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        let notFirstVolumePrefixes = engine.volumes.rules.notFirstPrefixes
        let notFirstVolumeMarkers = engine.volumes.rules.notFirstMarkers
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        // 同じ名前でも、分ける分類の組は別のシリーズ(SeriesGrouper.separateCategories)なので、組の番号でまとめる。
        let bySeries = Dictionary(grouping: seriesBooks) { document.books[$0].groupID ?? -1 }
        for (_, indices) in bySeries {
            let numbers = indices.compactMap { document.books[$0].volumeNumber }
            // 利用者が確定させた巻(「巻は無い」と確定したものを含む)は、読めた巻として扱う。
            let unread = indices.filter { document.books[$0].volumeText.isEmpty && !document.books[$0].volumeConfirmed }
            guard numbers.contains(where: { $0 >= 2 }), !numbers.contains(1), !unread.isEmpty else { continue }
            // 「1 冊目ではない」語は、シリーズ名より後ろの部分だけで探す(シリーズ名そのものに「総集編」が
            // 含まれることがある。「X 総集編」「X 総集編 02」…の番号の無い 1 冊は 1 巻)。
            func remainder(_ i: Int) -> String {
                let title = engine.text.comparable(document.books[i].compareTitle).key
                let name = engine.text.comparable(document.books[i].series).key
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
            log?.apply("firstVolume", to: document.books[i].id)
        }
    }
}
