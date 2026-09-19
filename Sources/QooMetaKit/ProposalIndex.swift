import Foundation

/// 本の追加・変更・削除のたびに、影響のある単位(書き手 + 本の種別)だけを計算し直す。
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
    private var cachedSnapshot: ProposalSet?

    public init(rules: CompiledRules, vocabulary: Vocabulary, options: ProposalOptions = .default) {
        engine = RuleEngine(rules: rules, vocabulary: vocabulary)
        self.options = options
    }

    /// 足す・変える・消す。影響のある単位だけを計算し直し、変わった提案を返す。
    @discardableResult
    public func apply(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta {
        let (next, delta) = try compute(changes, from: state, engine: engine)
        state = next
        cachedSnapshot = nil
        return delta
    }

    /// 状態を変えずに、変更を当てた場合の差分を返す(「ほかに n 冊がこのシリーズに入ります」)。
    public func preview(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta {
        try compute(changes, from: state, engine: engine).1
    }

    /// 規則・語彙を替える。すべての本を読み直す(単位が変わりうるため)。
    @discardableResult
    public func update(rules: CompiledRules, vocabulary: Vocabulary) throws(CancellationError) -> ProposalDelta {
        let newEngine = RuleEngine(rules: rules, vocabulary: vocabulary)
        let inputs = state.books.values.sorted { $0.order < $1.order }.map(\.input)
        // 扱わなかった入力の理由は上限だけで決まり、規則には依らないので、そのまま持ち越す。
        var fresh = State()
        fresh.rejected = state.rejected
        let (next, _) = try compute(inputs.map { .upsert($0) }, from: fresh, engine: newEngine)
        let before = snapshot()
        engine = newEngine
        state = next
        cachedSnapshot = nil
        let after = snapshot()
        return ProposalDelta(before: before, after: after)
    }

    public func proposal(for id: String) -> BookProposal? {
        guard let book = state.books[id] else { return nil }
        return engine.bookProposal(book, state.unitResults[book.unitKey])
    }

    public func snapshot() -> ProposalSet {
        if let cachedSnapshot { return cachedSnapshot }
        let books = state.books.values.sorted { $0.order < $1.order }
        let prepared = Prepared(books: books, units: [:], rejected: state.rejected.values.sorted { $0.id < $1.id })
        let set = engine.assemble(prepared, state.unitResults)
        cachedSnapshot = set
        return set
    }

    /// 変更を当てた次の状態と、差分。
    private func compute(_ changes: [BookChange], from current: State, engine: RuleEngine) throws(CancellationError)
        -> (State, ProposalDelta) {
        var s = current
        var affected = Set<String>()
        var touched = Set<String>()
        for change in changes {
            let id: String
            switch change {
            case .upsert(let input): id = input.id
            case .remove(let removed): id = removed
            }
            touched.insert(id)
            let order = s.books[id]?.order
            if let old = s.books.removeValue(forKey: id) {
                affected.insert(old.unitKey)
                s.unitMembers[old.unitKey]?.remove(id)
            }
            s.rejected[id] = nil
            guard case .upsert(let input) = change else { continue }
            if s.books.count >= options.limits.maxBooks {
                s.rejected[id] = InputIssue(id: id, reason: .tooManyBooks)
                continue
            }
            if let reason = RuleEngine.issue(input, limits: options.limits) {
                s.rejected[id] = InputIssue(id: id, reason: reason)
                continue
            }
            let book = engine.prepareOne(input, order: order ?? s.nextOrder)
            if order == nil { s.nextOrder += 1 }
            s.books[id] = book
            s.unitMembers[book.unitKey, default: []].insert(id)
            affected.insert(book.unitKey)
        }

        var before: [String: UnitResult] = [:]
        for key in affected.sorted() {
            if Task.isCancelled { throw CancellationError() }
            before[key] = s.unitResults[key]
            let members = (s.unitMembers[key] ?? []).compactMap { s.books[$0] }
            if members.isEmpty {
                s.unitResults[key] = nil
                s.unitMembers[key] = nil
            } else {
                s.unitResults[key] = engine.computeUnit(members)
            }
        }
        if Task.isCancelled { throw CancellationError() }

        // 差分: 影響のあった単位の本(前と後)と、シリーズ。
        let oldSeries = Dictionary(before.flatMap { engine.seriesProposals(unitKey: $0.key, $0.value) }.map { ($0.id, $0) },
                                   uniquingKeysWith: { a, _ in a })
        let newSeries = Dictionary(affected.flatMap { key in
            s.unitResults[key].map { engine.seriesProposals(unitKey: key, $0) } ?? []
        }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = touched
        for key in affected { ids.formUnion(s.unitMembers[key] ?? []) }
        for result in before.values { ids.formUnion(result.books.keys) }
        var changed: [BookProposal] = []
        for id in ids.sorted() {
            guard let book = s.books[id] else { continue }
            let new = engine.bookProposal(book, s.unitResults[book.unitKey])
            let old = current.books[id].map { engine.bookProposal($0, current.unitResults[$0.unitKey]) }
            if old != new { changed.append(new) }
        }
        let removedBooks = touched.filter { current.books[$0] != nil && s.books[$0] == nil }.sorted()
        let delta = ProposalDelta(
            changed: changed,
            removedBooks: removedBooks,
            removedSeries: oldSeries.keys.filter { newSeries[$0] == nil }.sorted(),
            changedSeries: newSeries.values.filter { oldSeries[$0.id] != $0 }.sorted(by: RuleEngine.seriesOrder))
        return (s, delta)
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
