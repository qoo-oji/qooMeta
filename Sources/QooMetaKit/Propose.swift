import Foundation

// 提案の計算(docs/api.md「まとめて提案する」)。
//
// 流れ: 入力を確かめる → 名前を欄に分ける(確定した欄を優先)→ 中核の入口(CoreBook)に詰める →
// 比べる単位(書き手 + ジャンル)に分ける →
// 単位ごとに組・確定した内容・巻を決める → 決まった順に並べて返す。**提案は単位の中だけで決まる**ので、
// 単位ごとに別々に計算でき(並列化・ProposalIndex の計算し直し)、同じ入力なら毎回同じ結果になる。

/// ファイル名を型で読んで欄に分ける(シリーズと巻数は見ない)。取り込みの瞬間に 1 冊ずつ補完したい利用側向け。
/// `preset` は、どの型の並びで読むか(nil なら既定。フォルダごとに使い分けられる)。
public func parseName(_ name: String, rules: CompiledRules, preset: String? = nil) -> FormatReading {
    rules.formats[preset].read(RuleEngine.cleaned(name))
}

/// 一覧をまとめて提案する。CPU を使う同期の計算。メインスレッドの外で呼ぶ。
public func proposeSync(_ books: [BookInput], rules: CompiledRules, dictionaries: [String: WordSet],
                        options: ProposalOptions = .default) -> ProposalSet {
    let engine = RuleEngine(rules: rules, dictionaries: dictionaries)
    let prepared = engine.prepare(books, limits: options.limits)
    let results = prepared.units.mapValues { engine.computeUnit($0.map(\.core), explain: options.explanations) }
    return engine.assemble(prepared, results)
}

/// 同じ計算を、呼び出し側のアクターの外で行う。Task の取り消しと、進み具合の通知に対応する。
/// 単位をまとめた塊ごとに並列に計算する(1 単位は平均して数冊なので、単位ごとにタスクを作ると遅くなる)。
@concurrent
public func propose(_ books: [BookInput], rules: CompiledRules, dictionaries: [String: WordSet],
                    options: ProposalOptions = .default,
                    progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError) -> ProposalSet {
    let engine = RuleEngine(rules: rules, dictionaries: dictionaries)
    // 名前の解析(計算の大半)も、本をまとめた塊ごとに並列に行う。入力の確かめ(ID の重なりなど)は順に。
    let (accepted, rejected) = engine.screen(books, limits: options.limits)
    let preparedBooks = try await engine.prepareInParallel(accepted)
    let prepared = Prepared(books: preparedBooks, units: Dictionary(grouping: preparedBooks, by: \.unitKey), rejected: rejected)
    let results = try await engine.computeUnitsInParallel(prepared.units.mapValues { $0.map(\.core) },
                                                          explain: options.explanations, progress: progress)
    return engine.assemble(prepared, results)
}

extension RuleEngine {
    /// 名前を読んで中核の入口に詰める所を、本をまとめた塊ごとに並列に行う(入力の順のまま返す)。
    /// `readings` に前の読み(本の ID → 型で読んだ結果)があれば、名前を読み直さずに使う(型の並びが変わっていないとき)。
    func prepareInParallel(_ accepted: [(input: BookInput, order: Int)],
                           readings: [String: FormatReading]? = nil) async throws(CancellationError) -> [PreparedBook] {
        let size = max(64, (accepted.count + ProcessorCount.value * 4 - 1) / (ProcessorCount.value * 4))
        var prepared = [PreparedBook?](repeating: nil, count: accepted.count)
        do {
            try await withThrowingTaskGroup(of: [(Int, PreparedBook)].self) { group in
                for start in stride(from: 0, to: accepted.count, by: size) {
                    group.addTask {
                        try Task.checkCancellation()
                        return (start..<min(start + size, accepted.count)).map { i in
                            (i, self.prepareOne(accepted[i].input, order: accepted[i].order, reading: readings?[accepted[i].input.id]))
                        }
                    }
                }
                for try await part in group {
                    for (i, book) in part { prepared[i] = book }
                }
            }
        } catch {
            throw CancellationError()
        }
        return prepared.map { $0! }
    }

