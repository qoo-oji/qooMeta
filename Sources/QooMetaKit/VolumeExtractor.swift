import Foundation

/// シリーズ名より後ろの部分から、巻を読み取る。
///
/// **読めないものは作らない。** 番号の無いシリーズの順番を推測で埋めると、利用者には
/// 推測と事実の区別が付かなくなる。読めるのは次の形だけ:
/// - 数字(`2` `Vol.3` `ver2` `#4` `第5話` `その6` `Part 7`)。数字の直後が語なら読まない(「2人の…」は巻ではない)
/// - 語で書いた数(`ふたつ` = 2、`みっかめ` = 3)。どの語がどの数かは規則の対応表が決める
/// - 漢数字(`第三話` `その二`)。**大字(`壱` `弐` `参`)は、前に語も後ろに単位も無くても読む**
///   ―― 題名の言葉と見分けが付くのは大字だけ(`X 弐` は 2 巻、`X 二` は読まない)
/// - 「第」+ 数字 + 任意の漢字 1 字の単位(`第1幕` `第三部` `第2夜`)。`第04-1章` は分冊(数は 4.1)
/// - ローマ数字(`I` `II` `Ⅳ`。大文字だけ)
/// - 位置の語(`上` `中` `下` `前編` `中編` `後編`)。数はシリーズの中の文脈で決める(ProposalFinalizer.numberPositionWords)
/// - 続きの語(`アフターエピソード` `後日談` `その後`)。本編のナンバリングの後ろに続く 1 冊で、数はシリーズの中の
///   文脈で決める(ProposalFinalizer.numberSequels)
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
    /// 語の規則。「そのまま読む語」(`treat: keep`)に重なる表記は、巻として読まない。
    private let words: WordRules?
    static let kanjiDigits = "〇零一二三四五六七八九十百千壱弐参壹貳參肆伍陸柒漆捌玖拾佰仟"

    /// 語の一覧を空にしたとき、空の選択肢が何にでも一致しないよう、決して一致しない形にする。
    static func nonEmpty(_ pattern: String) -> String { pattern.isEmpty ? "(?!)" : pattern }

    private let numeric: NSRegularExpression
    private let kanji: NSRegularExpression
    /// 大字だけでできた巻(「X 弐」)。
    private let kanjiAlone: NSRegularExpression
    /// 数を語で書いた巻(「ふたつ」)。
    private let wordNumber: NSRegularExpression
    /// 「第」+ 数字 + 任意の漢字 1 字、ギリシャ文字、ローマ数字。**巻の後ろに来てよい文字**(規則 volume.followers)を
    /// 使うので、規則ごとに組み立てる。
    private let ordinal: NSRegularExpression
    private let greek: NSRegularExpression
    private let roman: NSRegularExpression
    private let position: NSRegularExpression
    /// 続きの語で始まるか(語そのものだけを見る。表記は残り全体)。
    private let sequel: NSRegularExpression
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

    init(_ rules: SeriesRules.Volume, text: TextRules, words: WordRules? = nil) {
        self.rules = rules
        self.words = words
        let nonEmpty = Self.nonEmpty, kanjiDigits = Self.kanjiDigits
        numeric = try! NSRegularExpression(
            pattern: #"^(?:"# + nonEmpty(rules.prefixPattern) + #")?\s*(\d+(?:\.\d+)?)(?:[-‐~〜](\d+))?(?:"#
                + nonEmpty(rules.alternation(rules.counters)) + #"|$|\s|"# + rules.followerPattern + #")"#,
            options: [.caseInsensitive])
        kanji = try! NSRegularExpression(
            pattern: #"^(?:(?:"# + nonEmpty(rules.kanjiPrefixPattern) + #")(["# + kanjiDigits + #"]+)|(["# + kanjiDigits + #"]+)(?:"#
                + nonEmpty(rules.alternation(rules.kanjiCounters)) + #"))"#)
        // 語の切れ目まで求める(「参加者たち」の「参」を 3 と読まないため)。
        kanjiAlone = try! NSRegularExpression(
            pattern: #"^((?:"# + nonEmpty(rules.alternation(rules.kanjiAloneDigits)) + #")+)(?:$|\s|"# + rules.followerPattern + #")"#)
        // 語で書いた数。長い語から試す(「みっかめ」を「みっか」より先に)。
        wordNumber = try! NSRegularExpression(
            pattern: #"^("# + nonEmpty(rules.alternation(Array(rules.numberWords.keys))) + #")(?:$|\s|"#
                + rules.followerPattern + #")"#,
            options: [.caseInsensitive])
        let followers = rules.followerPattern
        ordinal = try! NSRegularExpression(
            pattern: #"^第\s*(\d+(?:\.\d+)?|["# + kanjiDigits + #"]+)(?:[-‐](\d+))?\s*(?:\p{Han}|$|\s|"# + followers + #")"#)
        greek = try! NSRegularExpression(pattern: #"^([α-ω])(?:$|\s|"# + followers + #")"#)
        roman = try! NSRegularExpression(pattern: #"^(?:vol\.?\s*)?(X{0,3}(?:IX|IV|V?I{0,3}))(?:$|\s|"# + followers + #")"#)
        position = try! NSRegularExpression(
            pattern: #"^((?:"# + nonEmpty(rules.positionPattern) + #")(?:\s*\d{1,2})?)(?:$|\s)"#)
        // 続きの語は、語の切れ目を求めない(「アフターエピソード」の「アフター」は次の語とつながっている)。
        // 英字の語は大文字小文字を問わない(「EXTRA」「Extra」「extra」を一覧に 3 つ書かせない)。
        sequel = try! NSRegularExpression(pattern: #"^(?:"# + nonEmpty(rules.alternation(rules.sequelWords)) + #")"#,
                                          options: [.caseInsensitive])
        let values = [
            rules.reads(.number) ? #"\d+(?:\.\d+)?(?:[-‐~〜]\d+)?"# : nil,
            rules.reads(.kanji) ? "[" + kanjiDigits + "]+" : nil,
            rules.reads(.greek) ? "[α-ω]" : nil,
        ].compactMap { $0 }
        let counted = #"^(?:(?:"# + nonEmpty(rules.prefixPattern) + #")\s*)?(?:"# + nonEmpty(values.joined(separator: "|"))
            + #")\s*(?:"# + nonEmpty(rules.alternation(rules.counters + rules.wholeOnlyCounters)) + #")?$"#
        let positionOnly = #"^(?:"# + nonEmpty(rules.reads(.position) ? rules.positionPattern : "") + #")(?:\s*\d{1,2})?$"#
        wholeVolume = try! NSRegularExpression(pattern: counted + "|" + positionOnly, options: [.caseInsensitive])
        // シリーズ名の後ろに残す文字(naming.includeFollowing の一覧。「♡」を足せば「X♡2」の「♡」は名前に入る)は、
        // 巻の前では読み飛ばす ―― 名前に入れた文字が巻の頭に残ると、「♡2」を巻として読めない(2026-09-21、利用者の指摘)。
        leadingSeparators = text.trailingTrim.union(.whitespaces).union(CharacterSet(charactersIn: "!?！？】」』》〉)）]］>"))
            .union(CharacterSet(charactersIn: String(text.keepFollowing)))
    }

    /// 巻の表記の前後から区切りを落とす。**後ろの「〜」「-」などは、同じ記号が表記の中にもあれば残す**(対になっている ――
    /// 「XX〜YYY〜」は「XX〜YYY」にしない。2026-09-22、qooViewer の利用者の指摘)。対が無ければ今までどおり落とす(「第2巻〜」)。
    func trimSeparators(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, leadingSeparators.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, leadingSeparators.contains(last) {
            if Self.pairedMarks.contains(last), scalars.dropLast().contains(last) { break }
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// 対にして囲む(「〜サブタイトル〜」)のに使われる、波線とダッシュの類。
    static let pairedMarks = CharacterSet(charactersIn: "〜～~-‐‑‒–—―−")

    /// 読み手を優先の順に試し、最初に読めたものを採る(規則で止めた読み手は飛ばす)。
    ///
    /// 読めた表記が「そのまま読む語」に重なるなら、巻にしない(題名が「No.5」の本。語の規則は巻の読み手より前の段階なので、
    /// そこで取られた語には、後ろの段階の読み手も反応しない)。
    func extract(fromRemainder remainder: String) -> Volume? {
        guard let volume = read(fromRemainder: remainder) else { return nil }
        if let words, words.keepsAny {
            let s = trimSeparators(remainder.precomposedNFKC)
            // 読み手は残りの頭から読む。巻の表記(「No.5」の「5」)の終わりまでを、読んだ範囲とみなす。
            let found = (s as NSString).range(of: volume.text)
            let read = NSRange(location: 0, length: found.location == NSNotFound ? (volume.text as NSString).length
                                                                                  : found.location + found.length)
            if words.keptRanges(in: s).contains(where: { NSIntersectionRange($0, read).length > 0 }) { return nil }
        }
        return volume
    }

    /// 続きの語で始まるか。始まるなら、その語より後ろ(番号を書く所)を返す。
    ///
    /// **巻だけでできているか(`isWholeVolume`)には数えない。** そちらはシリーズの組み立ての 1 段目と
    /// ファイル名の `@volume` が見るもので、続きの語をそこへ入れると、タイトルの中のただの言葉
    /// (「アフターケア」)を巻と見て、別々の本を 1 つのシリーズにしてしまう。続きの語が効くのは、
    /// シリーズが決まったあとの巻の読み取りだけにする(2026-09-22、利用者の事例)。
    func sequelRest(in text: String) -> String? {
        guard rules.reads(.sequel) else { return nil }
        let s = trimSeparators(text.precomposedNFKC)
        let ns = s as NSString
        guard let m = sequel.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(from: m.range.length)
    }

    private func read(fromRemainder remainder: String) -> Volume? {
        let s = trimSeparators(remainder.precomposedNFKC)
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
        // 正規表現の `\d` は ASCII のほかの数字(アラビア・インド数字など)にも当たるが、`Int` は ASCII しか読まない。
        // 読めなければ、号として読まない(決めつけて開くと、そこでアプリが落ちる)。
        guard let year = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        guard let issue = [2, 4, 5].lazy.compactMap({ i -> Int? in
            m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i)))
        }).first else { return nil }
        return Volume(text: ns.substring(with: m.range), number: Double(year * 100 + issue))
    }

    private func read(_ reader: SeriesRules.Reader, _ s: String, _ ns: NSString, _ range: NSRange) -> Volume? {
        switch reader {
        case .ordinal:
            // 「第」が付いていれば、数字の後ろの単位は何でもよい(「第1幕」「第三部」「第2夜」)。
            guard let m = ordinal.firstMatch(in: s, range: range) else { return nil }
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
        case .kanjiAlone:
            guard let m = kanjiAlone.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            return Self.kanjiNumber(text).map { Volume(text: text, number: Double($0)) }
        case .wordNumber:
            guard let m = wordNumber.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            // 表記は名前に書いてあるまま(「ふたつ」)。並べ替えの数だけを対応表から採る。
            return rules.numberWords[text].map { Volume(text: text, number: $0) }
        case .greek:
            guard let m = greek.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            return Self.greekNumber(text).map { Volume(text: text, number: Double($0)) }
        case .roman:
            guard let m = roman.firstMatch(in: s, range: range) else { return nil }
            let text = ns.substring(with: m.range(at: 1))
            return Self.romanNumber(text).map { Volume(text: text, number: Double($0)) }
        case .position:
            guard let m = position.firstMatch(in: s, range: range) else { return nil }
            return Volume(text: ns.substring(with: m.range(at: 1)), number: nil)
        case .sequel:
            // 表記は残り全体(「アフターエピソード」。語だけを抜き出すと、名前に書いてある呼び方が消える)。
            guard sequel.firstMatch(in: s, range: range) != nil else { return nil }
            return Volume(text: s, number: nil)
        }
    }

    /// 「第」+ 数字 + 任意の漢字 1 字の単位(巻だけでできているかを見るとき。後ろの文字は問わない)。
    private static let wholeOrdinal = try! NSRegularExpression(
        pattern: #"^第\s*(?:\d+(?:\.\d+)?|[〇零一二三四五六七八九十百千壱弐参壹貳參肆伍陸柒漆捌玖拾佰仟]+)(?:[-‐]\d+)?\s*\p{Han}?$"#)

    /// 巻の後ろの括弧書き(`isWholeVolume` が除く)と、数の範囲。呼ぶたびに組み立てない。
    private static let trailingBracket = try! NSRegularExpression(pattern: #"\s*[\[(【][^\[\]()【】]*[\])】]\s*$"#)
    private static let numberRange = try! NSRegularExpression(pattern: #"(\d+)[-‐~〜](\d+)"#)

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
        // 閉じ括弧が無ければ、括弧書きは無い(正規表現を回さない。この判定は、1 つのタイトルに切れ目の数だけ呼ばれる)。
        while t.contains(where: { $0 == "]" || $0 == ")" || $0 == "】" }),
              let m = Self.trailingBracket.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)),
              m.range.location > 0 {
            t = (t as NSString).substring(to: m.range.location)
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
            if let m = Self.numberRange.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
                let parts = s[r].split(whereSeparator: { "-‐~〜".contains($0) })
                return isMergedIssue(Double(parts[0]), Int(parts[1]))
            }
            return true
        }
        // ローマ数字だけ(「II」)。
        if rules.reads(.roman), let m = roman.firstMatch(in: s, range: range), m.range.length == ns.length || m.range(at: 1).length == ns.length {
            return Self.romanNumber(ns.substring(with: m.range(at: 1))) != nil
        }
        return false
    }


    /// 漢数字を数にする。大字(壱弐参…)とその旧字体(壹貳參)・百・千・〇にも対応する
    /// (StackNest の NumeralNormalizer(MIT)の表に倣った)。
    static func kanjiNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = [
            "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
            "壱": 1, "弐": 2, "参": 3, "肆": 4, "伍": 5, "陸": 6, "柒": 7, "漆": 7, "捌": 8, "玖": 9,
            // 大字の旧字体(利用者の指摘 2026-09-22)。壹 = 壱 = 一、貳 = 弐 = 二、參 = 参 = 三。
            "壹": 1, "貳": 2, "參": 3,
        ]
        let powers: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "拾": 10, "佰": 100, "仟": 1000]
        // 位取りで書いた漢数字(「二〇」= 20、「二〇二五」= 2025)。十・百・千が 1 つも無く、2 文字以上なら桁として読む。
        // 数え上げの読み方だと「二〇」は 2 + 0 で 0 になり、読めない数になってしまう(2026-09-20、利用者の指摘)。
        if s.count >= 2, s.allSatisfy({ digits[$0] != nil }) {
            // 桁が Int に収まらない並び(「九」が 19 字以上)は数として読まない。あふれた掛け算はそこでアプリが落ちる
            // ―― 名前は外から来るもので、長さを選べない(2026-09-21 の監査)。
            var value = 0
            for ch in s {
                let (shifted, overflowed) = value.multipliedReportingOverflow(by: 10)
                let (next, carried) = shifted.addingReportingOverflow(digits[ch] ?? 0)
                guard !overflowed, !carried else { return nil }
                value = next
            }
            return value > 0 ? value : nil
        }
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
            // 並べ替え用の数は、確定していればその数、無ければ表記を巻の読み手に通して決める(「上」は文脈で後から)。
            if let volume = confirmedVolume(document.books[i].confirmation) {
                document.books[i].volumeText = volume
                document.books[i].volumeNumber = document.books[i].confirmation.fields.volumeSort
                    ?? engine.volumes.extract(fromRemainder: " " + volume)?.number
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
        if engine.rules.series.compilation.placement == .inMainSeries {
            switch engine.rules.series.compilation.volumeMode {
            case .afterRange: placeCompilationsAfterRange(&document, engine: engine, log: log)
            case .none: break
            }
        }
        if engine.volumes.rules.sharedLeadingKanjiEnabled { readLeadingKanjiNumerals(&document, engine: engine, log: log) }
        numberPositionWords(&document, engine: engine)
        numberSequels(&document, engine: engine, log: log)
        // 1 巻の推定より**後**に置く: 推定は「巻の読めない本がちょうど 1 冊か」を見るので、先に文字を
        // 入れてしまうと、番号の無い 1 冊目(「X 副題」と「X 2」の X 側)を見つけられない
        // (2026-09-21、利用者の指摘)。
        if engine.volumes.rules.inferFirstVolume { inferFirstVolumes(&document, engine: engine, log: log) }
        if engine.volumes.rules.unreadAsWritten { showRemainingText(&document, engine: engine, log: log) }
    }

    /// 本編に含めた総集編(方針 compilations = inMainSeries)の巻を、収録範囲の最後の巻の直後にする
    /// (方針 compilationVolume = afterRange。「X 総集編 1~4」は 4.5)。範囲が読めなければ巻を付けない(並びは末尾)。
    static func placeCompilationsAfterRange(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        for i in document.books.indices
        where !document.books[i].series.isEmpty && document.books[i].volumeText.isEmpty && !document.books[i].volumeConfirmed {
            let title = engine.text.comparable(document.books[i].compareTitle)
            let name = engine.text.comparable(document.books[i].series).key
            guard title.key.starts(with: name) else { continue }
            let remainder = engine.volumes.trimSeparators(title.originalRemainder(afterKeyLength: name.count))
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

    /// 位置の語で並ぶシリーズの、1 巻目の書き方(「後編」なら「前編」、「下巻」なら「上巻」)。
    ///
    /// 3 つの一覧(`positionFirst` / `positionMiddle` / `positionLast`)は**同じ並びで書く**決まりなので、
    /// ほかの本の語が何番目かを見て、同じ番目の「上」の語を選ぶ(利用者の指示 2026-09-21)。
    /// 一覧の長さが違うときは、いちばん近い所まで寄せる。
    static func firstPositionWord(_ others: [String], _ rules: SeriesRules.Volume) -> String? {
        let words = rules.positionWords
        guard !words.first.isEmpty else { return nil }
        for text in others {
            // 「後編1」のような分冊は、語の部分だけで見る。
            let word = String(text.prefix { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
            guard let i = words.middle.firstIndex(of: word) ?? words.last.firstIndex(of: word) else { continue }
            return words.first[min(i, words.first.count - 1)]
        }
        return nil
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

    /// 巻として読めなかった本は、**シリーズ名より後ろの文字列を、そのまま巻数(表示)にする**
    /// (方針 `unnumberedVolume` = `asWritten`。既定)。
    ///
    /// 並べ替えの数は付けない。「アフター」「後日談」のような語を並べて続きものと決めつけるやり方は、
    /// 名前の付け方がサークルごとに違う以上きりが無く(「小幡の場合」のような人名は語にできない)、
    /// **分かる順番だけを出し、分からない順番は空にして利用者に渡す**ことにした(2026-09-22、利用者の判断)。
    /// 順番を付けたい本は、一覧で巻数(表示)を直すか、連番を振れば数が入る。
    static func showRemainingText(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        for i in document.books.indices
        where !document.books[i].series.isEmpty && document.books[i].volumeText.isEmpty && !document.books[i].volumeConfirmed {
            let name = engine.text.comparable(document.books[i].series).key
            // **見せる文字は、名前に書いてあるとおりの題名から採る。** 比べるタイトルは版の印を外してあるので、
            // そこから採ると「架空録 新改訂版」が「新」だけになってしまう(2026-09-21、利用者の指摘)。
            // 総集編のように題名の順を直した本(「X1~4総集編」→「X 総集編 1~4」)だけは、比べる形から採る。
            let shown = engine.text.comparable(document.books[i].title)
            let title = shown.key.starts(with: name) ? shown : engine.text.comparable(document.books[i].compareTitle)
            // **語の切れ目から始まる残りだけ**を採る。シリーズ名が語の途中で切れているとき(「月の庭|の安息」)の
            // 残りは、番号の代わりに書かれた言葉ではなく語のかけらなので、巻数にしない。
            guard title.key.starts(with: name) else { continue }
            let rest = engine.volumes.trimSeparators(title.originalRemainder(afterKeyLength: name.count))
                .trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            // 区切りが無くても採る(「架空録|アルバム」「架空録|なつまつり」)。シリーズに入っている本の名前に何か
            // 書いてあるのに、巻数の欄が空のままなのはおかしい(2026-09-21、利用者の指摘)。
            // 外すのは、**助詞で始まる残り**だけ(「月の庭|の安息」は語の途中)。前はひらがなで始まる残りをすべて
            // 外していて、「なつまつり」のような新しい語まで空欄になった。助詞をひらがなの形から見分ける手立ては
            // 無いので、どれを助詞とみなすかは一覧(規則 volume.particles)が決める(2026-09-21、利用者の指示)。
            let particles = engine.rules.series.volume.particles
            guard SeriesGrouper.isCleanCut(title, at: name.count) || !particles.contains(where: { !$0.isEmpty && rest.hasPrefix($0) })
            else { continue }
            document.books[i].volumeText = rest
            log?.apply("unnumberedVolume", to: document.books[i].id)
        }
    }

    /// 本編の完結後に出た 1 冊(「アフターエピソード」「後日談」「その後」)を、**そのシリーズの最後の番号の次**に置く。
    ///
    /// 利用者の事例(2026-09-22): 番号の代わりに「アフター」と書いてある本は、名前のとおりの表記を巻数(表示用)にし、
    /// 巻数(ソート用)はシリーズのナンバリングの続きにしたい(0〜6 まである所へ来た 1 冊は 7)。
    /// 数は 1 冊ずつでは決まらないので、位置の語(上・下)と同じく、組がそろってからここで決める。
    ///
    /// 「最後の番号」に数えるのは**本編の巻だけ**。総集編・番外編は、本編の後ろへ置くためにオフセット(既定 100)を
    /// 足した数を持っているので、ナンバリングの一部として数えない(数えると「アフター」が 102 になってしまう)。
    /// 番号がどこにも無いシリーズでは、続く先が無いので数を付けない(表記だけ残す。推測で番号を作らない)。
    static func numberSequels(_ document: inout WorkingDocument, engine: RuleEngine, log: ExplanationLog?) {
        guard engine.volumes.rules.reads(.sequel) else { return }
        let seriesBooks = document.books.indices.filter { !document.books[$0].series.isEmpty }
        for (_, indices) in Dictionary(grouping: seriesBooks, by: { document.books[$0].groupID ?? -1 }) {
            let sequels = indices.filter {
                document.books[$0].volumeNumber == nil && engine.volumes.sequelRest(in: document.books[$0].volumeText) != nil
            }.sorted { document.books[$0].id < document.books[$1].id }
            guard !sequels.isEmpty else { continue }
            let numbering = indices.filter { i in
                guard document.books[i].volumeNumber != nil, !sequels.contains(i) else { return false }
                let text = document.books[i].volumeText
                return engine.compilation.keywordRange(in: text)?.lowerBound != text.startIndex
            }
            guard let last = numbering.compactMap({ document.books[$0].volumeNumber }).max() else { continue }
            // 続きの語の後ろに番号があれば、その番号だけ後ろへ(「後日談 2」は最後の巻 + 2)。
            let written = sequels.reduce(into: [Int: Double]()) { found, i in
                guard let rest = engine.volumes.sequelRest(in: document.books[i].volumeText),
                      let number = engine.volumes.extract(fromRemainder: rest)?.number else { return }
                found[i] = number
            }
            // 番号の無い続きの本が何冊もあるときは、名前の順に 1 つずつ後ろへ置く(同じ数に重ねると並びが決まらない)。
            var taken = Set(written.values)
            var next = 1.0
            for i in sequels {
                var step = written[i]
                if step == nil {
                    while taken.contains(next) { next += 1 }
                    step = next
                    taken.insert(next)
                }
                document.books[i].volumeNumber = last + step!
                log?.apply("sequel", to: document.books[i].id)
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
                let remainder = engine.volumes.trimSeparators(title.originalRemainder(afterKeyLength: name.count))
                // 「〇」は入れない。伏せ字(「〇〇さん」)と見分けが付かず、道具の側で 0 と決めてかからない
                // (2026-09-20、利用者の判断)。「第二〇巻」のように単位の付く形は、漢数字の読み手が読む。
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
            // **版違いは同じ作品なので 1 冊と数える**(「X」と「X フルカラー版」は、どちらも 1 巻。
            // 印を除いた比べるタイトルが同じなら、候補が何冊あっても迷いは無い。2026-09-21、利用者の指摘)。
            let bases = Set(candidates.map { String(engine.text.comparable(document.books[$0].compareTitle).key) })
            guard !candidates.isEmpty, bases.count == 1 else { continue }
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
            // ほかの巻が漢数字だけ(「二籠」「三鼎」)なら、推定した 1 巻も同じ書き方にする ―― 並びの中で
            // 1 冊だけ算用数字が混ざらないように(2026-09-22、利用者の指摘)。大字なら「壱」、その旧字体なら「壹」。
            let others = indices.filter { !candidates.contains($0) }
                .map { document.books[$0].volumeText }.filter { !$0.isEmpty }
            let kanji = !others.isEmpty && others.allSatisfy { $0.allSatisfy(VolumeExtractor.kanjiDigits.contains) }
            var one = !kanji ? nil
                : others.joined().contains(where: "壹貳參".contains) ? "壹"
                : others.joined().contains(where: "壱弐参肆伍陸柒漆捌玖拾佰仟".contains) ? "壱" : "一"
            // 数を語で書くシリーズ(「に」「さん」…)も同じ: 1 を表す語が対応表にあれば、それで書く。
            if one == nil, !others.isEmpty, others.allSatisfy(engine.volumes.rules.numberWords.keys.contains) {
                one = engine.volumes.rules.numberWords.filter { $0.value == 1 }.keys.sorted {
                    $0.count != $1.count ? $0.count < $1.count : $0 < $1
                }.first
            }
            // 位置の語で並ぶシリーズ(「後編」「下巻」)なら、そろいの「上」の語にする。
            if one == nil { one = Self.firstPositionWord(others, engine.volumes.rules) }
            let text = one ?? (usesRoman ? "I" : String(repeating: "0", count: max(0, width - 1)) + "1")
            for i in candidates {
                document.books[i].volumeText = text
                document.books[i].volumeNumber = 1
                document.books[i].volumeInferred = true
                log?.apply("firstVolume", to: document.books[i].id)
            }
        }
    }
}
