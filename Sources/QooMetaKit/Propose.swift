import Foundation

// 提案の計算(docs/api.md「まとめて提案する」)。
//
// 流れ: 入力を確かめる → 名前を欄に分ける(確定した欄を優先)→ 中核の入口(CoreBook)に詰める →
// 比べる単位(書き手 + ジャンル)に分ける →
// 単位ごとに組・確定した内容・巻を決める → 決まった順に並べて返す。**提案は単位の中だけで決まる**ので、
// 単位ごとに別々に計算でき(並列化・ProposalIndex の計算し直し)、同じ入力なら毎回同じ結果になる。

/// ファイル名を欄に分ける(シリーズは見ない)。取り込みの瞬間に 1 冊ずつ補完したい利用側向け。
public func parseName(_ name: String, rules: CompiledRules, vocabulary: Vocabulary) -> ParsedName {
    let engine = RuleEngine(rules: rules, vocabulary: vocabulary)
    return engine.publicName(engine.parse(BookInput(id: "", name: name)))
}

/// 一覧をまとめて提案する。CPU を使う同期の計算。メインスレッドの外で呼ぶ。
public func proposeSync(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                        options: ProposalOptions = .default) -> ProposalSet {
    let engine = RuleEngine(rules: rules, vocabulary: vocabulary)
    let prepared = engine.prepare(books, limits: options.limits)
    let results = prepared.units.mapValues { engine.computeUnit($0.map(\.core), explain: options.explanations) }
    return engine.assemble(prepared, results)
}

/// 同じ計算を、呼び出し側のアクターの外で行う。Task の取り消しと、進み具合の通知に対応する。
/// 単位をまとめた塊ごとに並列に計算する(1 単位は平均して数冊なので、単位ごとにタスクを作ると遅くなる)。
@concurrent
public func propose(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                    options: ProposalOptions = .default,
                    progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError) -> ProposalSet {
    let engine = RuleEngine(rules: rules, vocabulary: vocabulary)
    // 名前の解析(計算の大半)も、本をまとめた塊ごとに並列に行う。入力の確かめ(ID の重なりなど)は順に。
    let (accepted, rejected) = engine.screen(books, limits: options.limits)
    let size = max(64, (accepted.count + ProcessorCount.value * 4 - 1) / (ProcessorCount.value * 4))
    var preparedBooks = [PreparedBook?](repeating: nil, count: accepted.count)
    do {
        try await withThrowingTaskGroup(of: [(Int, PreparedBook)].self) { group in
            for start in stride(from: 0, to: accepted.count, by: size) {
                group.addTask {
                    try Task.checkCancellation()
                    return (start..<min(start + size, accepted.count)).map { i in
                        (i, engine.prepareOne(accepted[i].input, order: accepted[i].order))
                    }
                }
            }
            for try await part in group {
                for (i, book) in part { preparedBooks[i] = book }
            }
        }
    } catch {
        throw CancellationError()
    }
    let prepared = Prepared(books: preparedBooks.map { $0! },
                            units: Dictionary(grouping: preparedBooks.map { $0! }, by: \.unitKey), rejected: rejected)
    let keys = prepared.units.keys.sorted()
    let chunkCount = max(1, min(keys.count, ProcessorCount.value * 4))
    let chunks = stride(from: 0, to: keys.count, by: max(1, (keys.count + chunkCount - 1) / chunkCount)).map {
        Array(keys[$0..<min($0 + (keys.count + chunkCount - 1) / chunkCount, keys.count)])
    }
    var results: [String: UnitResult] = [:]
    do {
        try await withThrowingTaskGroup(of: [(String, UnitResult)].self) { group in
            for chunk in chunks {
                group.addTask {
                    try Task.checkCancellation()
                    return chunk.map { ($0, engine.computeUnit(prepared.units[$0]!.map(\.core), explain: options.explanations)) }
                }
            }
            for try await part in group {
                for (key, result) in part { results[key] = result }
                progress?(ProposalProgress(completedUnits: results.count, totalUnits: keys.count))
            }
        }
    } catch {
        throw CancellationError()
    }
    if Task.isCancelled { throw CancellationError() }
    return engine.assemble(prepared, results)
}

/// 並列の度合い(本体は ProcessInfo に触れないので、固定の値にする。塊の数を決めるだけなので厳密でなくてよい)。
enum ProcessorCount {
    static let value = 8
}

// MARK: - 下ごしらえ

