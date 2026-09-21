import Foundation

/// 番号の無いシリーズの候補を、規則だけで作る。
///
/// 方針(docs/design.md「シリーズの候補」):
/// - **同じ書き手の中だけで比べる。** 別の書き手の偶然の一致を最初から除く。
/// - 比較用の形(ComparableText)で並べ替え、隣どうしの共通する前半部分でまとめる。
///   並べ替えれば前半が共通する本は隣り合うので、全組を比べる必要が無く、鎖のようにつながって
///   関係の薄い本まで 1 組になる(union-find で起きる)ことも無い。
/// - 組に 3 冊目以降を加えて共通部分が短くなるときは、**語の切れ目で切れる場合だけ**加える
///   (「ABCD 1」「ABCD 2」に「ABCZ」が来て、共通部分が「ABC」へ縮むのを防ぐ)。
/// - 本当にシリーズか・名前はどこまでか、の最終判断は規則ではしない(端末内モデルと利用者に任せる)。
struct SeriesGrouper: Sendable {
    /// 語の**途中**で切れる共通部分は、この文字数(比較用の形で)以上のときだけ候補にする。
    /// 語の切れ目で切れる共通部分には掛けない(1 文字のタイトルもある)。
    var minPrefix: Int
    /// 片方のタイトル全体がもう片方の前半と一致する場合は、この文字数まで短くても候補にする
    /// (短いシリーズ名の「X」と「X 2」)。
    var minWholeTitle: Int

    /// 組の名前そのものが「別の組の名前 + 巻」になっている組を、その別の組へ入れるか(規則 mergeVolumeSubgroups)。
    var mergesVolumeSubgroups: Bool

    /// 区切りなしで続く副題の本(「X リベンジ」の X とカタカナの境)も、その組に入れるか(規則 attachAcrossScript)。
    /// **文字の種類が変わる所だけ**を切れ目とみなす、ゆるい判定。すでに巻でまとまった組へ**入れるときにだけ**使い、
    /// 新しい組を作るのには使わない(日本語は語の中で文字種が変わるので、組を作る手がかりには弱い)。
    var attachesAcrossScript: Bool

    /// 副題付きの本(「X 〇〇編」)を、巻でまとめた「X」の組に入れるか。NDL の書誌では副題付きが別の作品として
    /// 記録されていることが多く(「X : 〇〇」)、入れると NDL を正解とした適合率は下がる。どちらが正しいかは
    /// 蔵書の整理の考え方次第(docs/design.md「公開データでの検討」)。
    var attachesSubtitledBooks: Bool

    /// 語の途中で切れる共通部分が、ひらがなで終わるなら組にしない。
    var rejectsHiraganaEndings: Bool

    /// 原作(`@source`)が違う本を分けるか(方針 differentRelation)。公開データ(NDL)には原作が無いので、そちらの採点には効かない。
    var splitsByRelation: Bool

    /// ジャンル(`@genre`)が違う本を分けるか(方針 differentGenre)。
    var splitsByGenre: Bool

    /// 1 段目(「タイトル + 巻」を頭でまとめる。規則 volumeHead)と 2 段目(共通する前半部分。規則 sharedPrefix)を使うか。
    var usesVolumeHeads: Bool
    var usesSharedPrefixes: Bool

    /// 一般的な英語だけのタイトルでも、後ろに巻があれば組にする。
    var commonEnglishUnlessVolume: Bool

    /// 本編のシリーズがあれば、総集編が 1 冊でもシリーズにする。
    var singleCompilationWithMain: Bool

    /// 語の切れ目で切れる共通部分でも、2 冊とも一般的な英単語だけのタイトルなら組にしない(EnglishWords)。
    var rejectsCommonEnglishTitles: Bool

    /// 語の途中で切れる共通部分が 1 語(文字種の 1 続き)なら組にしない。
    var rejectsSingleWordPrefixes: Bool

    /// 説明の材料を書き留める先(説明を作るときだけ)。
    var log: ExplanationLog?

    /// 比べ方・巻の読み方・辞書(規則から作ったもの)。
    let engine: RuleEngine
    var text: TextRules { engine.text }

