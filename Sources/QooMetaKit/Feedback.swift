import Foundation

/// 利用者の直しを、例のファイル(`qoometa.examples`)の 1 件にしたもの。**すべての語を架空のものに置き換えてある**。
/// 送るのは利用側と利用者で、qooMeta は送らない。利用側は中身を利用者に見せ、同意を得てから送る。
public struct FeedbackExample: Sendable, Hashable {
    public struct PolicyChoice: Sendable, Hashable {
        public let policy: String
        public let choice: String
    }

    /// 例のファイル(1 件)。
    public let data: Data
    /// 置き換えた例で、元と同じ結果(組と巻)になるか。false なら、置き換えで形が変わった(そのまま送っても再現しない)。
    public let isFaithful: Bool
    /// 直しが、方針を 1 つ切り替えれば満たされるなら、その方針と値。好みの違いであって、報告する不具合ではない。
    public let satisfiedByPolicy: PolicyChoice?
}

/// 利用者が直した結果を、例のファイルの 1 件にする(docs/api.md「フィードバック」)。
///
/// 置き換えの規則(実名を残さないため、**すべての語を置き換える**):
/// - 規則の一覧にある語(総集編・vol・第・上・フルカラー版 …)、括弧・記号・空白、数字(漢数字を含む)は残す。
/// - 本の種別の語は `種別A`・`種別B` …(例の `vocabulary` にも同じ語を書く)。
/// - 辞書にある英単語は、辞書にある別の英単語(同じ長さ。同じ語は同じ語へ)。
/// - かな・カタカナ・漢字・それ以外の英字は、同じ文字種の架空の文字へ 1 文字ずつ置き換える。置き換えは「そこまでの元の並び」で
///   決めるので、同じ語は同じ語へ、先頭が共通する語は置き換えた後も同じ長さだけ共通する(シリーズの組が保たれる)。
public func makeFeedbackExample(_ books: [BookInput], corrected: [String: Confirmation], rules: CompiledRules,
                                vocabulary: Vocabulary) -> FeedbackExample {
    var anonymizer = Anonymizer(rules: rules, vocabulary: vocabulary)
    let anonymousBooks = books.map { book in
        BookInput(id: book.id, name: anonymizer.name(book.name), folders: book.folders.map { anonymizer.text($0) })
    }
    let anonymousVocabulary = Vocabulary(genres: vocabulary.genres.map { anonymizer.genre($0) },
                                         dictionaries: vocabulary.dictionaries)

    // 忠実さ: 直す前の提案(規則だけ)で、組の分け方と巻が元と同じか。
    let original = proposeSync(books.map { BookInput(id: $0.id, name: $0.name, folders: $0.folders) },
                               rules: rules, vocabulary: vocabulary)
    let replaced = proposeSync(anonymousBooks, rules: rules, vocabulary: anonymousVocabulary)
    func shape(_ set: ProposalSet) -> ([[String]], [String: String]) {
        (set.series.map { $0.memberIDs.sorted() }.sorted { $0.lexicographicallyPrecedes($1) },
         Dictionary(uniqueKeysWithValues: set.proposals.map {
             ($0.id, "\($0.volume?.sortKey.map { String($0) } ?? "-")\($0.volume?.inferred == true ? "?" : "")")
         }))
    }
    let isFaithful = shape(original) == shape(replaced)

    // 直した内容を期待値にする(直していない本は確かめない)。
    var expectations: [JSONValue] = []
    for book in books {
        var e: [String: JSONValue] = [:]
        let c = corrected[book.id] ?? .none
        switch c {
        case .series(let name, let volume, _):
            e["series"] = .string(anonymizer.text(name))
            if let volume { e["volume"] = volume.isEmpty ? .null : .string(anonymizer.text(volume)) }
        case .notInSeries: e["series"] = .null
        case .none, .fields: break
        }
        let f = c.fields
        if let v = f.circle { e["circle"] = .string(anonymizer.text(v)) }
        if let v = f.authors { e["authors"] = .array(v.map { .string(anonymizer.text($0)) }) }
        if let v = f.title { e["title"] = .string(anonymizer.text(v)) }
        if let v = f.relation { e["relation"] = .string(anonymizer.text(v)) }
        if let v = f.genre { e["genre"] = .string(anonymizer.genre(v)) }
        expectations.append(.object(e))
    }
    let files: [JSONValue] = anonymousBooks.map { book in
        book.folders.isEmpty ? .string(book.name)
            : .object(["name": .string(book.name), "folders": .array(book.folders.reversed().map(JSONValue.string))])
    }
    var hasher = FNV1a()
    for case .string(let s) in files { hasher.add(s) }
    let example: JSONValue = .object([
        "id": .string("feedback-" + String(hasher.value, radix: 16)),
        "files": .array(files),
        "expect": .array(expectations),
        "covers": .array([]),
    ])
    let file: JSONValue = .object([
        "kind": .string(ExampleFile.kind), "schemaVersion": .number(Double(ExampleFile.supportedSchemaVersion)),
        "vocabulary": .object(["genres": .array(anonymousVocabulary.genres.map(JSONValue.string))]),
        "examples": .array([example]),
    ])

    return FeedbackExample(data: Data((file.rendered() + "\n").utf8), isFaithful: isFaithful,
                           satisfiedByPolicy: policySatisfying(books, corrected: corrected, rules: rules, vocabulary: vocabulary))
}

