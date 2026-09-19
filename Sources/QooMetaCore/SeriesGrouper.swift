import Foundation

/// 番号の無いシリーズの候補を、規則だけで作る。
///
/// 方針(docs/design.md「シリーズの候補」):
/// - **同じ書き手(サークル)の中だけで比べる。** 別の書き手の偶然の一致を最初から除く。
/// - 比較用の形(ComparableText)で並べ替え、隣どうしの共通する前半部分でまとめる。
///   並べ替えれば前半が共通する本は隣り合うので、全組を比べる必要が無く、鎖のようにつながって
///   関係の薄い本まで 1 組になる(union-find で起きる)ことも無い。
/// - 組に 3 冊目以降を加えて共通部分が短くなるときは、**語の切れ目で切れる場合だけ**加える
///   (「ABCD 1」「ABCD 2」に「ABCZ」が来て、共通部分が「ABC」へ縮むのを防ぐ)。
/// - 本当にシリーズか・名前はどこまでか、の最終判断は規則ではしない(端末内モデルと利用者に任せる)。
public struct SeriesGrouper: Sendable {
    /// 語の**途中**で切れる共通部分は、この文字数(比較用の形で)以上のときだけ候補にする。
    /// 語の切れ目で切れる共通部分には掛けない(1 文字のタイトルもある)。
    public var minPrefix: Int
    /// 片方のタイトル全体がもう片方の前半と一致する場合は、この文字数まで短くても候補にする
    /// (短いシリーズ名の「X」と「X 2」)。
    public var minWholeTitle: Int

    /// 副題付きの本(「X 〇〇編」)を、巻でまとめた「X」の組に入れるか。NDL の書誌では副題付きが別の作品として
    /// 記録されていることが多く(「X : 〇〇」)、入れると NDL を正解とした適合率は下がる。どちらが正しいかは
    /// 蔵書の整理の考え方次第(docs/design.md「公開データでの検討」)。
    public var attachesSubtitledBooks: Bool

    /// 語の途中で切れる共通部分が、ひらがなで終わるなら組にしない。
    public var rejectsHiraganaEndings: Bool

    /// ネタ(`@genre`)が違う本を分けるか(方針 differentRelation)。公開データ(NDL)にはネタが無いので、そちらの採点には効かない。
    public var splitsByGenre = RuleFiles.seriesRules.grouping.splitByGenre

    /// 本の種別(`@mediatype`)が違う本を分けるか(方針 differentGenre)。
    public var splitsByMediaType = RuleFiles.seriesRules.grouping.splitByMediaType

    /// 1 段目(「タイトル + 巻」を頭でまとめる。規則 volumeHead)と 2 段目(共通する前半部分。規則 sharedPrefix)を使うか。
    public var usesVolumeHeads = RuleFiles.seriesRules.grouping.volumeHeadEnabled
    public var usesSharedPrefixes = RuleFiles.seriesRules.grouping.sharedPrefixEnabled

    /// 一般的な英語だけのタイトルでも、後ろに巻があれば組にする。
    public var commonEnglishUnlessVolume = RuleFiles.seriesRules.grouping.commonEnglishUnlessVolume

    /// 本編のシリーズがあれば、総集編が 1 冊でもシリーズにする。
    public var singleCompilationWithMain = RuleFiles.seriesRules.grouping.compilationSingleWhenMainExists

    /// 既定値は series-rules.json の grouping。
    public init(minPrefix: Int = RuleFiles.seriesRules.grouping.minPrefix,
                minWholeTitle: Int = RuleFiles.seriesRules.grouping.minWholeTitle,
                attachesSubtitledBooks: Bool = RuleFiles.seriesRules.grouping.attachSubtitled,
                rejectsHiraganaEndings: Bool = RuleFiles.seriesRules.grouping.rejectHiraganaEndings) {
        self.minPrefix = minPrefix
        self.minWholeTitle = minWholeTitle
        self.attachesSubtitledBooks = attachesSubtitledBooks
        self.rejectsHiraganaEndings = rejectsHiraganaEndings
    }

    /// 語の切れ目で切れる共通部分でも、2 冊とも一般的な英単語だけのタイトルなら組にしない(EnglishWords)。
    public var rejectsCommonEnglishTitles = RuleFiles.seriesRules.grouping.rejectCommonEnglishTitles

    /// その位置で切ると、元の表記で数字の途中になるか(「2022-01」の「-」は比較用の形では消えるので、元の表記で見る)。
    static func splitsANumber(_ text: ComparableText, at length: Int) -> Bool {
        guard length > 0, length < text.key.count else { return false }
        let chars = Array(text.original)
        let end = text.originalEnd[length - 1]
        return end < chars.count && chars[end].isNumber && chars[end - 1].isNumber
    }

