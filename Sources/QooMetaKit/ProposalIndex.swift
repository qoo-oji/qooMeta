import Foundation

/// 本の追加・変更・削除のたびに、影響のある単位(書き手 + ジャンル)だけを計算し直す。
///
/// **`apply` の結果は、同じ本の一覧(入れた順)を `proposeSync` に渡した結果と常に同じ**(テストで確かめる)。提案は単位の
/// 中だけで決まるので、変わった本の、前と後の単位だけを計算し直せばよい。
///
/// **全か無か**: 取り消されたら、状態は呼ぶ前のまま。
public actor ProposalIndex {
    struct State: Sendable {
        var books: [String: PreparedBook] = [:]
        var unitMembers: [String: Set<String>] = [:]
        var unitResults: [String: UnitResult] = [:]
        var rejected: [String: InputIssue] = [:]
        /// 入れた順の番号(次に使う番号)。変更した本は前の番号を保つ。
        var nextOrder = 0
    }

    private var engine: RuleEngine
    private let options: ProposalOptions
    private var state = State()

    public init(rules: CompiledRules, dictionaries: [String: WordSet], options: ProposalOptions = .default) {
        engine = RuleEngine(rules: rules, dictionaries: dictionaries)
        self.options = options
    }

    /// 足す・変える・消す。影響のある単位だけを計算し直し、変わった提案を返す。
    @discardableResult
    public func apply(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta {
        var undo = Undo(nextOrder: state.nextOrder)
        do {
            return try compute(changes, undo: &undo)
        } catch {
            restore(undo)
            throw error
        }
    }

    /// 状態を変えずに、変更を当てた場合の差分を返す(「ほかに n 冊がこのシリーズに入ります」)。
    public func preview(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta {
        var undo = Undo(nextOrder: state.nextOrder)
        defer { restore(undo) }
        return try compute(changes, undo: &undo)
    }

    /// 空の索引へ、一覧をまとめて入れる。**名前の読み取りも単位の計算も並列に行う**(`apply` は 1 本で順に読むので、
    /// 1 万冊を開くのに数倍かかる)。結果は `apply` で同じ一覧を入れたときと同じ。空でなければ `apply` と同じ道を通る。
    public func load(_ inputs: [BookInput]) async throws(CancellationError) {
        guard state.books.isEmpty, state.rejected.isEmpty, state.nextOrder == 0 else {
            _ = try apply(inputs.map { .upsert($0) })
            return
        }
        let engine = engine
        // 入力の確かめは順に(`compute` と同じ決まり: 同じ ID は後のものが勝ち、順番は最初のもの)。
        var lastIndex: [String: Int] = [:]
        for (i, input) in inputs.enumerated() { lastIndex[input.id] = i }
        var accepted: [(input: BookInput, order: Int)] = []
        var orderByID: [String: Int] = [:]
        var rejected: [String: InputIssue] = [:]
        var nextOrder = 0
        for (i, input) in inputs.enumerated() {
            // 順番は最初に現れたときに決まる(その入力が断られていなければ)。
            let isLast = lastIndex[input.id] == i
            let issue: InputIssue.Reason? = accepted.count >= options.limits.maxBooks && orderByID[input.id] == nil
                ? .tooManyBooks : RuleEngine.issue(input, limits: options.limits)
            if issue == nil, orderByID[input.id] == nil {
                orderByID[input.id] = nextOrder
                nextOrder += 1
            }
            guard isLast else { continue }
            if let issue {
                // 後の入力が断られたら、その本は入らない(前に受け付けた分も、`compute` では置き換えで消える)。
                rejected[input.id] = InputIssue(id: input.id, reason: issue)
            } else {
                accepted.append((input, orderByID[input.id]!))
            }
        }
        // 同じ ID が重なる入力(まず無い)は、決まりが込み入るので 1 本の道に任せる。
        guard lastIndex.count == inputs.count else {
            _ = try apply(inputs.map { .upsert($0) })
            return
        }
        let books = try await engine.prepareInParallel(accepted)
        let units = Dictionary(grouping: books, by: \.unitKey)
        let results = try await engine.computeUnitsInParallel(units.mapValues { $0.map(\.core) }, explain: options.explanations)
        // 待っているあいだに別の変更が入っていたら、そちらを壊さない(1 本の道でやり直す)。
        guard state.books.isEmpty, state.nextOrder == 0, engine.rules.contentHash == self.engine.rules.contentHash else {
            _ = try apply(inputs.map { .upsert($0) })
            return
        }
        var next = State()
        next.books = Dictionary(books.map { ($0.input.id, $0) }, uniquingKeysWith: { _, b in b })
        next.unitMembers = units.mapValues { Set($0.map(\.input.id)) }
        next.unitResults = results
        next.rejected = rejected
        next.nextOrder = nextOrder
        state = next
    }

    /// 規則・語彙を替える。すべての本を読み直す(単位が変わりうるため)。並列に行い、取り消されたら状態は前のまま。
    ///
    /// **型の並びも、巻の読み手も変わっていなければ、名前は読み直さない**(前の読みを使う)。名前の読み取りは計算の
    /// 半分を占め、シリーズの規則だけを直したときには結果が変わらない。巻の読み手を見るのは、`@volume` がそれを使うため。
    public func reload(rules: CompiledRules, dictionaries: [String: WordSet]) async throws(CancellationError) {
        let newEngine = RuleEngine(rules: rules, dictionaries: dictionaries)
        let old = engine.rules
        let readsTheSame = old.formats == rules.formats
            && old.mergedSeriesRules["volume"] == rules.mergedSeriesRules["volume"]
            && old.mergedSeriesRules["lists"] == rules.mergedSeriesRules["lists"]
            && old.mergedSeriesRules["policies"] == rules.mergedSeriesRules["policies"]
        let current = state.books.values.sorted { $0.core.order < $1.core.order }
        let accepted = current.map { (input: $0.input, order: $0.core.order) }
        let readings = readsTheSame ? Dictionary(current.map { ($0.input.id, $0.reading) }, uniquingKeysWith: { a, _ in a }) : nil
        let stamp = state.nextOrder
        let books = try await newEngine.prepareInParallel(accepted, readings: readings)
        let units = Dictionary(grouping: books, by: \.unitKey)
        let results = try await newEngine.computeUnitsInParallel(units.mapValues { $0.map(\.core) }, explain: options.explanations)
        // 待っているあいだに本が変わっていたら、1 本の道でやり直す(まず起きない。利用側が順に流している)。
        guard state.nextOrder == stamp, state.books.count == books.count,
              books.allSatisfy({ state.books[$0.input.id]?.input == $0.input }) else {
            _ = try update(rules: rules, dictionaries: dictionaries)
            return
        }
        engine = newEngine
        state.books = Dictionary(books.map { ($0.input.id, $0) }, uniquingKeysWith: { _, b in b })
        state.unitMembers = units.mapValues { Set($0.map(\.input.id)) }
        state.unitResults = results
    }

    /// 規則・語彙を替えて、前後の差分を返す(1 本で順に計算する。差分の要らない利用側は `reload`)。
    @discardableResult
    public func update(rules: CompiledRules, dictionaries: [String: WordSet]) throws(CancellationError) -> ProposalDelta {
        let before = snapshot()
        let inputs = state.books.values.sorted { $0.core.order < $1.core.order }
        let kept = state
        // 扱わなかった入力の理由は上限だけで決まり、規則には依らないので、そのまま持ち越す。
        let oldEngine = engine
        engine = RuleEngine(rules: rules, dictionaries: dictionaries)
        state = State()
        state.rejected = kept.rejected
        var undo = Undo(nextOrder: 0)
        do {
            _ = try compute(inputs.map { .upsert($0.input) }, undo: &undo)
        } catch {
            engine = oldEngine
            state = kept
            throw error
        }
        return ProposalDelta(before: before, after: snapshot())
    }

    public func proposal(for id: String) -> BookProposal? {
        guard let book = state.books[id] else { return nil }
        return engine.bookProposal(book, state.unitResults[book.unitKey])
    }

    /// いまの提案の全体。**作り置きはしない**(全冊ぶんの写しを持ち続けない。要るのは開いたとき・規則を替えたとき・書き出すときだけ)。
    public func snapshot() -> ProposalSet {
        let books = state.books.values.sorted { $0.core.order < $1.core.order }
        let prepared = Prepared(books: books, units: [:], rejected: state.rejected.values.sorted { $0.id < $1.id })
        return engine.assemble(prepared, state.unitResults)
    }

    /// 変える前の値の控え(変わった所だけ)。取り消されたとき・試しただけのときに、これで元へ戻す。
    ///
    /// 前は、状態を丸ごと写してから書き換えていた。辞書は書き換えた時点で全体が複製されるので、1 冊の変更が
    /// 冊数に比例し(10 万冊で 48 ms)、そのあいだメモリも 2 倍になっていた(2026-09-21 の計測)。
    private struct Undo {
        var books: [String: PreparedBook?] = [:]
        var rejected: [String: InputIssue?] = [:]
        var unitMembers: [String: Set<String>?] = [:]
        var unitResults: [String: UnitResult?] = [:]
        var nextOrder: Int
    }

    private func restore(_ undo: Undo) {
        for (id, book) in undo.books { state.books[id] = book }
        for (id, issue) in undo.rejected { state.rejected[id] = issue }
        for (key, members) in undo.unitMembers { state.unitMembers[key] = members }
        for (key, result) in undo.unitResults { state.unitResults[key] = result }
        state.nextOrder = undo.nextOrder
    }

    /// 変更を状態へ当て、差分を返す。変える前の値は `undo` に控える。
    private func compute(_ changes: [BookChange], undo: inout Undo) throws(CancellationError) -> ProposalDelta {
        var affected = Set<String>()
        var touched = Set<String>()
        func remember(unit key: String) {
            if undo.unitMembers[key] == nil { undo.unitMembers[key] = .some(state.unitMembers[key]) }
            if undo.unitResults[key] == nil { undo.unitResults[key] = .some(state.unitResults[key]) }
        }
        for change in changes {
            let id: String
            switch change {
            case .upsert(let input): id = input.id
            case .remove(let removed): id = removed
            }
            touched.insert(id)
            if undo.books[id] == nil { undo.books[id] = .some(state.books[id]) }
            if undo.rejected[id] == nil { undo.rejected[id] = .some(state.rejected[id]) }
            let order = state.books[id]?.core.order
            if let old = state.books.removeValue(forKey: id) {
                remember(unit: old.unitKey)
                affected.insert(old.unitKey)
                state.unitMembers[old.unitKey]?.remove(id)
            }
            state.rejected[id] = nil
            guard case .upsert(let input) = change else { continue }
            if state.books.count >= options.limits.maxBooks {
                state.rejected[id] = InputIssue(id: id, reason: .tooManyBooks)
                continue
            }
            if let reason = RuleEngine.issue(input, limits: options.limits) {
                state.rejected[id] = InputIssue(id: id, reason: reason)
                continue
            }
            let book = engine.prepareOne(input, order: order ?? state.nextOrder)
            if order == nil { state.nextOrder += 1 }
            remember(unit: book.unitKey)
            state.books[id] = book
            state.unitMembers[book.unitKey, default: []].insert(id)
            affected.insert(book.unitKey)
        }

        for key in affected.sorted() {
            if Task.isCancelled { throw CancellationError() }
            let members = (state.unitMembers[key] ?? []).compactMap { state.books[$0] }
            if members.isEmpty {
                state.unitResults[key] = nil
                state.unitMembers[key] = nil
            } else {
                state.unitResults[key] = engine.computeUnit(members.map(\.core), explain: options.explanations)
            }
        }
        if Task.isCancelled { throw CancellationError() }

        // 差分: 影響のあった単位の本(前と後)と、シリーズ。前の値は控えから取る。
        let before = undo.unitResults.compactMapValues { $0 }.filter { affected.contains($0.key) }
        let oldSeries = Dictionary(before.flatMap { engine.seriesProposals(unitKey: $0.key, $0.value) }.map { ($0.id, $0) },
                                   uniquingKeysWith: { a, _ in a })
        let newSeries = Dictionary(affected.flatMap { key in
            state.unitResults[key].map { engine.seriesProposals(unitKey: key, $0) } ?? []
        }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = touched
        for key in affected { ids.formUnion(state.unitMembers[key] ?? []) }
        for result in before.values { ids.formUnion(result.books.keys) }
        func oldBook(_ id: String) -> PreparedBook? {
            if let kept = undo.books[id] { return kept }
            return state.books[id]
        }
        func oldResult(_ key: String) -> UnitResult? {
            if let kept = undo.unitResults[key] { return kept }
            return state.unitResults[key]
        }
        var changed: [BookProposal] = []
        for id in ids.sorted() {
            guard let book = state.books[id] else { continue }
            let new = engine.bookProposal(book, state.unitResults[book.unitKey])
            let old = oldBook(id).map { engine.bookProposal($0, oldResult($0.unitKey)) }
            if old != new { changed.append(new) }
        }
        let removedBooks = touched.filter { oldBook($0) != nil && state.books[$0] == nil }.sorted()
        return ProposalDelta(
            changed: changed,
            removedBooks: removedBooks,
            removedSeries: oldSeries.keys.filter { newSeries[$0] == nil }.sorted(),
            changedSeries: RuleEngine.inSeriesOrder(newSeries.values.filter { oldSeries[$0.id] != $0 }))
    }
}

/// ProposalIndex への変更。
public enum BookChange: Sendable, Hashable {
    case upsert(BookInput)
    case remove(id: String)
}

public struct ProposalDelta: Sendable {
    /// 変わった(または新しく入った)本の提案。
    public let changed: [BookProposal]
    /// 消えた本。
    public let removedBooks: [String]
    public let removedSeries: [SeriesID]
    /// 変わった(または新しくできた)シリーズ。
    public let changedSeries: [SeriesProposal]

    init(changed: [BookProposal], removedBooks: [String], removedSeries: [SeriesID], changedSeries: [SeriesProposal]) {
        self.changed = changed
        self.removedBooks = removedBooks
        self.removedSeries = removedSeries
        self.changedSeries = changedSeries
    }

    /// 2 つの提案の全体の差分。
    init(before: ProposalSet, after: ProposalSet) {
        let old = Dictionary(before.proposals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldSeries = Dictionary(before.series.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newSeries = Set(after.series.map(\.id))
        let newIDs = Set(after.proposals.map(\.id))
        self.init(changed: after.proposals.filter { old[$0.id] != $0 },
                  removedBooks: before.proposals.map(\.id).filter { !newIDs.contains($0) },
                  removedSeries: before.series.map(\.id).filter { !newSeries.contains($0) },
                  changedSeries: after.series.filter { oldSeries[$0.id] != $0 })
    }
}