    /// 単位の計算を、単位をまとめた塊ごとに並列に行う(1 単位は平均して数冊なので、単位ごとにタスクを作ると遅くなる)。
    func computeUnitsInParallel(_ units: [String: [CoreBook]], explain: Bool,
                                progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError)
        -> [String: UnitResult] {
        let keys = units.keys.sorted()
        let chunkCount = max(1, min(keys.count, ProcessorCount.value * 4))
        let chunkSize = max(1, (keys.count + chunkCount - 1) / chunkCount)
        let chunks = stride(from: 0, to: keys.count, by: chunkSize).map { Array(keys[$0..<min($0 + chunkSize, keys.count)]) }
        var results: [String: UnitResult] = [:]
        do {
            try await withThrowingTaskGroup(of: [(String, UnitResult)].self) { group in
                for chunk in chunks {
                    group.addTask {
                        try Task.checkCancellation()
                        return chunk.map { ($0, self.computeUnit(units[$0]!, explain: explain)) }
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
        return results
    }
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
    /// 名前を型で読んだ結果(確定した欄は重ねていない)。
    let reading: FormatReading
    /// 読んだ欄に、確定した欄を重ねたもの(シリーズと巻数は、単位の計算のあとで入れる)。
    let metadata: BookMetadata
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
    /// シリーズの鍵 → 名前。本ごとに `series` を頭から探さない(書き手の読めない蔵書は 1 つの単位に何千ものシリーズを持つ)。
    var seriesNames: [String: String]
    var seriesKinds: [String: SeriesProposal.Kind]

    init(books: [String: Book], series: [UnitSeries]) {
        self.books = books
        self.series = series
        seriesNames = Dictionary(series.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        seriesKinds = Dictionary(series.map { ($0.key, $0.kind) }, uniquingKeysWith: { a, _ in a })
    }
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
        return nil
    }

    /// 名前を型で読み、確定した欄を重ねて、中核の入口に詰める。
    /// `reading` に前の読みを渡すと、名前を読み直さない(型の並びが変わっていないと分かっているとき)。
    func prepareOne(_ input: BookInput, order: Int, reading: FormatReading? = nil) -> PreparedBook {
        scoped { prepareOneUnscoped(input, order: order, reading: reading) }
    }

    private func prepareOneUnscoped(_ input: BookInput, order: Int, reading given: FormatReading?) -> PreparedBook {
        let reading = given ?? rules.formats[input.preset].read(Self.cleaned(input.name))
        let metadata = input.confirmation.fields.applied(to: reading.metadata)
        let compared = compareTitle(metadata.title)
        // 型が名前から直に読んだシリーズ・巻数(`@series` `@volume`)は、利用者が確定した値と同じ扱いで中核へ渡す。
        var confirmation = Self.confirming(metadata, over: input.confirmation)
        // 「シリーズに入れない語」(語の規則 `treat: standalone`)のある本は、利用者が「シリーズに入れない」と直した本と同じ扱いで
        // 中核へ渡す。利用者や型がシリーズを決めた本には効かない(はっきり決めた値が優先)。
        switch confirmation {
        case .none, .fields: if compared.standsAlone { confirmation = .notInSeries(fields: confirmation.fields) }
        case .series, .notInSeries: break
        }
        // 巻数を型で読んだ本は、比べるタイトルの後ろにその表記を付ける(「月の庭」+「12」)。名前の中に巻が書いてある本と
        // 同じ形になるので、中核の規則(タイトル + 巻)がそのまま効く。
        // `@title` の無い型が組み立てたタイトル(「月の庭 (3)」)には、もう巻が入っているので付けない。
        let assembled = reading.formatIndex != nil && !reading.spans.contains { $0.word == .title }
            && metadata.title == reading.metadata.title
        let compareText = metadata.volume.isEmpty || assembled ? compared.text : compared.text + " " + metadata.volume
        let core = CoreBook(id: input.id, order: order, title: metadata.title, compareTitle: compareText,
                            // 書き手は著者の並びの先頭。無ければ空(書き手の空の本どうしで 1 つの単位になる)。
                            writerKey: text.key(metadata.authors.first ?? ""), genre: metadata.genre,
                            source: metadata.source, hasEditionMarks: !compared.editions.isEmpty,
                            hasSourceMarks: !compared.sources.isEmpty, standsAlone: compared.standsAlone,
                            confirmation: confirmation,
                            volumeHead: volumeHead(compareTitle: compareText),
                            compareClaims: words.claims(in: compareText))
        return PreparedBook(input: input, core: core, reading: reading, metadata: metadata, unitKey: unitKey(core))
    }

    /// 型が読んだシリーズ・巻数を、確定した内容に重ねる(利用者の確定が優先)。どちらも無ければそのまま。
    static func confirming(_ metadata: BookMetadata, over confirmation: Confirmation) -> Confirmation {
        guard !metadata.series.isEmpty || !metadata.volume.isEmpty else { return confirmation }
        switch confirmation {
        case .none, .fields:
            let fields = confirmation.fields
            guard !metadata.series.isEmpty else {
                // 巻数だけ読めたときは、シリーズは中核に任せ、巻数だけ確定した値として渡す。
                var withVolume = fields
                withVolume[.volume] = [metadata.volume]
                return .fields(withVolume)
            }
            return .series(name: metadata.series, volume: metadata.volume.isEmpty ? nil : metadata.volume, fields: fields)
        case .series, .notInSeries:
            return confirmation  // 利用者の確定が優先。
        }
    }

    /// 制御文字と書式文字(Cc・Cf)は読む前に落とす(見えない文字で組を割ったり、表示を崩したりさせない)。
    static func cleaned(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !($0.properties.generalCategory == .control || $0.properties.generalCategory == .format)
        }))
    }

    // MARK: - 単位ごとの計算

    /// 1 つの単位の本(中核の入口の形)から、組・確定した内容・巻を決める。
    func computeUnit(_ members: [CoreBook], explain: Bool = false) -> UnitResult {
        scoped { computeUnitUnscoped(members, explain: explain) }
    }

    private func computeUnitUnscoped(_ members: [CoreBook], explain: Bool) -> UnitResult {
        if let cache = ComputationCache.current {
            for book in members where cache.claims.count < ComputationCache.limit {
                if let claims = book.compareClaims { cache.claims[book.compareTitle] = claims }
            }
        }
        let sorted = members.sorted { $0.order < $1.order }
        var doc = WorkingDocument(books: sorted.enumerated().map { i, book in
            WorkingBook(id: i + 1, inputID: book.id, title: book.title, compareTitle: book.compareTitle,
                        source: book.source, genre: book.genre, hasEditionMarks: book.hasEditionMarks,
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
    static func seriesOrder(_ a: SeriesProposal, _ b: SeriesProposal) -> Bool { orderKey(a) < orderKey(b) }

    private static func orderKey(_ s: SeriesProposal) -> (String, String, String, SeriesID) {
        let head = s.id.rawValue.components(separatedBy: "\u{1}")[0]
        return (head.components(separatedBy: "\u{1E}")[0], s.name, s.memberIDs.min() ?? "", s.id)
    }

    /// 決まった順に並べる。**鍵は 1 つにつき 1 度だけ作る**(比べるたびに ID を切り分け、本の並びから最小を探すと、
    /// 並べ替えが提案の組み立ての大半を占める)。
    static func inSeriesOrder(_ series: [SeriesProposal]) -> [SeriesProposal] {
        series.map { (key: orderKey($0), value: $0) }.sorted { $0.key < $1.key }.map(\.value)
    }

    func bookProposal(_ book: PreparedBook, _ result: UnitResult?) -> BookProposal {
        let r = result?.books[book.input.id]
        let key = r?.seriesKey
        let seriesKind = key.flatMap { result?.seriesKinds[$0] }
        var flags = Set<BookProposal.Flag>()
        if r?.volume?.volume.inferred == true { flags.insert(.inferredVolume) }
        if book.core.hasEditionMarks { flags.insert(.edition) }
        if book.core.hasSourceMarks { flags.insert(.source) }
        if r?.isCompilation == true { flags.insert(.compilation) }
        if book.core.standsAlone { flags.insert(.standalone) }
        if seriesKind == .magazineYear || (seriesKind != nil && r?.volume?.fromMagazineIssue == true) { flags.insert(.magazineIssue) }
        if book.input.confirmation != .none { flags.insert(.confirmed) }
        // シリーズと巻数は、単位の計算で決まったものを欄へ入れる。
        var metadata = book.metadata
        metadata.series = key.flatMap { result?.seriesNames[$0] } ?? ""
        if let volume = r?.volume?.volume {
            metadata.volume = volume.text
            metadata.volumeSort = volume.sortKey
        } else if !metadata.volume.isEmpty {
            // シリーズに入らなくても、型で読んだ巻数はそのまま残す。
            metadata.volumeSort = volumes.extract(fromRemainder: " " + metadata.volume)?.number
        }
        return BookProposal(id: book.input.id, name: book.input.name, reading: book.reading, metadata: metadata,
                            seriesID: key.map { seriesID(book.unitKey, $0) }, flags: flags)
    }

    func assemble(_ prepared: Prepared, _ results: [String: UnitResult]) -> ProposalSet {
        let series = Self.inSeriesOrder(results.flatMap { seriesProposals(unitKey: $0.key, $0.value) })
        let proposals = prepared.books.map { bookProposal($0, results[$0.unitKey]) }
        var explanations: [String: Explanation] = [:]
        for result in results.values { for (id, book) in result.books { if let e = book.explanation { explanations[id] = e } } }
        return ProposalSet(proposals: proposals, series: series, rulesHash: rules.contentHash, rejected: prepared.rejected,
                           explanations: explanations)
    }
}
