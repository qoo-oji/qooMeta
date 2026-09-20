import Foundation
import Observation
import QooMetaExport
import QooMetaKit
import QooMetaRules

/// 一覧の 1 冊(提案 + 利用者の修正)。画面はこれだけを見る。
struct BookRow: Identifiable, Hashable {
    /// 本の ID(開いた起点からの相対パス)。
    let id: String
    /// 拡張子を除いたファイル名(型で読んだもの。隠せない列)。
    let fileName: String
    /// 型で読んだ結果(提案。「提案に戻す」の戻り先)。
    let reading: FormatReading
    /// 今の値(提案 + 利用者が直した欄。シリーズと巻は中核が導いたもの)。
    var metadata: BookMetadata
    /// 利用者の修正(欄・シリーズ・巻)。
    var confirmation: Confirmation
    var seriesID: SeriesID?
    var flags: Set<BookProposal.Flag>

    init(_ proposal: BookProposal, confirmation: Confirmation) {
        id = proposal.id
        fileName = proposal.name
        reading = proposal.reading
        metadata = proposal.metadata
        self.confirmation = confirmation
        seriesID = proposal.seriesID
        flags = proposal.flags
    }

    /// 利用者が直した欄。
    var edited: Set<BookMetadata.Field> { Set(confirmation.fields.values.keys) }

    /// シリーズか巻を利用者が確定しているか(一覧と詳細の印)。
    var hasConfirmedSeries: Bool {
        switch confirmation {
        case .none, .fields: false
        case .series, .notInSeries: true
        }
    }

    /// 一覧のセルに出す文字(並びの欄は「、」でつなぐ)。
    subscript(text field: BookMetadata.Field) -> String {
        metadata.values(field).joined(separator: "、")
    }

    /// 巻数(ソート用)の表示(空なら「-」)。
    var volumeSortText: String {
        guard let n = metadata.volumeSort else { return "" }
        return n == n.rounded() ? String(Int(n)) : String(n)
    }

    /// 並べ替えの鍵。シリーズは シリーズ → 巻(シリーズの無い本は後ろ)、巻は数の順(数に読めない表記は後ろ)。
    subscript(sortKey field: BookMetadata.Field) -> String {
        switch field {
        case .series:
            guard !metadata.series.isEmpty else { return "\u{10FFFF}" + metadata.title }
            return metadata.series + "\u{1}" + self[sortKey: .volume]
        case .volume:
            if let n = metadata.volumeSort { return String(format: "%012.3f", n) }
            return metadata.volume.isEmpty ? "\u{10FFFF}" : "~" + metadata.volume
        default:
            return self[text: field]
        }
    }
}

/// 絞り込みの値: 値か「(空)」。
enum ValueKey: Hashable, Comparable {
    case empty
    case value(String)

    var label: String {
        switch self {
        case .empty: "(空)"
        case .value(let v): v
        }
    }
}

/// 開いた一覧と、それへの修正(作業ファイル)。**ライブラリではない**: 覚えているのは、いま直している一覧だけ。
///
/// 本当の持ちものは「本ごとの入力(名前・プリセット・確定した内容)」で、画面に出す提案は中核が導いたもの。
/// 直すたびに全冊を計算し直さず、**変更の索引**(`ProposalIndex`)に変わった本だけを渡す(影響のある単位だけが計算し直される)。
@MainActor @Observable
final class Workspace {
    private(set) var books: [BookRow] = []
    /// 走査の起点(作業ファイルに残す。画面の題に出す)。
    private(set) var rootPath: String
    /// 保存先の作業ファイル(まだ保存していなければ nil)。
    var fileURL: URL?
    private(set) var hasUnsavedChanges = false
    /// 計算し直している最中か(大きな一覧では数秒かかる)。
    private(set) var isWorking = false

    /// フォルダごとの型の並びの割り当て。変えると、当たる本の名前を読み直す。
    private(set) var presets: Workfile.PresetAssignment
    /// フォルダの本(画像フォルダ)の ID。書き出しのファイルの種類に要る(ID の末尾からは決められない)。
    private let folderIDs: Set<String>

    private(set) var rules: CompiledRules
    private(set) var formats: FormatPresets
    /// 本ごとの入力(ID → 名前・プリセット・確定した内容)。これが持ちもの。
    private var inputs: [String: BookInput]
    /// 入れた順(一覧の既定の並び)。
    private var order: [String]
    private let index: ProposalIndex
    /// 索引への変更は入れた順に流す(あとの変更が先に着かないように)。
    private var tail: Task<Void, Never>?