    /// 既定値は規則の grouping と policies。`minPrefix` だけは、公開データでの比較のために直接渡せる。
    init(engine: RuleEngine, minPrefix: Int? = nil) {
        let g = engine.rules.series.grouping
        self.engine = engine
        self.minPrefix = minPrefix ?? g.minPrefix
        minWholeTitle = g.minWholeTitle
        attachesSubtitledBooks = g.attachSubtitled
        attachesAcrossScript = g.attachAcrossScript
        mergesVolumeSubgroups = g.mergeVolumeSubgroups
        rejectsHiraganaEndings = g.rejectHiraganaEndings
        splitsByRelation = g.splitByRelation
        splitsByGenre = g.splitByGenre
        usesVolumeHeads = g.volumeHeadEnabled
        usesSharedPrefixes = g.sharedPrefixEnabled
        commonEnglishUnlessVolume = g.commonEnglishUnlessVolume
        singleCompilationWithMain = g.compilationSingleWhenMainExists
        rejectsCommonEnglishTitles = g.rejectCommonEnglishTitles
        rejectsSingleWordPrefixes = g.rejectSingleWordPrefixes
    }

    /// その位置で切ると、元の表記で数字の途中になるか(「2022-01」の「-」は比較用の形では消えるので、元の表記で見る)。
    static func splitsANumber(_ text: ComparableText, at length: Int) -> Bool {
        guard length > 0, length < text.key.count else { return false }
        let chars = Array(text.original)
        let end = text.originalEnd[length - 1]
        return end < chars.count && isDigit(chars[end]) && isDigit(chars[end - 1])
    }