/// 直しを満たす方針(今と違う値)を探す。シリーズの直しが無ければ探さない。
func policySatisfying(_ books: [BookInput], corrected: [String: Confirmation], rules: CompiledRules,
                      vocabulary: Vocabulary) -> FeedbackExample.PolicyChoice? {
    let targets = corrected.filter {
        switch $0.value { case .series, .notInSeries: true; default: false }
    }
    guard !targets.isEmpty else { return nil }
    let plain = books.map { BookInput(id: $0.id, name: $0.name, folders: $0.folders) }
    let current = rules.catalog.policies
    for policy in current {
        for choice in policy.choices where choice != policy.current {
            guard let applied = rules.applying(policies: [policy.id: choice]).rules else { continue }
            let set = proposeSync(plain, rules: applied, vocabulary: vocabulary)
            let satisfied = targets.allSatisfy { id, c in
                let name = set[id]?.seriesID.flatMap { set.series($0)?.name }
                switch c {
                case .series(let expected, let volume, _):
                    guard name == TextRules.normalizeDisplay(expected) else { return false }
                    return volume == nil || set[id]?.volume?.text == volume
                case .notInSeries: return name == nil
                default: return true
                }
            }
            if satisfied { return FeedbackExample.PolicyChoice(policy: policy.id, choice: choice) }
        }
    }
    return nil
}

/// 名前を架空のものに置き換える(1 つの例の中で、同じ置き換えを使い回す)。
struct Anonymizer {
    /// 残す語(規則の一覧の語)。長い語から。英字は小文字で比べる。
    let keepWords: [String]
    /// 残す文字(数字・漢数字・ギリシャ文字、処理に組み込まれた語の文字)。
    let keepCharacters: Set<Character>
    let genres: [String]
    let dictionary: WordSet?
    let pools: [Script: [Character]]
    /// そこまでの元の並び + 元の文字 → 置き換えた文字。
    var trie: [String: Character] = [:]
    var usedAtNode: [String: Set<Character>] = [:]
    var englishMap: [String: String] = [:]
    var englishUsed: Set<String> = []
    let englishByLength: [Int: [String]]

    enum Script: Hashable { case hiragana, katakana, han, upper, lower }