/// 名前を欄に分け、中核の入口に詰めた 1 冊。
struct PreparedBook: Sendable {
    let input: BookInput
    /// 中核へ渡す形。
    let core: CoreBook
    /// 公開する形(下ごしらえのときに 1 度だけ作る。ProposalIndex で毎回作り直さないため)。
    let parsed: ParsedName
    let unitKey: String
}

struct Prepared: Sendable {
    /// 受け付けた本(入力の順)。
    var books: [PreparedBook]
    var units: [String: [PreparedBook]]
    var rejected: [InputIssue]
}

/// 1 つの単位の結果。
struct UnitResult: Sendable {
    struct Book: Sendable {
        struct ReadVolume: Sendable {
            var volume: Volume
            /// 雑誌の年と号として読んだ(方針 magazines = whole)。
            var fromMagazineIssue: Bool
        }

        var seriesKey: String?
        var volume: ReadVolume?
        var isCompilation: Bool
        var explanation: Explanation?
    }

    var books: [String: Book]
    /// 単位の中のシリーズ(ID を付ける前)。
    var series: [UnitSeries]
}

struct UnitSeries: Sendable {
    /// 単位の中で組を指す鍵(名前の比べる形 + 最小の本の ID)。
    var key: String
    var name: String
    var kind: SeriesProposal.Kind
    var memberIDs: [String]
    var evidence: SeriesProposal.Evidence
    var minMemberID: String
}

extension RuleEngine {
    /// 入力を確かめ、名前を欄に分けて単位ごとに分ける。上限を超えた入力と、重なった ID は扱わない。
    func prepare(_ inputs: [BookInput], limits: InputLimits) -> Prepared {
        let (accepted, rejected) = screen(inputs, limits: limits)
        let books = accepted.map { prepareOne($0.input, order: $0.order) }
        return Prepared(books: books, units: Dictionary(grouping: books, by: \.unitKey), rejected: rejected)
    }

    /// 入力を確かめる(上限・ID の重なり)。受け付けた入力と、その入力の中の順番。
    func screen(_ inputs: [BookInput], limits: InputLimits) -> (accepted: [(input: BookInput, order: Int)], rejected: [InputIssue]) {
        var seen = Set<String>()
        var accepted: [(input: BookInput, order: Int)] = []
        var rejected: [InputIssue] = []
        for (order, input) in inputs.enumerated() {
            func reject(_ reason: InputIssue.Reason) { rejected.append(InputIssue(id: input.id, reason: reason)) }
            if order >= limits.maxBooks { reject(.tooManyBooks); continue }
            if let reason = Self.issue(input, limits: limits) { reject(reason); continue }
            if !seen.insert(input.id).inserted { reject(.duplicateID); continue }
            accepted.append((input, order))
        }
        return (accepted, rejected)
    }

    /// 入力の上限を確かめる(ID の重なりと冊数は呼び出し側で見る)。
    static func issue(_ input: BookInput, limits: InputLimits) -> InputIssue.Reason? {
        if input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if input.name.count > limits.maxNameLength { return .nameTooLong }
        if input.folders.count > limits.maxFolders { return .tooManyFolders }
        if input.folders.contains(where: { $0.count > limits.maxFolderNameLength }) { return .folderNameTooLong }
        return nil
    }

    /// 名前を読み、中核の入口に詰める。
    func prepareOne(_ input: BookInput, order: Int) -> PreparedBook {
        let parts = parse(input)
        // 書き手はサークル。無ければいちばん近いフォルダ名(今の前段の読み方。フォルダ名を読むのは段階 6 でやめる)。
        let owner = parts.circle.isEmpty ? (input.folders.first.map(TextRules.normalizeDisplay) ?? "") : parts.circle
        let head = volumeHead(compareTitle: parts.baseTitle)
        let core = CoreBook(id: input.id, order: order, title: parts.title, compareTitle: parts.baseTitle,
                            writerKey: text.key(owner), genre: parts.mediaType ?? "", relation: parts.trailing,
                            hasEditionMarks: parts.editions != nil, hasSourceMarks: parts.sources != nil,
                            confirmation: input.confirmation, volumeHead: head)
        return PreparedBook(input: input, core: core, parsed: publicName(parts, volumeHead: head), unitKey: unitKey(core))
    }