    /// 比較用の先頭 `length` 文字より後ろが巻で始まるか。
    static func hasVolume(_ text: ComparableText, after length: Int) -> Bool {
        VolumeExtractor.extract(fromRemainder: text.originalRemainder(afterKeyLength: length)) != nil
    }

    /// 語の途中で切れる共通部分が 1 語(文字種の 1 続き)なら組にしない。
    public var rejectsSingleWordPrefixes = RuleFiles.seriesRules.grouping.rejectSingleWordPrefixes

    enum Script { case hiragana, katakana, han, latin, digit, other }

    static func script(_ ch: Character) -> Script {
        guard let v = ch.unicodeScalars.first?.value else { return .other }
        switch v {
        case 0x3041...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: return .han
        case 0x30...0x39: return .digit
        default: return ch.isLetter ? .latin : .other
        }
    }

    static func isSingleScriptRun(_ chars: [Character]) -> Bool {
        guard let first = chars.first else { return true }
        let s = script(first)
        return chars.allSatisfy { script($0) == s }
    }

    static func isHiragana(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// **ネタ(末尾の丸括弧、`@genre`)が違う本は同じシリーズにしない**(利用者の指摘。先頭の 1 語が一致しただけの別作品)。組をネタごとに分け、ネタの書かれていない本は
    /// いちばん大きい組へ入れる。分けた結果 2 冊に満たない組は捨てる。
    func splitByGenre(_ groups: [SeriesGroup], books: [BookProposal]) -> [SeriesGroup] {
        guard splitsByGenre else { return groups }
        let genreByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, String(ComparableText($0.parsed.trailing).key)) })
        var result: [SeriesGroup] = []
        for group in groups {
            let byGenre = Dictionary(grouping: group.memberIDs.filter { !(genreByID[$0] ?? "").isEmpty }) { genreByID[$0]! }
            guard byGenre.count >= 2 else { result.append(group); continue }
            let unlabeled = group.memberIDs.filter { (genreByID[$0] ?? "").isEmpty }
            let largest = byGenre.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key }!.key
            for (genre, ids) in byGenre.sorted(by: { $0.key < $1.key }) {
                let members = (genre == largest ? ids + unlabeled : ids).sorted()
                guard members.count >= 2 else { continue }
                var g = group
                g.memberIDs = members
                result.append(g)
            }
        }
        return result
    }

    /// 総集編なら、その名前(「X 総集編」「X フルカラー総集編」)と、本編のシリーズ名の候補(「X」)。
    /// タイトルの先頭が「総集編」の本(本編の名前が無い)は対象にしない。
    /// 収録範囲が総集編の前に書かれている形(「X1~4総集編」)は、BookScanner が「X 総集編 1~4」に並べ替えてある
    /// (Compilation.normalizedTitle)。
    static func compilation(_ title: String) -> (name: String, mains: [String])? {
        guard let r = Compilation.keywordRange(in: title), r.lowerBound > title.startIndex else { return nil }
        let head = String(title[..<r.lowerBound])
        let main = TextRules.trimSeriesName(head)
        guard !main.isEmpty else { return nil }
        var mains = [main]
        // 「X フルカラー総集編」の「フルカラー」のような、総集編の直前の語を除いた名前も本編の候補にする。
        if !head.hasSuffix(" "), let space = main.lastIndex(where: \.isWhitespace) {
            mains.append(TextRules.trimSeriesName(String(main[..<space])))
        }
        return (TextRules.trimSeriesName(head + String(title[r])), mains)
    }

    /// 版違い・入手経路違いだけでできた組はシリーズにしない(同じ作品。利用者との取り決め)。
    /// 印(EditionMarkers)を除いたタイトルが 2 種類以上ある組だけを残す。1 冊でもよい組(本編のある総集編)は残す。
    func dissolveSameWorkOnly(_ groups: [SeriesGroup], books: [BookProposal]) -> [SeriesGroup] {
        let baseByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, String(ComparableText($0.parsed.baseTitle).key)) })
        return groups.filter { g in
            g.allowsSingle == true || Set(g.memberIDs.compactMap { baseByID[$0] }).count >= 2
        }
    }

    /// 比べる単位。書き手 + 本の種別(qooLibrary の `@mediatype`)。**本の種別が違う本は同じシリーズにしない**
    /// (同人の本と商業の単行本のような発行形態の違い。利用者の指摘)。種別が読めなかった本は書き手だけで比べる。
    func partitionKey(_ book: BookProposal) -> String {
        let mediaType = splitsByMediaType ? String(ComparableText(book.parsed.mediaType ?? "").key) : ""
        return mediaType.isEmpty ? book.circleKey : "\(book.circleKey)\u{1}\(mediaType)"
    }

    public func group(_ books: [BookProposal]) -> [SeriesGroup] {
        let byCircle = Dictionary(grouping: books, by: partitionKey)
        var groups: [SeriesGroup] = []
        for circleKey in byCircle.keys.sorted() {
            // 総集編は本編と分けて扱う(Self.compilation)。
            let compilations = byCircle[circleKey]!.compactMap { b in Self.compilation(b.parsed.baseTitle).map { (b, $0) } }
            let compilationIDs = Set(compilations.map(\.0.id))
            let items = byCircle[circleKey]!
                .filter { !compilationIDs.contains($0.id) }
                .map { (id: $0.id, text: ComparableText($0.parsed.baseTitle)) }
                .filter { !$0.text.key.isEmpty }
            let groupsBefore = groups.count

            // 1 段目: 「タイトル + 巻」の形の本を、巻を除いた頭の部分でまとめる。
            // 並べ替えた隣どうしで比べるだけだと、「三国志 21」と「三国志 第1巻」の間に「三国志演義」の
            // ような別のタイトルが挟まり、組が切れる(NDL の書誌で測った取りこぼしの主因)。
            var byHead: [String: [(id: Int, text: ComparableText, headLength: Int)]] = [:]
            var rest: [(id: Int, text: ComparableText)] = []
            for item in items {
                // 後ろが巻だけでできていることを求めるので、頭は 1 文字でもよい(「咲 18」)。
                if usesVolumeHeads, let head = Self.volumeHeadLength(item.text, minLength: 1) {
                    byHead[String(item.text.key.prefix(head)), default: []].append((item.id, item.text, head))
                } else {
                    rest.append(item)
                }
            }
            var headGroups: [(key: String, members: [(id: Int, text: ComparableText, headLength: Int)])] = []
            // 辞書の並びはプロセスごとに変わるので、キーの順に並べてから使う。下の「1 冊だけの頭の組を移す」処理は
            // 組の並びで結果が変わりうる(同じ入力なら毎回同じ結果にする。api.md「方針」の 5)。
            for (key, members) in byHead.sorted(by: { $0.key < $1.key }) {
                // 巻の無い本(「X」)が同じ頭なら、その組に入れる(1 巻目に番号が無いことは多い)。
                var members = members
                rest.removeAll { item in
                    guard String(item.text.key) == key else { return false }
                    members.append((item.id, item.text, item.text.key.count))
                    return true
                }
                headGroups.append((key, members))
            }
            // 1 冊だけの頭の組は、もっと短い頭の組に語の切れ目で当たるなら、そちらへ移す。
            // 「X2～副題 1～」のように末尾の別の番号を巻と読んで長い頭になった本を、「X」の組へ戻すため。
            // 長い頭から順に見る(移す先がまだ移されていないうちに。並びで結果が変わらないように)。
            let longestFirst = headGroups.indices.sorted {
                headGroups[$0].key.count != headGroups[$1].key.count
                    ? headGroups[$0].key.count > headGroups[$1].key.count : headGroups[$0].key < headGroups[$1].key
            }
            for g in longestFirst where headGroups[g].members.count == 1 {
                let m = headGroups[g].members[0]
                let key = String(m.text.key)
                guard let h = headGroups.indices
                    .filter({ $0 != g && headGroups[$0].key.count < headGroups[g].key.count
                        && key.hasPrefix(headGroups[$0].key) && Self.isCleanCut(m.text, at: headGroups[$0].key.count) })
                    .max(by: { headGroups[$0].key.count < headGroups[$1].key.count }) else { continue }
                headGroups[h].members.append((m.id, m.text, headGroups[h].key.count))
                headGroups[g].members = []
            }
            headGroups.removeAll { $0.members.isEmpty }
            // 副題付きの本(「X 〇〇編」「X 番外編」)は、頭が語の切れ目で一致する組へ入れる(いちばん長い頭)。
            if attachesSubtitledBooks {
                let heads = headGroups.indices.sorted { headGroups[$0].key.count > headGroups[$1].key.count }
                rest.removeAll { item in
                    let key = String(item.text.key)
                    guard let h = heads.first(where: { key.hasPrefix(headGroups[$0].key)
                        && Self.isCleanCut(item.text, at: headGroups[$0].key.count) }) else { return false }
                    headGroups[h].members.append((item.id, item.text, headGroups[h].key.count))
                    return true
                }
            }
            // 2 冊に満たない頭の組は解いて、2 段目へ回す(副題付きの本を受け入れてから判断する)。
            for group in headGroups where group.members.count < 2 {
                rest += group.members.map { ($0.id, $0.text) }
            }
            headGroups.removeAll { $0.members.count < 2 }
            for (_, members) in headGroups.sorted(by: { $0.key < $1.key }) {
                let first = members.min { $0.id < $1.id }!
                groups.append(SeriesGroup(
                    id: 0, circleKey: circleKey.components(separatedBy: "\u{1}")[0], memberIDs: members.map(\.id).sorted(),
                    ruleName: TextRules.trimSeriesName(first.text.originalPrefix(keyLength: first.headLength)),
                    cleanBoundary: true, circlesSharingPrefix: 0))
            }

            // 2 段目: 残りを、共通する前半部分でまとめる。
            let sorted = rest.sorted { String($0.text.key) < String($1.text.key) }
            for run in (usesSharedPrefixes ? runs(sorted) : []) where run.count >= 2 {
                let prefixLength = run.map(\.prefixLength).min()!
                let first = run[0].item.text
                groups.append(SeriesGroup(
                    id: 0,
                    circleKey: circleKey.components(separatedBy: "\u{1}")[0],
                    memberIDs: run.map(\.item.id),
                    ruleName: TextRules.trimSeriesName(first.originalPrefix(keyLength: prefixLength)),
                    cleanBoundary: run.allSatisfy { Self.isCleanCut($0.item.text, at: prefixLength) },
                    circlesSharingPrefix: 0
                ))
            }

            // 総集編: 「X 総集編」ごとにまとめる。2 冊以上か、本編のシリーズ「X」がこの書き手にあれば(1 冊でも)シリーズ。
            // 番号の無い最初の総集編のあとに「総集編2」が出ることがあるので、番号の有無で分け方を変えない(利用者の判断)。
            let mainKeys = Set(groups[groupsBefore...].map { String(ComparableText($0.ruleName).key) })
            let byName = Dictionary(grouping: compilations) { String(ComparableText($0.1.name).key) }
            for key in byName.keys.sorted() {
                let members = byName[key]!
                let hasMain = members[0].1.mains.contains { mainKeys.contains(String(ComparableText($0).key)) }
                guard members.count >= 2 || (hasMain && singleCompilationWithMain) else { continue }
                var g = SeriesGroup(
                    id: 0, circleKey: circleKey.components(separatedBy: "\u{1}")[0],
                    memberIDs: members.map(\.0.id).sorted(), ruleName: members.min { $0.0.id < $1.0.id }!.1.name,
                    cleanBoundary: true, circlesSharingPrefix: 0)
                g.allowsSingle = hasMain && singleCompilationWithMain
                groups.append(g)
            }
        }
        groups = splitByGenre(groups, books: books)
        groups = dissolveSameWorkOnly(groups, books: books)
        // ありふれた言葉の疑い: この前半部分で始まるタイトルを持つ書き手の数。
        let titleKeysByCircle = Dictionary(grouping: books, by: \.circleKey)
            .mapValues { $0.map { String(ComparableText($0.parsed.baseTitle).key) } }
        for i in groups.indices {
            let prefix = String(ComparableText(groups[i].ruleName).key)
            groups[i].circlesSharingPrefix = prefix.isEmpty ? 0 : titleKeysByCircle.values
                .filter { keys in keys.contains { $0.hasPrefix(prefix) } }.count
            groups[i].id = i + 1
        }
        return groups
    }

    private struct Member { let item: (id: Int, text: ComparableText); var prefixLength: Int }

    private func runs(_ items: [(id: Int, text: ComparableText)]) -> [[Member]] {
        var result: [[Member]] = []
        var run: [Member] = []
        var runPrefix = 0
        for item in items {
            guard let last = run.last else {
                run = [Member(item: item, prefixLength: item.text.key.count)]
                runPrefix = item.text.key.count
                continue
            }
            let l = Self.commonPrefixLength(Array(last.item.text.key.prefix(runPrefix)), item.text.key)
            let shorter = min(runPrefix, item.text.key.count)
            let accepts: Bool
            // **文字数の下限は、語の途中で切れる一致にだけ掛ける。** 両方とも語の切れ目(空白・記号・数字の手前)で
            // 切れているなら、1 文字の共通部分でも同じ組にする(「咲 18」「亜人 3」「風光る 〇〇編」)。
            // 固定の n 文字にしていた頃は、NDL の書誌で取りこぼしのほとんどが 3 文字以下のタイトルだった
            // (docs/design.md「公開データでの検討」)。
            // ただし、2 冊とも一般的な英単語だけでできたタイトルなら採らない。
            // ありふれた英語が重なっただけで手がかりにならない(利用者の指摘)。後ろに巻があれば組にする。
            let cleanOnBothSides = l >= 1 && Self.isCleanCut(last.item.text, at: l) && Self.isCleanCut(item.text, at: l)
                && !(rejectsCommonEnglishTitles
                     && EnglishWords.isCommonEnglishOnly(last.item.text.original)
                     && EnglishWords.isCommonEnglishOnly(item.text.original)
                     && !(commonEnglishUnlessVolume && (Self.hasVolume(last.item.text, after: l) || Self.hasVolume(item.text, after: l))))
            // 語の途中で切れる一致が、ひらがな(「の」「と」などの助詞)で終わるなら採らない。
            // 言い回しが重なっただけの別作品(利用者の指摘)。
            // 共通部分が文字種の 1 続き(カタカナだけ・漢字だけ…)なら、それは 1 語でしかない。語の途中で切れる一致としては
            // 採らない(キャラクター名のような 1 語で始まる別作品。利用者の指摘)。
            let midWordAccepted = l >= minPrefix
                && !(rejectsHiraganaEndings && !cleanOnBothSides && Self.isHiragana(item.text.key[l - 1]))
                && !(rejectsSingleWordPrefixes && !cleanOnBothSides && Self.isSingleScriptRun(Array(item.text.key.prefix(l))))
            if run.count == 1 {
                accepts = midWordAccepted || cleanOnBothSides || (l >= minWholeTitle && l == shorter)
            } else if l == runPrefix {
                accepts = true
            } else {
                accepts = l >= 1
                    && run.allSatisfy { Self.isCleanCut($0.item.text, at: l) }
                    && Self.isCleanCut(item.text, at: l)
            }
            if accepts {
                runPrefix = l
                run.append(Member(item: item, prefixLength: l))
                for i in run.indices { run[i].prefixLength = l }
            } else {
                result.append(run)
                run = [Member(item: item, prefixLength: item.text.key.count)]
                runPrefix = item.text.key.count
            }
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    /// 「タイトル + 巻」の形なら、巻を除いた頭の長さ(比較用の形で)。語の切れ目で切れていて、
    /// 後ろが巻だけでできている、いちばん短い頭を採る(長い方から探すと「X Vol.5」の頭が「X Vol」に、
    /// 「X 21」の頭が「X 2」になる)。
    static func volumeHeadLength(_ text: ComparableText, minLength: Int) -> Int? {
        guard text.key.count > minLength else { return nil }
        for length in minLength..<text.key.count
        where !Self.splitsANumber(text, at: length)
            && isCleanCut(text, at: length)
            && VolumeExtractor.isWholeVolume(text.originalRemainder(afterKeyLength: length)) {
            return length
        }
        return nil
    }

    private static let volumeMarker = try! NSRegularExpression(pattern: #"^(?:ver|vol)(?:\.|\s|\d)"#, options: [.caseInsensitive])

    static func startsWithVolumeMarker(_ s: String) -> Bool {
        let n = s.precomposedNFKC
        return volumeMarker.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
    }

    static func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    /// 比較用の先頭 `length` 文字で切ったとき、元の表記で語の切れ目になっているか。
    static func isCleanCut(_ text: ComparableText, at length: Int) -> Bool {
        guard length > 0 else { return false }
        if length >= text.key.count { return true }
        // 比較用の形で飛ばした記号・空白が挟まっていれば切れ目。
        let end = text.originalEnd[length - 1]
        let chars = Array(text.original)
        if end < chars.count, TextRules.isBoundary(chars[end]) { return true }
        // 漢字・かなの直後に英字が続くなら切れ目(「Xex」「X DX」の空白なし)。
        if end < chars.count, end > 0, chars[end].isASCII, chars[end].isLetter, !chars[end - 1].isASCII,
           chars[end - 1].isLetter { return true }
        // 「ver」「vol」が名前に続けて書かれた巻の印なら切れ目(「Xver.48」)。
        if end < chars.count, startsWithVolumeMarker(String(chars[end...])) { return true }
        // 次が数字なら切れ目(「X2」の X と 2)。
        return text.key[length].isNumber
    }
}