    init(rules: CompiledRules, vocabulary: Vocabulary) {
        // 規則の一覧の語と、印の正規表現に書いた語(「DL版」「〇〇語版」)。
        var words: Set<String> = ["DL", "ＤＬ", "語版"]
        for (_, list) in rules.mergedSeriesRules["lists"]?.objectValue ?? [:] {
            for w in list.arrayValue?.compactMap(\.stringValue) ?? [] { words.insert(w) }
        }
        keepWords = words.filter { !$0.isEmpty }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        // 処理に組み込まれた語(雑誌の号、分冊、ローマ数字は英字の並びとして別に見る)と、漢数字・ギリシャ文字。
        let builtIn = "年月号巻話章弾部幕集版編篇第上中下前後其"
        keepCharacters = Set(VolumeExtractor.kanjiDigits + builtIn + "αβγδεζηθικλμνξοπρστυφχψω")
        genres = vocabulary.genres
        dictionary = vocabulary.dictionaries["english"]
        englishByLength = Dictionary(grouping: (dictionary?.words ?? []).filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }.sorted(),
                                     by: \.count)
        // 置き換え先の文字。残す語・残す文字に使われている文字は避ける(置き換えで規則の語ができないように)。
        let avoid = Set(words.joined()).union(keepCharacters)
        func pool(_ s: String) -> [Character] { s.filter { !avoid.contains($0) } }
        pools = [
            .hiragana: pool("あいうえおかきくけこさしすせそたちてとなにぬねはひふへほまみむめもやゆよらりるれろわ"),
            .katakana: pool("アイウエオカキクケコサシスセタチツテトナニヌネハヒフヘホマミムメモヤユヨラリルレロワ"),
            .han: pool("山川田木林森石花空海風雨雪光音色羽鳥魚犬猫桜松竹梅春夏秋冬朝夕南北東西町村里野原岡島橋坂谷池泉岩砂草葉実種根枝"),
            .upper: Array("BCDFGHJKLMNPRSTVWZ"),
            .lower: Array("bcdfghjklmnprstvwz"),
        ]
    }

    static func script(_ ch: Character) -> Script? {
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return nil }
        switch v {
        case 0x3041...0x3096: return .hiragana
        case 0x30A1...0x30FA: return .katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .han
        case 0x41...0x5A: return .upper
        case 0x61...0x7A: return .lower
        default: return nil
        }
    }

    mutating func genre(_ g: String) -> String {
        guard let i = genres.firstIndex(of: g) else { return text(g) }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return "種別" + (i < letters.count ? String(letters[i]) : String(i + 1))
    }

    /// ファイル名。括弧で区切った部分ごとに置き換える(部分ごとに並びを数え直すので、タイトルの先頭とシリーズ名が同じに置き換わる)。
    mutating func name(_ raw: String) -> String {
        let delimiters: Set<Character> = ["[", "]", "(", ")", "［", "］", "（", "）"]
        var out = "", segment = ""
        func flush() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, genres.contains(trimmed) {
                out += segment.replacingOccurrences(of: trimmed, with: genre(trimmed))
            } else {
                out += text(segment)
            }
            segment = ""
        }
        for ch in raw.precomposedStringWithCanonicalMapping {
            if delimiters.contains(ch) { flush(); out.append(ch) } else { segment.append(ch) }
        }
        flush()
        return out
    }

    /// 1 つの並び(タイトル、シリーズ名、フォルダ名 …)。先頭の空白は並びに数えない。
    mutating func text(_ raw: String) -> String {
        let chars = Array(raw.precomposedStringWithCanonicalMapping)
        var out = ""
        var context = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if context.isEmpty, ch.isWhitespace { out.append(ch); i += 1; continue }
            // 残す語。
            if let word = keepWord(at: i, in: chars) {
                out += String(chars[i..<(i + word)])
                context += String(chars[i..<(i + word)])
                i += word
                continue
            }
            // 英字の語: 辞書にある語は語ごとに、無い語とローマ数字は 1 文字ずつ(ローマ数字は残す)。
            if ch.isASCII, ch.isLetter {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j])
                if word.allSatisfy({ "IVX".contains($0) }) {
                    out += word
                } else if let replaced = english(word) {
                    out += replaced
                } else {
                    for k in i..<j { out.append(replace(chars[k], context: context + String(chars[i..<k]))) }
                }
                context += word
                i = j
                continue
            }
            out.append(replace(ch, context: context))
            context.append(ch)
            i += 1
        }
        return out
    }

    func keepWord(at i: Int, in chars: [Character]) -> Int? {
        if keepCharacters.contains(chars[i]) { return 1 }
        for word in keepWords where word.count <= chars.count - i {
            let slice = String(chars[i..<(i + word.count)])
            if slice == word || (word.allSatisfy(\.isASCII) && slice.lowercased() == word.lowercased()) {
                // 英字の語は、語の途中から始まる・語の途中で終わる一致を採らない(「side」を「besides」の中に見ない)。
                if word.first?.isLetter == true, word.allSatisfy(\.isASCII) {
                    let before = i > 0 ? chars[i - 1] : " ", after = i + word.count < chars.count ? chars[i + word.count] : " "
                    if (before.isASCII && before.isLetter) || (after.isASCII && after.isLetter && word.last?.isLetter == true) { continue }
                }
                return word.count
            }
        }
        return nil
    }

    /// 1 文字の置き換え。そこまでの元の並びが同じなら同じ文字へ。同じ並びの後の違う文字は、違う文字へ。
    mutating func replace(_ ch: Character, context: String) -> Character {
        guard let script = Self.script(ch), let pool = pools[script], !pool.isEmpty else { return ch }
        let key = context + "\u{1}" + String(ch)
        if let done = trie[key] { return done }
        let used = usedAtNode[context] ?? []
        let start = Int(ch.unicodeScalars.first!.value) % pool.count
        var pick = pool[start]
        for k in 0..<pool.count where !used.contains(pool[(start + k) % pool.count]) {
            pick = pool[(start + k) % pool.count]
            break
        }
        trie[key] = pick
        usedAtNode[context, default: []].insert(pick)
        return pick
    }

    /// 辞書にある英単語なら、辞書にある別の同じ長さの語へ(大文字・小文字の形は保つ)。
    mutating func english(_ word: String) -> String? {
        let lower = word.lowercased()
        guard lower.count >= 2, let dictionary, dictionary.contains(lower) else { return nil }
        let replaced: String
        if let done = englishMap[lower] {
            replaced = done
        } else {
            let candidates = englishByLength[lower.count] ?? []
            var hasher = FNV1a()
            hasher.add(lower)
            var pick: String?
            if !candidates.isEmpty {
                let start = Int(hasher.value % UInt64(candidates.count))
                for k in 0..<candidates.count {
                    let c = candidates[(start + k) % candidates.count]
                    if c != lower, !englishUsed.contains(c), !keepWords.contains(c) { pick = c; break }
                }
            }
            guard let pick else { return nil }
            englishMap[lower] = pick
            englishUsed.insert(pick)
            replaced = pick
        }
        if word == word.uppercased() { return replaced.uppercased() }
        if word.first?.isUppercase == true { return replaced.prefix(1).uppercased() + replaced.dropFirst() }
        return replaced
    }
}

/// 決まった値のハッシュ(プロセスごとに変わる Hasher は使えないため)。
struct FNV1a {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ s: String) {
        for b in s.utf8 { value = (value ^ UInt64(b)) &* 0x100_0000_01b3 }
    }
}