    /// 名前を欄に分け、確定した欄で置き換え、版・入手経路の印と総集編の範囲を見る。
    func parse(_ input: BookInput) -> NameParts {
        // 制御文字と書式文字(Cc・Cf)は比べる前に落とす(見えない文字で組を割ったり、表示を崩したりさせない)。
        let name = String(String.UnicodeScalarView(input.name.unicodeScalars.filter {
            !($0.properties.generalCategory == .control || $0.properties.generalCategory == .format)
        }))
        // どのフォーマットにも一致しなければ、括弧の位置だけで読む(規則 fallback.simpleBrackets)。止めていれば名前全体をタイトルにする。
        var parts = parser.parse(baseName: name) ?? {
            if rules.formats.simpleBracketsEnabled {
                var p = NameParser.parse(baseName: name)
                p.format = .fallback(p.matchedPattern ? "simpleBrackets" : "wholeName")
                return p
            }
            return NameParts(title: TextRules.normalizeDisplay(name), matchedPattern: false)
        }()
        let confirmed = input.confirmation.fields
        if let circle = confirmed.circle { parts.circle = TextRules.normalizeDisplay(circle) }
        if let authors = confirmed.authors { parts.authors = authors }
        if let title = confirmed.title { parts.title = TextRules.normalizeDisplay(title) }
        if let relation = confirmed.relation { parts.trailing = TextRules.normalizeDisplay(relation) }
        if let genre = confirmed.genre {
            parts.mediaType = TextRules.normalizeDisplay(genre)
            parts.leading = parts.mediaType ?? ""
        }
        let compared = compareTitle(parts.title)
        if compared.text != parts.title { parts.workTitle = compared.text }
        parts.editions = compared.editions.isEmpty ? nil : compared.editions
        parts.sources = compared.sources.isEmpty ? nil : compared.sources
        return parts
    }