    /// 位取りの数字(算用数字と全角数字)。**漢数字は数えない** ―― 「〇」は伏せ字(「〇〇さん」)にも使う字で、
    /// 数として書かれたとは限らない。数かどうかを道具の側で決めてかからない(2026-09-20、利用者の判断)。
    static func isDigit(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x30...0x39).contains(v) || (0xFF10...0xFF19).contains(v)
    }

    /// 比較用の先頭 `length` 文字より後ろが巻で始まるか。
    func hasVolume(_ text: ComparableText, after length: Int) -> Bool {
        engine.volumes.extract(fromRemainder: text.originalRemainder(afterKeyLength: length)) != nil
    }


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

    /// 区切りの無い所で、**次の語が始まっているとみなせるか**。文字の種類が変わり、しかも続きがひらがなでない
    /// ことを見る ―― ひらがなが続くのは語の途中(「灯|り咲く庭」)、カタカナや英字が続くのは副題
    /// (「彼女催眠|リベンジ」)。すでに巻でまとまった組へ入れるときと、残りを巻数(表示)にするときに使う
    /// (2026-09-21、利用者の指示)。
    static func startsNewWord(_ text: ComparableText, at length: Int) -> Bool {
        guard length > 0, length < text.key.count else { return false }
        let next = text.key[length]
        guard !isHiragana(next) else { return false }
        return script(text.key[length - 1]) != script(next)
    }

    static func isSingleScriptRun(_ chars: [Character]) -> Bool {
        guard let first = chars.first else { return true }
        let s = script(first)
        return chars.allSatisfy { script($0) == s }
    }

    static func isHiragana(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// **原作(`@source`)が違う本は同じシリーズにしない**(利用者の指摘。先頭の 1 語が一致しただけの別作品)。組を原作ごとに分け、原作の書かれていない本は
    /// いちばん大きい組へ入れる。分けた結果 2 冊に満たない組は捨てる。
    func splitByRelation(_ groups: [CandidateGroup], books: [WorkingBook]) -> [CandidateGroup] {
        guard splitsByRelation else { return groups }
        let relationByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, String(text.comparable($0.source).key)) })
        var result: [CandidateGroup] = []
        for group in groups {
            let byRelation = Dictionary(grouping: group.memberIDs.filter { !(relationByID[$0] ?? "").isEmpty }) { relationByID[$0]! }
            guard byRelation.count >= 2 else { result.append(group); continue }
            let unlabeled = group.memberIDs.filter { (relationByID[$0] ?? "").isEmpty }
            let largest = byRelation.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key }!.key
            if let log {
                // 原作の違う本どうしは、組になりかけて分けられた。
                let keyByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, text.comparable($0.compareTitle).key) })
                for (x, xs) in byRelation { for (y, ys) in byRelation where x < y { for a in xs { for b in ys {
                    log.miss(a, b, length: Self.commonPrefixLength(keyByID[a] ?? [], keyByID[b] ?? []), rule: "splitByRelation")
                } } } }
                for id in group.memberIDs { log.apply("splitByRelation", to: id) }
            }
            for (relation, ids) in byRelation.sorted(by: { $0.key < $1.key }) {
                let members = (relation == largest ? ids + unlabeled : ids).sorted()
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
    func compilation(_ title: String) -> (name: String, mains: [String])? {
        guard let r = engine.compilation.keywordRange(in: title), r.lowerBound > title.startIndex else { return nil }
        let head = String(title[..<r.lowerBound])
        let main = text.trimSeriesName(head)
        guard !main.isEmpty else { return nil }
        var mains = [main]
        // 「X フルカラー総集編」の「フルカラー」のような、総集編の直前の語を除いた名前も本編の候補にする。
        if !head.hasSuffix(" "), let space = main.lastIndex(where: \.isWhitespace) {
            mains.append(text.trimSeriesName(String(main[..<space])))
        }
        return (text.trimSeriesName(head + String(title[r])), mains)
    }

    /// 版違い・入手経路違いだけでできた組はシリーズにしない(同じ作品。利用者との取り決め)。
    /// 印(EditionMarkers)を除いたタイトルが 2 種類以上ある組だけを残す。1 冊でもよい組(本編のある総集編)は残す。
    func dissolveSameWorkOnly(_ groups: [CandidateGroup], books: [WorkingBook]) -> [CandidateGroup] {
        let baseByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, String(text.comparable($0.compareTitle).key)) })
        return groups.filter { g in
            let keep = g.allowsSingle == true || Set(g.memberIDs.compactMap { baseByID[$0] }).count >= 2
            if !keep, let log {
                for a in g.memberIDs { for b in g.memberIDs where a < b {
                    log.miss(a, b, length: baseByID[a]?.count ?? 0, rule: "rejectSameWork")
                } }
            }
            return keep
        }
    }

    /// 比べる単位。書き手 + ジャンル。**ジャンルが違う本は同じシリーズにしない**
    /// (同人の本と商業の単行本のような発行形態の違い。利用者の指摘)。ジャンルの空の本は書き手だけで比べる。
    func partitionKey(_ book: WorkingBook) -> String {
        let genre = splitsByGenre ? String(text.comparable(book.genre).key) : ""
        return genre.isEmpty ? book.writerKey : "\(book.writerKey)\u{1}\(genre)"
    }

    func group(_ books: [WorkingBook]) -> [CandidateGroup] {
        let byWriter = Dictionary(grouping: books, by: partitionKey)
        var groups: [CandidateGroup] = []
        for writerKey in byWriter.keys.sorted() {
            // 総集編は本編と分けて扱う(Self.compilation)。
            let compilations = byWriter[writerKey]!.compactMap { b in compilation(b.compareTitle).map { (b, $0) } }
            let compilationIDs = Set(compilations.map(\.0.id))
            let items = byWriter[writerKey]!
                .filter { !compilationIDs.contains($0.id) }
                .map { (id: $0.id, text: text.comparable($0.compareTitle)) }
                .filter { !$0.text.key.isEmpty }
            let groupsBefore = groups.count

            // 1 段目: 「タイトル + 巻」の形の本を、巻を除いた頭の部分でまとめる。
            // 並べ替えた隣どうしで比べるだけだと、「三国志 21」と「三国志 第1巻」の間に「三国志演義」の
            // ような別のタイトルが挟まり、組が切れる(NDL の書誌で測った取りこぼしの主因)。
            var byHead: [String: [(id: Int, text: ComparableText, headLength: Int)]] = [:]
            var rest: [(id: Int, text: ComparableText)] = []
            let precomputedHeads = Dictionary(uniqueKeysWithValues: byWriter[writerKey]!.map { ($0.id, $0.volumeHead) })
            for item in items {
                // 後ろが巻だけでできていることを求めるので、頭は 1 文字でもよい(「咲 18」)。
                if usesVolumeHeads,
                   let head = precomputedHeads[item.id].flatMap({ $0 }) ?? volumeHeadLength(item.text, minLength: 1) {
                    byHead[String(item.text.key.prefix(head)), default: []].append((item.id, item.text, head))
                } else {
                    rest.append(item)
                }
            }
            var headGroups: [(key: String, members: [(id: Int, text: ComparableText, headLength: Int)])] = []
            // 辞書の並びはプロセスごとに変わるので、キーの順に並べてから使う。下の「1 冊だけの頭の組を移す」処理は
            // 組の並びで結果が変わりうる(同じ入力なら毎回同じ結果にする。api.md「方針」の 5)。
            // **頭の組は、鍵で引く。** 組と本を総当たりで見比べると、冊数の 2 乗の時間がかかる。どの型にも合わない名前は
            // 書き手が空で、蔵書の全体が 1 つの単位になるので、2 万冊で 25 秒かかっていた(2026-09-21 の監査)。
            // 本の鍵の頭を長いほうから順に切り出して引けば、1 冊あたり鍵の長さぶんで済み、結果は同じ。
            let restByKey = Dictionary(grouping: rest.indices) { String(rest[$0].text.key) }
            var movedFromRest = Set<Int>()
            for (key, members) in byHead.sorted(by: { $0.key < $1.key }) {
                // 巻の無い本(「X」)が同じ頭なら、その組に入れる(1 巻目に番号が無いことは多い)。
                var members = members
                for i in restByKey[key] ?? [] {
                    members.append((rest[i].id, rest[i].text, rest[i].text.key.count))
                    movedFromRest.insert(i)
                }
                headGroups.append((key, members))
            }
            if !movedFromRest.isEmpty { rest = rest.indices.filter { !movedFromRest.contains($0) }.map { rest[$0] } }
            /// 本の鍵の頭に当たる組のうち、`accepts` が通す、いちばん長い頭のもの(`below` より短い頭だけを見る)。
            func longestHead(of text: ComparableText, below limit: Int, in index: [String: Int],
                             where accepts: (Int) -> Bool) -> Int? {
                let chars = Array(String(text.key))
                for length in stride(from: min(limit - 1, chars.count), through: 1, by: -1) {
                    if let h = index[String(chars[..<length])], accepts(length) { return h }
                }
                return nil
            }
            // 1 冊だけの頭の組は、もっと短い頭の組に語の切れ目で当たるなら、そちらへ移す。
            // 「X2～副題 1～」のように末尾の別の番号を巻と読んで長い頭になった本を、「X」の組へ戻すため。
            // 長い頭から順に見る(移す先がまだ移されていないうちに。並びで結果が変わらないように)。
            let keyCounts = headGroups.map(\.key.count)
            let longestFirst = headGroups.indices.sorted {
                keyCounts[$0] != keyCounts[$1] ? keyCounts[$0] > keyCounts[$1] : headGroups[$0].key < headGroups[$1].key
            }
            let headIndex = Dictionary(headGroups.indices.map { (headGroups[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
            for g in longestFirst where headGroups[g].members.count == 1 {
                let m = headGroups[g].members[0]
                guard let h = longestHead(of: m.text, below: keyCounts[g], in: headIndex,
                                          where: { Self.isCleanCut(m.text, at: $0) }) else { continue }
                headGroups[h].members.append((m.id, m.text, keyCounts[h]))
                headGroups[g].members = []
            }
            headGroups.removeAll { $0.members.isEmpty }
            // 副題付きの本(「X 〇〇編」「X 番外編」)は、頭が語の切れ目で一致する組へ入れる(いちばん長い頭)。
            if attachesSubtitledBooks {
                let attachIndex = Dictionary(headGroups.indices.map { (headGroups[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
                rest.removeAll { item in
                    guard let h = longestHead(of: item.text, below: Int.max, in: attachIndex, where: { length in
                        Self.isCleanCut(item.text, at: length)
                            || (attachesAcrossScript && Self.startsNewWord(item.text, at: length))
                    }) else { return false }
                    headGroups[h].members.append((item.id, item.text, headGroups[h].key.count))
                    log?.apply(Self.isCleanCut(item.text, at: headGroups[h].key.count)
                        ? "subtitled" : "attachAcrossScript", to: item.id)
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
                var g = CandidateGroup(
                    id: 0, writerKey: writerKey.components(separatedBy: "\u{1}")[0], memberIDs: members.map(\.id).sorted(),
                    ruleName: text.trimSeriesName(first.text.originalPrefix(keyLength: first.headLength)),
                    cleanBoundary: true, writersSharingPrefix: 0)
                g.evidence = .volumeHead
                groups.append(g)
            }

            // 2 段目: 残りを、共通する前半部分でまとめる。
            let sorted = rest.sorted { String($0.text.key) < String($1.text.key) }
            for run in (usesSharedPrefixes ? runs(sorted) : []) where run.count >= 2 {
                let prefixLength = run.map(\.prefixLength).min()!
                let first = run[0].item.text
                var g = CandidateGroup(
                    id: 0,
                    writerKey: writerKey.components(separatedBy: "\u{1}")[0],
                    memberIDs: run.map(\.item.id),
                    ruleName: text.trimSeriesName(first.originalPrefix(keyLength: prefixLength)),
                    cleanBoundary: run.allSatisfy { Self.isCleanCut($0.item.text, at: prefixLength) },
                    writersSharingPrefix: 0
                )
                g.evidence = .sharedPrefix(cleanCut: g.cleanBoundary)
                groups.append(g)
            }

            // 総集編: 「X 総集編」ごとにまとめる。2 冊以上か、本編のシリーズ「X」がこの書き手にあれば(1 冊でも)シリーズ。
            // 番号の無い最初の総集編のあとに「総集編2」が出ることがあるので、番号の有無で分け方を変えない(利用者の判断)。
            // どこへ入れるかは方針 compilations: 別のシリーズ(既定)/ 本編のシリーズ / どこにも入れない。
            let placement = engine.rules.series.compilation.placement
            let mainKeys = Set(groups[groupsBefore...].map { String(text.comparable($0.ruleName).key) })
            let byName = Dictionary(grouping: placement == .notInSeries ? [] : compilations) { String(text.comparable($0.1.name).key) }
            for key in byName.keys.sorted() {
                let members = byName[key]!
                let hasMain = members[0].1.mains.contains { mainKeys.contains(String(text.comparable($0).key)) }
                // 本編に含める: 本編のシリーズがあれば、その組へ入れる。無ければ既定と同じく「X 総集編」にする。
                if placement == .inMainSeries,
                   let main = mainGroup(for: members[0].1.mains, in: groups, from: groupsBefore) {
                    groups[main.index].memberIDs = (groups[main.index].memberIDs + members.map(\.0.id)).sorted()
                    if let name = main.rename { groups[main.index].ruleName = name }
                    continue
                }
                // 本編が組になっていなくても、本編の本が残っているなら、その本と総集編で 1 つのシリーズにする
                // (利用者の事例 2026-09-22: 1〜10 は総集編に入っているので捨て、本編は 11 の 1 冊だけ。
                // 本編が 1 冊では組にならないので、総集編だけが「X 総集編」の別シリーズになっていた)。
                if placement == .inMainSeries,
                   let main = mainBooksFor(members[0].1.mains, items: items,
                                           claimed: Set(groups[groupsBefore...].flatMap(\.memberIDs))) {
                    var g = CandidateGroup(
                        id: 0, writerKey: writerKey.components(separatedBy: "\u{1}")[0],
                        memberIDs: (main.ids + members.map(\.0.id)).sorted(), ruleName: main.name,
                        cleanBoundary: true, writersSharingPrefix: 0)
                    // 本編が 1 冊でも作る組(総集編が本編の名前を言っているので、シリーズがあることは分かっている)。
                    g.allowsSingle = true
                    g.evidence = .compilation
                    groups.append(g)
                    continue
                }
                // 総集編の語が**題名の途中にあるだけ**で、その名前が指す本編が無いとき(「X・食／総集編」)は、
                // ふつうの本として、名前の頭が合う組へ入れる ―― 語が 1 つ入っているせいで、どのシリーズにも
                // 入れないのはおかしい(2026-09-21、利用者の指摘)。
                if members.count == 1, !hasMain, placement != .notInSeries,
                   let g = attachableGroup(for: members[0].0, in: groups, from: groupsBefore) {
                    groups[g].memberIDs = (groups[g].memberIDs + [members[0].0.id]).sorted()
                    log?.apply("subtitled", to: members[0].0.id)
                    continue
                }
                guard members.count >= 2 || (hasMain && singleCompilationWithMain) else { continue }
                var g = CandidateGroup(
                    id: 0, writerKey: writerKey.components(separatedBy: "\u{1}")[0],
                    memberIDs: members.map(\.0.id).sorted(), ruleName: members.min { $0.0.id < $1.0.id }!.1.name,
                    cleanBoundary: true, writersSharingPrefix: 0)
                g.allowsSingle = hasMain && singleCompilationWithMain
                g.evidence = .compilation
                g.isCompilation = true
                groups.append(g)
            }
            // 「X 6巻」のように、**組の名前そのものが「別の組の名前 + 巻」**になっている組は、その別の組の一部。
            // (「X 6巻 前編」「…後編」が 1 段目で「X 6巻」の組になり、本編「X」と別のシリーズに
            // 見えていた。2026-09-21、利用者の指摘)。**巻として読めるときだけ**移すので、「X 外伝 1・2」の
            // ように別の番号の並びを持つ組は、そのまま別のシリーズに残る。
            if mergesVolumeSubgroups { mergeVolumeSubgroups(&groups, from: groupsBefore) }
        }
        groups = splitByRelation(groups, books: books)
        groups = dissolveSameWorkOnly(groups, books: books)
        // ありふれた言葉の疑い: この前半部分で始まるタイトルを持つ書き手の数。
        // 鍵は並べておき、前半部分の位置を二分探索で探す(組の数 × 冊数の総当たりにしない。理由は上の「頭の組は、鍵で引く」)。
        let titleKeysByWriter = Dictionary(grouping: books, by: \.writerKey)
            .mapValues { $0.map { String(text.comparable($0.compareTitle).key) }.sorted() }
        for i in groups.indices {
            let prefix = String(text.comparable(groups[i].ruleName).key)
            groups[i].writersSharingPrefix = prefix.isEmpty ? 0 : titleKeysByWriter.values
                .filter { Self.anyHasPrefix(prefix, inSorted: $0) }.count
            groups[i].id = i + 1
        }
        return groups
    }

    /// 並べてある鍵の中に、この前半部分で始まるものがあるか。前半部分で始まる鍵は、並びの中でひと続きになる
    /// (文字列の順は、正規化した符号の辞書順)。その先頭を二分探索で見つけ、続くあいだだけ確かめる。
    static func anyHasPrefix(_ prefix: String, inSorted keys: [String]) -> Bool {
        var low = 0, high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        var i = low
        while i < keys.count, keys[i].unicodeScalars.starts(with: prefix.unicodeScalars) {
            if keys[i].hasPrefix(prefix) { return true }
            i += 1
        }
        return false
    }

    /// 名前が「別の組の名前 + 巻」になっている組を、その別の組へ入れる(方針ではなく規則 mergeVolumeSubgroups)。
    /// 入れ先はいちばん短い名前の組。巻として読めない残り(「外伝」)は動かさない。
    private func mergeVolumeSubgroups(_ groups: inout [CandidateGroup], from first: Int) {
        var merged = Set<Int>()
        for i in first..<groups.count where !merged.contains(i) {
            let name = text.comparable(groups[i].ruleName)
            let hosts = (first..<groups.count).filter { j -> Bool in
                guard j != i, !merged.contains(j) else { return false }
                let hostKey = text.key(groups[j].ruleName)
                guard !hostKey.isEmpty, name.key.count > hostKey.count,
                      String(name.key).hasPrefix(hostKey) else { return false }
                guard Self.isCleanCut(name, at: hostKey.count)
                    || (attachesAcrossScript && Self.startsNewWord(name, at: hostKey.count)) else { return false }
                return engine.volumes.isWholeVolume(name.originalRemainder(afterKeyLength: hostKey.count))
            }
            guard let host = hosts.min(by: { text.key(groups[$0].ruleName).count < text.key(groups[$1].ruleName).count })
            else { continue }
            groups[host].memberIDs = (groups[host].memberIDs + groups[i].memberIDs).sorted()
            merged.insert(i)
        }
        for i in merged.sorted(by: >) { groups.remove(at: i) }
    }

    /// その本の名前の頭に当たる組(いちばん長い名前のもの)。総集編の語が題名の途中にあるだけの本を、
    /// ふつうの本として入れるのに使う。切れ目の見方は副題の本と同じ。
    private func attachableGroup(for book: WorkingBook, in groups: [CandidateGroup], from first: Int) -> Int? {
        let title = text.comparable(book.compareTitle)
        return (first..<groups.count).filter { i in
            let name = text.comparable(groups[i].ruleName).key
            guard !name.isEmpty, title.key.count > name.count, String(title.key).hasPrefix(String(name)) else { return false }
            return Self.isCleanCut(title, at: name.count)
                || (attachesAcrossScript && Self.startsNewWord(title, at: name.count))
        }.max { text.key(groups[$0].ruleName).count < text.key(groups[$1].ruleName).count }
    }

    /// 総集編が言っている本編の名前(「X 総集編」の「X」)で、入れる先の組を探す(方針 compilations = inMainSeries)。
    ///
    /// 名前がそのまま一致する組が第一。無ければ、**本編の名前で始まり、余りがひらがなだけの名前**の組
    /// (「鬼ヶ島の安息」「鬼ヶ島の繁栄」… だけで組を作ると、名前が「鬼ヶ島の」になる)。その組は名前を
    /// 総集編の言う名前(「鬼ヶ島」)に直して受け入れる ―― 共通部分が助詞で終わるのは 2 段目の弱点で、
    /// 総集編はシリーズ名がどこまでかを名前で言っているから、そちらを採る(利用者の事例 2026-09-22)。
    /// 余りが漢字・カタカナを含むとき(「鬼ヶ島戦記」)は、別の作品なので受け入れない。
    private func mainGroup(for mains: [String], in groups: [CandidateGroup],
                           from first: Int) -> (index: Int, rename: String?)? {
        for main in mains {
            if let i = (first..<groups.count).first(where: { text.key(main) == text.key(groups[$0].ruleName) }) {
                return (i, nil)
            }
        }
        for main in mains {
            let key = text.key(main)
            guard !key.isEmpty else { continue }
            let found = (first..<groups.count).filter { i in
                let name = text.key(groups[i].ruleName)
                guard name.count > key.count, name.hasPrefix(key) else { return false }
                return name.dropFirst(key.count).allSatisfy(Self.isHiragana)
            }
            if let i = found.min(by: { text.key(groups[$0].ruleName).count < text.key(groups[$1].ruleName).count }) {
                return (i, main)
            }
        }
        return nil
    }

    /// 総集編の名前から導いた本編の名前(「X 総集編」の「X」)で、**まだどの組にも入っていない本編の本**を探す
    /// (方針 compilations = inMainSeries のとき)。
    ///
    /// 拾うのは、タイトルが本編の名前そのものか、**そのすぐ後ろが巻だけでできている**本に限る(1 段目と同じ見方)。
    /// 語の切れ目だけを頼りにすると、「X の住人たち」のような別の作品まで引き込んでしまう。
    private func mainBooksFor(_ mains: [String], items: [(id: Int, text: ComparableText)],
                              claimed: Set<Int>) -> (name: String, ids: [Int])? {
        for main in mains {
            let key = text.key(main)
            guard !key.isEmpty else { continue }
            let ids = items.filter { item in
                guard !claimed.contains(item.id), String(item.text.key).hasPrefix(key) else { return false }
                if item.text.key.count == key.count { return true }
                return !Self.splitsANumber(item.text, at: key.count) && Self.isCleanCut(item.text, at: key.count)
                    && engine.volumes.isWholeVolume(item.text.originalRemainder(afterKeyLength: key.count))
            }.map(\.id)
            if !ids.isEmpty { return (main, ids) }
        }
        return nil
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
            let l = Self.notInsideANumber(Self.commonPrefixLength(Array(last.item.text.key.prefix(runPrefix)), item.text.key),
                                          last.item.text, item.text)
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
                     && engine.english.isCommonEnglishOnly(last.item.text.original)
                     && engine.english.isCommonEnglishOnly(item.text.original)
                     && !(commonEnglishUnlessVolume && (hasVolume(last.item.text, after: l) || hasVolume(item.text, after: l))))
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
                if let log, l >= 1 {
                    // どの条件で組にしなかったか(説明のため)。
                    let englishOnly = l >= 1 && Self.isCleanCut(last.item.text, at: l) && Self.isCleanCut(item.text, at: l)
                        && !cleanOnBothSides
                    let rule = run.count > 1 || l < minPrefix ? (englishOnly ? "reject-common-english" : "sharedPrefix")
                        : englishOnly ? "reject-common-english"
                        : rejectsHiraganaEndings && Self.isHiragana(item.text.key[l - 1]) ? "reject-hiragana-ending"
                        : rejectsSingleWordPrefixes && Self.isSingleScriptRun(Array(item.text.key.prefix(l))) ? "reject-single-script"
                        : "sharedPrefix"
                    log.miss(last.item.id, item.id, length: l, rule: rule)
                }
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
    func volumeHeadLength(_ text: ComparableText, minLength: Int) -> Int? {
        guard text.key.count > minLength else { return nil }
        for length in minLength..<text.key.count
        where !Self.splitsANumber(text, at: length)
            && Self.isCleanCut(text, at: length)
            && engine.volumes.isWholeVolume(text.originalRemainder(afterKeyLength: length)) {
            return length
        }
        return nil
    }

    private static let volumeMarker = try! NSRegularExpression(pattern: #"^(?:ver|vol)(?:\.|\s|\d)"#, options: [.caseInsensitive])

    static func startsWithVolumeMarker(_ s: String) -> Bool {
        let n = s.precomposedNFKC
        return volumeMarker.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
    }

    /// 共通部分の切れ目を、**数の途中でない所まで戻す**。「Xそ01 夏」「Xそ02 春」の共通部分は「Xそ0」だが、
    /// それは 01・02 という 1 つの数を途中で切った形で、シリーズ名が「Xそ0」になってしまう(2026-09-20、利用者の指摘)。
    ///
    /// `isCleanCut` は「次が数字なら切れ目」(「X2」の X と 2)とみなすので、ここで戻さないと素通りする。
    /// 1 段目(`volumeHeadLength`)は同じことを `splitsANumber` で断っていて、2 段目にだけ無かった。
    static func notInsideANumber(_ length: Int, _ a: ComparableText, _ b: ComparableText) -> Int {
        var length = length
        while length > 0, splitsANumber(a, at: length) || splitsANumber(b, at: length) { length -= 1 }
        return length
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
        if end < chars.count, text.rules.isBoundary(chars[end]) { return true }
        // 漢字・かなの直後に英字が続くなら切れ目(「Xex」「X DX」の空白なし)。
        if end < chars.count, end > 0, chars[end].isASCII, chars[end].isLetter, !chars[end - 1].isASCII,
           chars[end - 1].isLetter { return true }
        // 「ver」「vol」が名前に続けて書かれた巻の印なら切れ目(「Xver.48」)。
        if end < chars.count, startsWithVolumeMarker(String(chars[end...])) { return true }
        // 次が数字なら切れ目(「X2」の X と 2)。
        return text.key[length].isNumber
    }
}