    /// 一覧の絞り込み: ジャンルと著者(nil なら絞らない)、本の状態。
    var genreFilter: ValueKey?
    var authorFilter: ValueKey?
    var stateFilter: StateFilter = .all
    var searchText = ""
    var selection: Set<BookRow.ID> = []

    /// 本の状態での絞り込み(シリーズと巻を確かめて直す作業の入口)。
    enum StateFilter: String, CaseIterable, Identifiable {
        case all, notInSeries, noVolume, unmatched, edited, confirmed
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "すべて"
            case .notInSeries: "シリーズに入っていない"
            case .noVolume: "巻が空"
            case .unmatched: "型に合わなかった"
            case .edited: "直した本"
            case .confirmed: "シリーズを確定した本"
            }
        }
        func contains(_ book: BookRow) -> Bool {
            switch self {
            case .all: true
            case .notInSeries: book.seriesID == nil
            case .noVolume: book.metadata.volume.isEmpty
            case .unmatched: book.reading.formatIndex == nil
            case .edited: !book.edited.isEmpty
            case .confirmed: book.hasConfirmedSeries
            }
        }
    }

    // MARK: - 開く

    private init(workfile: Workfile, rules: CompiledRules) {
        rootPath = workfile.rootPath
        presets = workfile.presets
        self.rules = rules
        formats = rules.formats
        folderIDs = Set(workfile.books.filter(\.isFolder).map(\.id))
        let all = workfile.inputs
        inputs = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        order = all.map(\.id)
        index = ProposalIndex(rules: rules, dictionaries: SystemDictionaries.all)
    }

    /// 作業ファイルを開く(最初の計算まで待つ)。
    static func open(_ workfile: Workfile, rules: CompiledRules = .builtin) async -> Workspace {
        let workspace = Workspace(workfile: workfile, rules: rules)
        await workspace.recomputeAll()
        return workspace
    }

    /// いまの中身を作業ファイルの形にする(保存は呼び出し側)。
    var workfile: Workfile {
        Workfile(rootPath: rootPath,
                 books: order.compactMap { id in
                     inputs[id].map { .init(id: $0.id, name: $0.name, isFolder: folderIDs.contains(id), confirmation: $0.confirmation) }
                 },
                 presets: presets)
    }

    func markSaved(to url: URL) {
        fileURL = url
        hasUnsavedChanges = false
    }

    /// 規則を替える(画面で方針や語の一覧を変えたとき)。すべての本を読み直す(単位が変わりうるため)。
    func setRules(_ rules: CompiledRules) async {
        guard rules.contentHash != self.rules.contentHash else { return }
        self.rules = rules
        formats = rules.formats
        isWorking = true
        await tail?.value
        let snapshot = await Task.detached { [index] in
            try? await index.update(rules: rules, dictionaries: SystemDictionaries.all)
            return await index.snapshot()
        }.value
        absorb(snapshot)
        isWorking = false
    }

    // MARK: - 計算

    /// 全冊を索引へ入れ直す(開いたとき・規則やプリセットを替えたとき)。
    private func recomputeAll() async {
        isWorking = true
        let all = order.compactMap { inputs[$0] }
        let snapshot = await Task.detached { [index] in
            try? await index.apply(all.map { .upsert($0) })
            return await index.snapshot()
        }.value
        absorb(snapshot)
        isWorking = false
    }

    /// 変わった本だけを索引へ渡す。索引は影響のある単位だけを計算し直し、変わった提案を返す。
    private func push(_ changedIDs: [String]) {
        let changes = changedIDs.compactMap { inputs[$0] }.map { BookChange.upsert($0) }
        guard !changes.isEmpty else { return }
        let previous = tail
        isWorking = true
        tail = Task { [index] in
            await previous?.value
            let delta = await Task.detached { try? await index.apply(changes) }.value
            guard !Task.isCancelled else { return }
            if let delta { self.absorb(delta) }
            self.isWorking = false
        }
    }

    private func absorb(_ set: ProposalSet) {
        books = set.proposals.map { BookRow($0, confirmation: inputs[$0.id]?.confirmation ?? .none) }
        dropStaleFilters()
    }

    private func absorb(_ delta: ProposalDelta) {
        var byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for proposal in delta.changed {
            byID[proposal.id] = BookRow(proposal, confirmation: inputs[proposal.id]?.confirmation ?? .none)
        }
        for id in delta.removedBooks { byID[id] = nil }
        books = order.compactMap { byID[$0] }
        dropStaleFilters()
    }

    /// 書き換えで消えた値の絞り込みは外す(残すと、どの本にも合わない絞り込みで一覧が空になる)。
    private func dropStaleFilters() {
        if let g = genreFilter, !genreValues.contains(where: { $0.key == g }) { genreFilter = nil }
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
    }

    // MARK: - まとめて書き換える

    /// 選んだ本の欄を、その値で置き換える(並びの欄は値の並び、1 つの値の欄は先頭だけ)。直したら、シリーズを組み直す。
    func set(_ field: BookMetadata.Field, to newValues: [String], for ids: Set<BookRow.ID>) {
        let values = newValues.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        edit("\(field.label)を書き換える") { input in
            guard ids.contains(input.id) else { return }
            var fields = input.confirmation.fields
            fields[field] = values
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    /// 選んだ本の欄を、型で読んだ値(提案)に戻す。
    func revert(_ field: BookMetadata.Field, for ids: Set<BookRow.ID>) {
        edit("\(field.label)を提案に戻す") { input in
            guard ids.contains(input.id) else { return }
            var fields = input.confirmation.fields
            fields[field] = nil
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    /// スタンプを押す(値のある欄だけを、選んだ本すべてに入れる)。1 回の操作として取り消せる。
    func apply(_ stamp: Stamp, to ids: Set<BookRow.ID>) {
        let values = stamp.values.filter { !$0.value.isEmpty }
        guard !values.isEmpty else { return }
        edit("スタンプ「\(stamp.name)」を押す") { input in
            guard ids.contains(input.id) else { return }
            var fields = input.confirmation.fields
            for (field, value) in values { fields[field] = value }
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    // MARK: - シリーズの操作

    /// 選んだ本のタイトルから、シリーズ名の候補(共通部分)。
    func suggestedSeriesName(for ids: Set<BookRow.ID>) -> String? {
        BulkEdit.suggestedSeriesName(forTitles: books.filter { ids.contains($0.id) }.map(\.metadata.title), rules: rules)
    }

    /// 選んだ本を 1 つのシリーズにする(巻は今の値を保つ)。確定した名前は錨になり、同じ単位のほかの本もそこへ寄る。
    func setSeries(_ name: String, for ids: Set<BookRow.ID>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let volumes = Dictionary(books.map { ($0.id, Self.confirmedVolume($0)) }, uniquingKeysWith: { a, _ in a })
        edit("シリーズを「\(trimmed)」にする") { input in
            guard ids.contains(input.id) else { return }
            input.confirmation = .series(name: trimmed, volume: volumes[input.id] ?? nil, fields: input.confirmation.fields)
        }
    }

    /// シリーズから外す(規則が組にしても入れない)。
    func removeFromSeries(_ ids: Set<BookRow.ID>) {
        edit("シリーズから外す") { input in
            guard ids.contains(input.id) else { return }
            input.confirmation = .notInSeries(fields: input.confirmation.fields)
        }
    }

    /// いまの提案(シリーズと巻)をそのまま確定する = 「確かめた」印。シリーズに入っていない本は「シリーズではない」と確定する。
    func acceptProposedSeries(_ ids: Set<BookRow.ID>) {
        let rows = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        edit("シリーズと巻を確かめる") { input in
            guard ids.contains(input.id), let row = rows[input.id] else { return }
            let fields = input.confirmation.fields
            if row.seriesID != nil, !row.metadata.series.isEmpty {
                input.confirmation = .series(name: row.metadata.series,
                                             volume: row.metadata.volume.isEmpty ? nil : row.metadata.volume, fields: fields)
            } else {
                input.confirmation = .notInSeries(fields: fields)
            }
        }
    }

    /// 選んだ本に、渡された順で巻を振る(シリーズ名は今の値。無い本は飛ばす)。
    func numberSequentially(_ orderedIDs: [BookRow.ID], start: Int = 1, step: Int = 1, width: Int = 0) {
        let names = Dictionary(books.map { ($0.id, Self.currentSeriesName($0)) }, uniquingKeysWith: { a, _ in a })
        var numbers: [String: String] = [:]
        var number = start
        for id in orderedIDs where !(names[id] ?? "").isEmpty {
            let digits = String(abs(number))
            numbers[id] = (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
            number += step
        }
        edit("巻を振り直す") { input in
            guard let volume = numbers[input.id], let name = names[input.id] else { return }
            input.confirmation = .series(name: name, volume: volume, fields: input.confirmation.fields)
        }
    }

    /// 巻だけを消す(「巻は無い」と確定する)。
    func clearVolumes(_ ids: Set<BookRow.ID>) {
        let names = Dictionary(books.map { ($0.id, Self.currentSeriesName($0)) }, uniquingKeysWith: { a, _ in a })
        edit("巻を空にする") { input in
            guard ids.contains(input.id), let name = names[input.id], !name.isEmpty else { return }
            input.confirmation = .series(name: name, volume: "", fields: input.confirmation.fields)
        }
    }

    /// シリーズと巻の確定を取り消して、規則の提案に戻す(欄の直しはそのまま)。
    func revertSeries(_ ids: Set<BookRow.ID>) {
        edit("シリーズを提案に戻す") { input in
            guard ids.contains(input.id) else { return }
            let fields = input.confirmation.fields
            input.confirmation = fields.values.isEmpty ? .none : .fields(fields)
        }
    }

    /// 適用前のプレビュー: 選んだ本を 1 つのシリーズにしたとき、**選んでいない本**がいくつ巻き込まれるか。
    /// 確定した名前は錨なので、同じ単位のほかの本もそのシリーズへ寄る(api.md「確定した値の効き方」)。
    /// 状態は変えない(`ProposalIndex.preview`)。
    func previewSetSeries(_ name: String, for ids: Set<BookRow.ID>) async -> SeriesChangePreview {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SeriesChangePreview() }
        let volumes = Dictionary(books.map { ($0.id, Self.confirmedVolume($0)) }, uniquingKeysWith: { a, _ in a })
        let changes = order.compactMap { id -> BookChange? in
            guard ids.contains(id), var input = inputs[id] else { return nil }
            input.confirmation = .series(name: trimmed, volume: volumes[id] ?? nil, fields: input.confirmation.fields)
            return .upsert(input)
        }
        let before = Dictionary(books.map { ($0.id, $0.metadata.series) }, uniquingKeysWith: { a, _ in a })
        let delta = await Task.detached { [index] in try? await index.preview(changes) }.value
        var preview = SeriesChangePreview()
        for proposal in delta?.changed ?? [] {
            let old = before[proposal.id] ?? ""
            guard old != proposal.metadata.series else { continue }
            if ids.contains(proposal.id) { preview.selected += 1 } else { preview.others += 1 }
            if old.isEmpty { preview.gained += 1 } else if proposal.metadata.series.isEmpty { preview.lost += 1 }
        }
        return preview
    }

    struct SeriesChangePreview: Hashable {
        /// 選んだ本のうち、シリーズが変わる冊数。
        var selected = 0
        /// 選んでいないのに巻き込まれる冊数。
        var others = 0
        var gained = 0
        var lost = 0
        var isEmpty: Bool { selected == 0 && others == 0 }
    }

    /// 今のシリーズ名(確定した名前、無ければ提案)。
    static func currentSeriesName(_ book: BookRow) -> String {
        if case .series(let name, _, _) = book.confirmation { return name }
        return book.metadata.series
    }

    /// 今の巻の表記(確定した巻、無ければ提案。推定した巻は確定させない)。
    static func confirmedVolume(_ book: BookRow) -> String? {
        if case .series(_, let volume?, _) = book.confirmation { return volume }
        guard !book.metadata.volume.isEmpty, !book.flags.contains(.inferredVolume) else { return nil }
        return book.metadata.volume
    }

    // MARK: - 書き出し

    /// 書き出しのための今の提案(索引から取る。直している途中の変更が着いてから)。
    func currentProposals() async -> ProposalSet {
        await tail?.value
        return await Task.detached { [index] in await index.snapshot() }.value
    }

    /// 書き出しに要るファイルの事実。作業ファイルは日付とファイルノードを持たないので、起点からのパスと拡張子だけ。
    var fileFacts: [String: Exporter.FileFacts] {
        Dictionary(order.map { id in
            (id, Exporter.FileFacts(path: (rootPath as NSString).appendingPathComponent(id),
                                    fileExtension: folderIDs.contains(id) ? "" : (id as NSString).pathExtension.lowercased()))
        }, uniquingKeysWith: { a, _ in a })
    }

    var fileIdentities: [String: Exporter.FileIdentity] {
        Dictionary(order.map { id in
            (id, Exporter.FileIdentity(path: (rootPath as NSString).appendingPathComponent(id)))
        }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - フォルダごとのプリセット

    /// その本の名前を読んだ型の並び(フォルダの割り当てに従う)。
    func formats(for id: String) -> FilenameFormats { formats[presets.preset(for: id)] }

    /// 起点の直下のフォルダ(割り当ての単位)と、その冊数。
    var topLevelFolders: [(folder: String, count: Int)] {
        var counts: [String: Int] = [:]
        for id in order {
            guard let slash = id.firstIndex(of: "/") else { continue }
            counts[String(id[..<slash]), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// フォルダ(nil なら既定)に使う型の並びを替える。当たる本の名前を読み直す。
    func setPreset(_ name: String?, forFolder folder: String?) {
        var updated = presets
        if let folder {
            updated.folders[folder] = name
        } else {
            updated.defaultPreset = name
        }
        guard updated != presets else { return }
        let beforeInputs = inputs, beforePresets = presets
        presets = updated
        var changed: [String] = []
        for id in order {
            let preset = presets.preset(for: id)
            guard inputs[id]?.preset != preset else { continue }
            inputs[id]?.preset = preset
            changed.append(id)
        }
        pushUndo("型の並びを替える", beforeInputs, presets: beforePresets)
        hasUnsavedChanges = true
        push(changed)
    }

    // MARK: - 絞り込みと一覧

    static func keys(_ values: [String]) -> Set<ValueKey> {
        values.isEmpty ? [.empty] : Set(values.map(ValueKey.value))
    }

    static func counts(_ books: [BookRow], _ values: (BookRow) -> [String]) -> [(key: ValueKey, count: Int)] {
        var counts: [ValueKey: Int] = [:]
        for book in books { for key in keys(values(book)) { counts[key, default: 0] += 1 } }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var genreFiltered: [BookRow] {
        books.filter { book in genreFilter.map { Self.keys(book.metadata.values(.genre)).contains($0) } ?? true }
    }

    /// ジャンルの値ごとの冊数(「(空)」は先頭)。
    var genreValues: [(key: ValueKey, count: Int)] { Self.counts(books) { $0.metadata.values(.genre) } }
    /// 著者の値ごとの冊数(ジャンルで絞った本で数える)。
    var authorValues: [(key: ValueKey, count: Int)] { Self.counts(genreFiltered) { $0.metadata.authors } }

    /// ジャンルを変えたら、そのジャンルに無い著者の絞り込みは外す。
    func setGenreFilter(_ key: ValueKey?) {
        genreFilter = key
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
    }

    /// 一覧に出す本(ジャンル・著者・状態・検索)。
    var visibleBooks: [BookRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return genreFiltered.filter { book in
            if let a = authorFilter, !Self.keys(book.metadata.authors).contains(a) { return false }
            guard stateFilter.contains(book) else { return false }
            guard !query.isEmpty else { return true }
            let fields = BookMetadata.Field.allCases.flatMap { book.metadata.values($0) }
            return ([book.fileName] + fields).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// 選んだ本のうち、一覧に出ているものだけ(値の列や検索で隠れた本を、見えないまま書き換えないため)。
    var selectedBooks: [BookRow] { visibleBooks.filter { selection.contains($0.id) } }

    // MARK: - 取り消し

    /// 取り消せる操作(名前と、その前の持ちもの)。操作の単位は 1 回のまとめて編集。
    private struct Step {
        let name: String
        let inputs: [String: BookInput]
        let presets: Workfile.PresetAssignment
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// 取り消しで戻れる回数の上限。
    private static let undoLimit = 50

    var undoName: String? { undoSteps.last?.name }
    var redoName: String? { redoSteps.last?.name }

    /// 本ごとの入力を書き換える操作を、取り消せる 1 歩として行う。
    private func edit(_ name: String, _ change: (inout BookInput) -> Void) {
        let before = inputs
        var changed: [String] = []
        for id in order {
            guard var input = inputs[id] else { continue }
            change(&input)
            guard input != inputs[id] else { continue }
            inputs[id] = input
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        pushUndo(name, before, presets: presets)
        hasUnsavedChanges = true
        push(changed)
    }

    private func pushUndo(_ name: String, _ inputs: [String: BookInput], presets: Workfile.PresetAssignment) {
        undoSteps.append(Step(name: name, inputs: inputs, presets: presets))
        if undoSteps.count > Self.undoLimit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        redoSteps.append(Step(name: step.name, inputs: inputs, presets: presets))
        restore(step)
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(Step(name: step.name, inputs: inputs, presets: presets))
        restore(step)
    }

    private func restore(_ step: Step) {
        let changed = order.filter { inputs[$0] != step.inputs[$0] }
        inputs = step.inputs
        presets = step.presets
        hasUnsavedChanges = true
        push(changed)
    }
}

extension Confirmation {
    /// 欄の値だけを入れ替える(シリーズと巻の確定はそのまま)。
    func withFields(_ fields: ConfirmedFields) -> Confirmation {
        switch self {
        case .none, .fields: fields.values.isEmpty ? .none : .fields(fields)
        case .series(let name, let volume, _): .series(name: name, volume: volume, fields: fields)
        case .notInSeries: .notInSeries(fields: fields)
        }
    }
}