    func publicName(_ parts: NameParts, volumeHead head: Int?? = nil) -> ParsedName {
        func value(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        // 1 冊だけで読める巻: タイトルが「頭 + 巻だけ」の形なら、その巻(シリーズ名は推定しない)。
        let title = text.comparable(parts.baseTitle)
        let standalone = (head ?? volumeHead(compareTitle: parts.baseTitle)).flatMap { head in
            volumes.extract(fromRemainder: title.originalRemainder(afterKeyLength: head))
        }.map { Volume(text: $0.text, sortKey: $0.number) }
        return ParsedName(
            genre: value(parts.mediaType), event: value(parts.event), circle: value(parts.circle), authors: parts.authors,
            title: parts.title, relation: value(parts.trailing), keyword: value(parts.keyword),
            editions: parts.editions ?? [], sources: parts.sources ?? [], format: parts.format,
            standaloneVolume: standalone)
    }

    // MARK: - 単位ごとの計算

    /// 1 つの単位の本(中核の入口の形)から、組・確定した内容・巻を決める。
    func computeUnit(_ members: [CoreBook], explain: Bool = false) -> UnitResult {
        let sorted = members.sorted { $0.order < $1.order }
        var doc = WorkingDocument(books: sorted.enumerated().map { i, book in
            WorkingBook(id: i + 1, inputID: book.id, title: book.title, compareTitle: book.compareTitle,
                        relation: book.relation, genre: book.genre, hasEditionMarks: book.hasEditionMarks,
                        hasSourceMarks: book.hasSourceMarks, writerKey: book.writerKey,
                        confirmation: book.confirmation, volumeHead: .some(book.volumeHead))
        }, groups: [])
        var grouper = SeriesGrouper(engine: self)
        let log = explain ? ExplanationLog() : nil
        grouper.log = log
        doc.groups = grouper.group(doc.books)
        applyConfirmations(&doc)
        ProposalFinalizer.finalize(&doc, engine: self, log: log)
        if let log {
            // 組になった本には、組になった理由の規則を。
            for group in doc.groups {
                let rule: String? = switch group.evidence {
                case .volumeHead: "volumeHead"
                case .sharedPrefix: "sharedPrefix"
                case .compilation: "compilation"
                case .confirmed: nil
                }
                for id in group.memberIDs where doc.books.first(where: { $0.id == id })?.groupID == group.id {
                    if let rule { log.apply(rule, to: id) }
                }
            }
            for book in doc.books {
                if book.hasEditionMarks { log.apply("edition", to: book.id) }
                if book.hasSourceMarks { log.apply("source", to: book.id) }
            }
        }
        let explanations = log?.explanations(inputIDs: Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, $0.inputID) }))

        let byID = Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, $0) })
        var series: [UnitSeries] = []
        var seriesKeyByGroup: [Int: String] = [:]
        for group in doc.groups {
            let members = group.memberIDs.compactMap { byID[$0] }.filter { $0.groupID == group.id }
            guard !members.isEmpty else { continue }
            let minID = members.map(\.inputID).min()!
            let key = text.key(group.ruleName) + "\u{1F}" + minID
            seriesKeyByGroup[group.id] = key
            let ordered = members.sorted { a, b in
                switch (a.volumeNumber, b.volumeNumber) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return (a.title, a.inputID) < (b.title, b.inputID)
                }
            }
            series.append(UnitSeries(key: key, name: group.ruleName, kind: kind(of: group), memberIDs: ordered.map(\.inputID),
                                     evidence: group.evidence, minMemberID: minID))
        }
        var books: [String: UnitResult.Book] = [:]
        for book in doc.books {
            let volume = book.volumeText.isEmpty ? nil : UnitResult.Book.ReadVolume(
                volume: Volume(text: book.volumeText, sortKey: book.volumeNumber, inferred: book.volumeInferred == true),
                fromMagazineIssue: rules.series.volume.magazinesWhole && (book.volumeNumber ?? 0) >= 190_000)
            books[book.inputID] = UnitResult.Book(
                seriesKey: book.groupID.flatMap { seriesKeyByGroup[$0] }, volume: volume,
                isCompilation: compilation.keywordRange(in: book.compareTitle) != nil,
                explanation: explanations?[book.inputID])
        }
        return UnitResult(books: books, series: series)
    }

    /// 1 年ぶんの雑誌のシリーズ(名前が年で終わる)か。
    static let yearSuffix = try! NSRegularExpression(pattern: #"(?:19|20)\d{2}\s*年?$"#)

    func kind(of group: CandidateGroup) -> SeriesProposal.Kind {
        if group.isCompilation { return .compilation }
        let name = group.ruleName.precomposedNFKC
        if !rules.series.volume.magazinesWhole,
           Self.yearSuffix.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil {
            return .magazineYear
        }
        return .series
    }

    /// 確定した内容の効き方(docs/api.md「確定した値の効き方」):
    /// - `.notInSeries` の本はどの組にも入れない。
    /// - `.series(name:)` の本は錨になる。規則が同じ組にした未確定の本は、確定した名前のシリーズに入る。
    ///   1 つの組に確定した名前が 2 種類以上あれば、組を名前ごとに割り、未確定の本はタイトルの先頭がいちばん長く一致する名前へ入れる。
    /// - 同じ単位で同じ名前に確定した本は、規則が別の組にしていても同じシリーズにする。
    func applyConfirmations(_ doc: inout WorkingDocument) {
        var confirmedName: [Int: String] = [:]
        var excluded = Set<Int>()
        for book in doc.books {
            switch book.confirmation {
            case .series(let name, _, _):
                let display = TextRules.normalizeDisplay(name)
                if !display.isEmpty { confirmedName[book.id] = display }
            case .notInSeries: excluded.insert(book.id)
            default: break
            }
        }
        guard !confirmedName.isEmpty || !excluded.isEmpty else { return }
        let titleKey = Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, text.key($0.compareTitle)) })

        var result: [CandidateGroup] = []
        // 確定した名前(比べる形)→ その名前の本。
        var named: [String: (display: String, members: [Int])] = [:]
        func addNamed(_ id: Int, _ nameKey: String, _ display: String) {
            if named[nameKey] == nil { named[nameKey] = (display, []) }
            if !named[nameKey]!.members.contains(id) { named[nameKey]!.members.append(id) }
        }
        for var group in doc.groups {
            group.memberIDs.removeAll { excluded.contains($0) }
            let names = group.memberIDs.compactMap { id in confirmedName[id].map { (id, $0) } }
            guard !names.isEmpty else {
                result.append(group)
                continue
            }
            // 同じ名前は、いちばん小さい番号の本の表記を使う。
            var displayByKey: [String: String] = [:]
            for (_, name) in names.sorted(by: { $0.0 < $1.0 }) where displayByKey[text.key(name)] == nil {
                displayByKey[text.key(name)] = name
            }
            for id in group.memberIDs {
                if let name = confirmedName[id] {
                    addNamed(id, text.key(name), displayByKey[text.key(name)]!)
                } else if displayByKey.count == 1 {
                    let (key, display) = displayByKey.first!
                    addNamed(id, key, display)
                } else if let key = displayByKey.keys.filter({ titleKey[id]!.hasPrefix($0) }).max(by: { ($0.count, $1) < ($1.count, $0) }) {
                    addNamed(id, key, displayByKey[key]!)
                }
            }
        }
        // 規則がどの組にも入れなかった、確定した名前の本。
        let grouped = Set(named.values.flatMap(\.members))
        for (id, name) in confirmedName.sorted(by: { $0.key < $1.key }) where !grouped.contains(id) {
            addNamed(id, text.key(name), named[text.key(name)]?.display ?? name)
        }
        for key in named.keys.sorted() {
            let entry = named[key]!
            var g = CandidateGroup(id: 0, writerKey: doc.books.first?.writerKey ?? "", memberIDs: entry.members.sorted(),
                                   ruleName: entry.display, cleanBoundary: true, writersSharingPrefix: 0)
            g.allowsSingle = true
            g.evidence = .confirmed
            result.append(g)
        }
        // 確定した本を割り当てた組から、その本を除く(同じ本が 2 つの組に入らないように)。
        let taken = Set(named.values.flatMap(\.members))
        for i in result.indices where result[i].evidence != .confirmed {
            result[i].memberIDs.removeAll { taken.contains($0) }
        }
        // 冊数の足りない組は ProposalFinalizer がシリーズにしない(2 冊未満。確定した組と、本編のある総集編は 1 冊でもよい)。
        result.removeAll { $0.memberIDs.isEmpty }
        for i in result.indices { result[i].id = i + 1 }
        doc.groups = result
    }

    // MARK: - まとめ

    /// シリーズの ID: 単位 + 名前 + 最小の本の ID(ネタで割れた同じ名前の組も重ならない)。
    func seriesID(_ unitKey: String, _ seriesKey: String) -> SeriesID {
        SeriesID(rawValue: unitKey + "\u{1E}" + seriesKey)
    }

    func seriesProposals(unitKey: String, _ result: UnitResult) -> [SeriesProposal] {
        result.series.map {
            SeriesProposal(id: seriesID(unitKey, $0.key), name: $0.name, kind: $0.kind, memberIDs: $0.memberIDs,
                           evidence: $0.evidence)
        }
    }

    /// シリーズの決まった順(書き手 → 名前 → 最小の本の ID)。
    static func seriesOrder(_ a: SeriesProposal, _ b: SeriesProposal) -> Bool {
        let x = a.id.rawValue.components(separatedBy: "\u{1}")[0], y = b.id.rawValue.components(separatedBy: "\u{1}")[0]
        let circleA = x.components(separatedBy: "\u{1E}")[0], circleB = y.components(separatedBy: "\u{1E}")[0]
        return (circleA, a.name, a.memberIDs.min() ?? "", a.id) < (circleB, b.name, b.memberIDs.min() ?? "", b.id)
    }

    func bookProposal(_ book: PreparedBook, _ result: UnitResult?) -> BookProposal {
        let r = result?.books[book.input.id]
        let key = r?.seriesKey
        let series = key.flatMap { k in result?.series.first { $0.key == k } }
        var flags = Set<BookProposal.Flag>()
        if r?.volume?.volume.inferred == true { flags.insert(.inferredVolume) }
        if !book.parsed.editions.isEmpty { flags.insert(.edition) }
        if !book.parsed.sources.isEmpty { flags.insert(.source) }
        if r?.isCompilation == true { flags.insert(.compilation) }
        if series?.kind == .magazineYear || (series != nil && r?.volume?.fromMagazineIssue == true) { flags.insert(.magazineIssue) }
        if book.input.confirmation != .none { flags.insert(.confirmed) }
        return BookProposal(id: book.input.id, name: book.input.name, parsed: book.parsed, seriesID: key.map { seriesID(book.unitKey, $0) },
                            volume: r?.volume?.volume, flags: flags)
    }

    func assemble(_ prepared: Prepared, _ results: [String: UnitResult]) -> ProposalSet {
        let series = results.flatMap { seriesProposals(unitKey: $0.key, $0.value) }.sorted(by: Self.seriesOrder)
        let proposals = prepared.books.map { bookProposal($0, results[$0.unitKey]) }
        var explanations: [String: Explanation] = [:]
        for result in results.values { for (id, book) in result.books { if let e = book.explanation { explanations[id] = e } } }
        return ProposalSet(proposals: proposals, series: series, rulesHash: rules.contentHash, rejected: prepared.rejected,
                           explanations: explanations)
    }
}
