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

    public init(minPrefix: Int = 4, minWholeTitle: Int = 2, attachesSubtitledBooks: Bool = true,
                rejectsHiraganaEndings: Bool = true) {
        self.minPrefix = minPrefix
        self.minWholeTitle = minWholeTitle
        self.attachesSubtitledBooks = attachesSubtitledBooks
        self.rejectsHiraganaEndings = rejectsHiraganaEndings
    }

    static func isHiragana(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// 比べる単位。書き手 + 本の種別(qooLibrary の `@mediatype`)。**本の種別が違う本は同じシリーズにしない**
    /// (同人の本と商業の単行本のような発行形態の違い。利用者の指摘)。種別が読めなかった本は書き手だけで比べる。
    func partitionKey(_ book: BookProposal) -> String {
        let mediaType = String(ComparableText(book.parsed.mediaType ?? "").key)
        return mediaType.isEmpty ? book.circleKey : "\(book.circleKey)\u{1}\(mediaType)"
    }

    public func group(_ books: [BookProposal]) -> [SeriesGroup] {
        let byCircle = Dictionary(grouping: books, by: partitionKey)
        var groups: [SeriesGroup] = []
        for circleKey in byCircle.keys.sorted() {
            let items = byCircle[circleKey]!
                .map { (id: $0.id, text: ComparableText($0.parsed.title)) }
                .filter { !$0.text.key.isEmpty }

            // 1 段目: 「タイトル + 巻」の形の本を、巻を除いた頭の部分でまとめる。
            // 並べ替えた隣どうしで比べるだけだと、「三国志 21」と「三国志 第1巻」の間に「三国志演義」の
            // ような別のタイトルが挟まり、組が切れる(NDL の書誌で測った取りこぼしの主因)。
            var byHead: [String: [(id: Int, text: ComparableText, headLength: Int)]] = [:]
            var rest: [(id: Int, text: ComparableText)] = []
            for item in items {
                // 後ろが巻だけでできていることを求めるので、頭は 1 文字でもよい(「咲 18」)。
                if let head = Self.volumeHeadLength(item.text, minLength: 1) {
                    byHead[String(item.text.key.prefix(head)), default: []].append((item.id, item.text, head))
                } else {
                    rest.append(item)
                }
            }
            var headGroups: [(key: String, members: [(id: Int, text: ComparableText, headLength: Int)])] = []
            for (key, members) in byHead {
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
            for g in headGroups.indices where headGroups[g].members.count == 1 {
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
            for run in runs(sorted) where run.count >= 2 {
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
        }
        // ありふれた言葉の疑い: この前半部分で始まるタイトルを持つ書き手の数。
        let titleKeysByCircle = Dictionary(grouping: books, by: \.circleKey)
            .mapValues { $0.map { String(ComparableText($0.parsed.title).key) } }
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
            let cleanOnBothSides = l >= 1 && Self.isCleanCut(last.item.text, at: l) && Self.isCleanCut(item.text, at: l)
            // 語の途中で切れる一致が、ひらがな(「の」「と」などの助詞)で終わるなら採らない。
            // 言い回しが重なっただけの別作品(利用者の指摘)。
            let midWordAccepted = l >= minPrefix
                && !(rejectsHiraganaEndings && !cleanOnBothSides && Self.isHiragana(item.text.key[l - 1]))
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
        where !(text.key[length - 1].isNumber && text.key[length].isNumber)
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
