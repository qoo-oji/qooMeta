import Foundation
import Observation
import QooMetaExport
import QooMetaKit
import QooMetaRules

/// 一覧の 1 冊(提案 + 利用者の修正)。画面はこれだけを見る。
struct BookRow: Identifiable, Hashable, Sendable {
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

    /// 並べ替えの鍵(1 冊につき 1 度だけ作る)。**比べるたびに作らない** ―― 一覧の並べ替えは 1 万冊なら
    /// 十数万回の比較になり、そのたびに文字列を組み立てると画面が固まる(2026-09-21、利用者の報告)。
    private let sortKeys: [BookMetadata.Field: String]
    /// 検索の当たり先(ファイル名とすべての欄をつないだもの)。これも 1 度だけ作る
    /// ―― 打つたびに 1 万冊ぶんの欄を組み立て直さないため。
    private let searchText: String
    /// ファイル名順での順位(小さいほうが先)。**名前そのものを比べない** ―― 名前は「(ジャンル) [著者] …」と頭が長く
    /// 重なるので、言語に合わせた比べ方(数字を数として読む順)は 1 回が重く、1.2 万冊の並べ替えに 0.3 秒かかっていた。
    /// 既定の並びなので、それが検索の 1 打鍵ごと・1 冊直すごとに main で走っていた(2026-09-21 の計測)。
    /// 名前は変わらないので、順位は開いたときに 1 度だけ決める。
    let fileRank: Int
    /// 中身の見分け(1 冊につき 1 度だけ作る)。**画面の差分は 1 万冊ぶんの `==` を呼ぶ**ので、
    /// 欄や並べ替えの鍵を 1 つずつ比べると、列を動かしただけで main が詰まる(2026-09-21、利用者の報告)。
    private let contentID: Int

    static func == (a: BookRow, b: BookRow) -> Bool { a.id == b.id && a.contentID == b.contentID }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(_ proposal: BookProposal, confirmation: Confirmation, fileRank: Int = 0) {
        self.fileRank = fileRank
        id = proposal.id
        fileName = proposal.name
        reading = proposal.reading
        metadata = proposal.metadata
        self.confirmation = confirmation
        seriesID = proposal.seriesID
        flags = proposal.flags
        sortKeys = Self.sortKeys(of: proposal.metadata)
        searchText = ([proposal.name] + BookMetadata.Field.allCases.flatMap { proposal.metadata.values($0) })
            .joined(separator: "\u{1}")
        var hasher = Hasher()
        hasher.combine(proposal.metadata)
        hasher.combine(confirmation)
        hasher.combine(proposal.seriesID)
        hasher.combine(proposal.flags)
        hasher.combine(proposal.name)
        contentID = hasher.finalize()
    }

    /// 検索の語を含むか。
    func matches(_ query: String) -> Bool { searchText.localizedCaseInsensitiveContains(query) }

    /// 欄ごとの並べ替えの鍵。シリーズは シリーズ → 巻(シリーズの無い本は後ろ)、巻は数の順
    /// (数に読めない表記は後ろ)。
    private static func sortKeys(of metadata: BookMetadata) -> [BookMetadata.Field: String] {
        var keys: [BookMetadata.Field: String] = [:]
        for field in BookMetadata.Field.allCases {
            keys[field] = metadata.values(field).joined(separator: "、")
        }
        if let n = metadata.volumeSort {
            keys[.volume] = String(format: "%012.3f", n)
        } else {
            keys[.volume] = metadata.volume.isEmpty ? "\u{10FFFF}" : "~" + metadata.volume
        }
        keys[.series] = metadata.series.isEmpty
            ? "\u{10FFFF}" + metadata.title : metadata.series + "\u{1}" + (keys[.volume] ?? "")
        return keys
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
        metadata.volumeSort.map(BookMetadata.volumeSortText) ?? ""
    }

    /// 並べ替えの鍵(組み立て済みのものを引くだけ)。
    subscript(sortKey field: BookMetadata.Field) -> String { sortKeys[field] ?? "" }
}

/// 絞り込みの値: 値か「(空)」。
enum ValueKey: Hashable, Comparable {
    case empty
    case value(String)

    var label: String {
        switch self {
        case .empty: "(empty)".ui
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
    var isWorking: Bool { working > 0 }
    /// 終わっていない計算の数。真偽で持つと、先に終わった計算が、まだ走っている計算の印まで消してしまう。
    private var working = 0

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
    /// 本の ID → `books` の中の位置。1 手ごとに全冊の辞書を作り直さないために持つ。
    private var positionByID: [String: Int] = [:]
    /// `books` の位置を、いまの並べ替えの順に並べたもの。**絞り込みと検索は、この順のまま抜き出すだけ**(並べ替え直さない)。
    private var sortedPositions: [Int] = []
    /// ファイル名順の順位(ID → 順位)。開いたときに 1 度だけ決める。
    private var fileRanks: [String: Int] = [:]
    /// 絞り込みや検索をまとめて変えている最中(途中では作り置きを作り直さない)。
    private var isBatching = false
    private var pendingSearch: Task<Void, Never>?
    /// いま走っている、規則を替えての読み直し。
    private var reloading: Task<[BookRow]?, Never>?
    private let index: ProposalIndex
    /// 索引への変更は入れた順に流す(あとの変更が先に着かないように)。
    private var tail: Task<Void, Never>?

    /// 一覧の絞り込み: ジャンルと著者(nil なら絞らない)、本の状態。
    var genreFilter: ValueKey? { didSet { if genreFilter != oldValue { filtersChanged(countsToo: true) } } }
    var authorFilter: ValueKey? { didSet { if authorFilter != oldValue { filtersChanged() } } }
    var stateFilter: StateFilter = .all { didSet { if stateFilter != oldValue { filtersChanged() } } }
    /// 検索の語。打っているあいだは少し待ってから絞る(1 打鍵ごとに全冊を見直さない)。
    var searchText = "" { didSet { if searchText != oldValue { searchChanged() } } }
    var selection: Set<BookRow.ID> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    /// 一覧の並べ替え(見出しを押して決める)。**画面ではなくここが持つ** ―― 並べ替えた結果を作り置きするため。
    var sortOrder: [KeyPathComparator<BookRow>] = [KeyPathComparator(\BookRow.fileRank)] {
        didSet { if sortOrder != oldValue { sortAll(); applyFilters() } }
    }

    /// 選んだ本のうち、一覧に出ているもの(作り置き。詳細は描くたびにこれを読むので、そのたびに全冊をなめない)。
    private(set) var selectedBooks: [BookRow] = []
    /// 選んだ本の**顔ぶれ**が変わるたびに増える番号(詳細が、入力中の値を捨てるきっかけに使う。中身が変わっただけでは増えない)。
    private(set) var selectionToken = 0

    /// 一覧にいま出す本(絞り込み + 並べ替えの結果)。**画面を描くたびに作り直さない**
    /// ―― 1 万冊の絞り込みと並べ替えを毎フレーム行うと、計算の最中に列を動かしただけで画面が固まる
    /// (2026-09-21、利用者の報告)。中身が変わったとき(本・絞り込み・並べ替え)だけ作り直す。
    private(set) var rows: [BookRow] = []
    /// 絞り込みの帯に出す、値ごとの冊数。これも作り置き。
    private(set) var genreValues: [(key: ValueKey, count: Int)] = []
    private(set) var authorValues: [(key: ValueKey, count: Int)] = []

    /// 本の状態での絞り込み(シリーズと巻を確かめて直す作業の入口)。
    enum StateFilter: String, CaseIterable, Identifiable {
        case all, notInSeries, noVolume, unmatched, edited, confirmed
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All".ui
            case .notInSeries: "Not in a series".ui
            case .noVolume: "No volume".ui
            case .unmatched: "Matched no format".ui
            case .edited: "Corrected".ui
            case .confirmed: "Series confirmed".ui
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
        // 同じ ID が 2 度書いてある作業ファイル(手で直したもの、重なりを除く前の版が書いたもの)でも、行は 1 つにする。
        // 同じ ID の行が並ぶと、一覧(Table)の振る舞いが決まらない。
        var seen = Set<String>()
        order = all.map(\.id).filter { seen.insert($0).inserted }
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
    ///
    /// **本の修正と同じ列(`tail`)に並べる。** 別々に走らせると、読み直しの結果が、その最中に入った修正の表示を
    /// 古い行で上書きしうる。書き出し(`currentProposals`)も列の終わりを待つので、読み直しの途中の提案を書き出さない。
    func setRules(_ rules: CompiledRules) async {
        guard rules.contentHash != self.rules.contentHash else { return }
        self.rules = rules
        formats = rules.formats
        // 規則を続けて直しているときは、前の読み直しを途中でやめる(その結果は、もう使わない)。
        // 索引は「全か無か」なので、やめた読み直しは何も変えない。
        reloading?.cancel()
        let previous = tail
        working += 1
        let task = Task { [index] in
            await previous?.value
            // 前の修正が着いてからの値で行を作る。
            let confirmations = self.inputs.mapValues(\.confirmation), ranks = self.fileRanks
            let work = Task.detached { () -> [BookRow]? in
                do { try await index.reload(rules: rules, dictionaries: SystemDictionaries.all) } catch { return nil }
                return await index.snapshot().proposals.map {
                    BookRow($0, confirmation: confirmations[$0.id] ?? .none, fileRank: ranks[$0.id] ?? 0)
                }
            }
            self.reloading = work
            if let rows = await work.value { self.replaceBooks(rows) }
            self.working -= 1
        }
        tail = task
        await task.value
    }

    // MARK: - 計算

    /// 全冊を索引へ入れ直す(開いたとき・規則やプリセットを替えたとき)。
    private func recomputeAll() async {
        working += 1
        let all = order.compactMap { inputs[$0] }
        // **一覧の行も、計算し直しと同じ所(main の外)で組み立てる。** 1 万冊ぶんの行を main で作ると、
        // その間じゅう画面が止まる(2026-09-21、利用者の報告)。
        let confirmations = inputs.mapValues(\.confirmation)
        let (rows, ranks) = await Task.detached { [index] in
            // まとめて入れる口(名前の読み取りも単位の計算も並列)。1 冊ずつの `apply` は 1 本で順に読む。
            try? await index.load(all)
            // ファイル名順の順位は、ここで 1 度だけ決める(名前は変わらない)。Finder と同じ、数字を数として読む順。
            let byName = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let ranks = Dictionary(byName.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            let rows = await index.snapshot().proposals.map {
                BookRow($0, confirmation: confirmations[$0.id] ?? .none, fileRank: ranks[$0.id] ?? 0)
            }
            return (rows, ranks)
        }.value
        fileRanks = ranks
        replaceBooks(rows)
        working -= 1
    }

    /// 変わった本だけを索引へ渡す。索引は影響のある単位だけを計算し直し、変わった提案を返す。
    private func push(_ changedIDs: [String]) {
        let changes = changedIDs.compactMap { inputs[$0] }.map { BookChange.upsert($0) }
        guard !changes.isEmpty else { return }
        let previous = tail
        working += 1
        tail = Task { [index] in
            await previous?.value
            let delta = await Task.detached { try? await index.apply(changes) }.value
            if let delta { self.absorb(delta) }
            self.working -= 1
        }
    }

    /// 変わった本の行だけを入れ替える(**1 手ごとに全冊の辞書や配列を作り直さない**)。本は足しも消しもしないので、
    /// 位置は開いたときのまま。
    private func absorb(_ delta: ProposalDelta) {
        var changed: [Int] = []
        var books = self.books
        self.books = []            // 1 つだけの持ち主にして、その場で書き換える(全冊ぶんの写しを作らない)
        for proposal in delta.changed {
            guard let position = positionByID[proposal.id] else { continue }
            books[position] = BookRow(proposal, confirmation: inputs[proposal.id]?.confirmation ?? .none,
                                      fileRank: fileRanks[proposal.id] ?? 0)
            changed.append(position)
        }
        self.books = books
        resort(changed)
        booksChanged()
    }

    /// 行を丸ごと入れ替える(開いたとき・規則を替えたとき)。
    private func replaceBooks(_ rows: [BookRow]) {
        books = rows
        positionByID = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        sortAll()
        booksChanged()
    }

    /// 本の中身が変わったあとの作り置きの作り直し(冊数の数え直し → 消えた値の絞り込みを外す → 一覧)。1 手につき 1 度だけ。
    private func booksChanged() {
        isBatching = true
        rebuildCounts()
        // 書き換えで消えた値の絞り込みは外す(残すと、どの本にも合わない絞り込みで一覧が空になる)。
        if let g = genreFilter, !genreValues.contains(where: { $0.key == g }) {
            genreFilter = nil
            rebuildCounts()
        }
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
        isBatching = false
        applyFilters()
    }

    // MARK: - まとめて書き換える

    /// 選んだ本の欄を、その値で置き換える(並びの欄は値の並び、1 つの値の欄は先頭だけ)。直したら、シリーズを組み直す。
    func set(_ field: BookMetadata.Field, to newValues: [String], for ids: Set<BookRow.ID>) {
        let values = newValues.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        edit("Change %@".ui(field.labelKey.ui), ids) { input in
            var fields = input.confirmation.fields
            fields[field] = values
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    /// 選んだ本の欄を、型で読んだ値(提案)に戻す。
    func revert(_ field: BookMetadata.Field, for ids: Set<BookRow.ID>) {
        edit("Revert %@ to the proposal".ui(field.labelKey.ui), ids) { input in
            var fields = input.confirmation.fields
            fields[field] = nil
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    /// スタンプを押す(値のある欄だけを、選んだ本すべてに入れる)。1 回の操作として取り消せる。
    func apply(_ stamp: Stamp, to ids: Set<BookRow.ID>) {
        let values = stamp.values.filter { !$0.value.isEmpty }
        guard !values.isEmpty else { return }
        edit("Apply stamp “%@”".ui(stamp.name), ids) { input in
            var fields = input.confirmation.fields
            for (field, value) in values { fields[field] = value }
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    // MARK: - シリーズの操作

    /// 選んだ本のタイトルから、シリーズ名の候補(共通部分)。
    func suggestedSeriesName(for ids: Set<BookRow.ID>) -> String? {
        // 並びは入れた順(候補は、最初の本のタイトルから切り出す)。
        BulkEdit.suggestedSeriesName(forTitles: ids.compactMap { positionByID[$0] }.sorted().map { books[$0].metadata.title },
                                     rules: rules)
    }

    /// 選んだ本を 1 つのシリーズにする(巻は今の値を保つ)。確定した名前は錨になり、同じ単位のほかの本もそこへ寄る。
    func setSeries(_ name: String, for ids: Set<BookRow.ID>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Set the series to “%@”".ui(trimmed), ids) { input in
            let volume = self.row(input.id).flatMap(Self.confirmedVolume)
            input.confirmation = .series(name: trimmed, volume: volume, fields: input.confirmation.fields)
        }
    }

    /// シリーズから外す(規則が組にしても入れない)。
    func removeFromSeries(_ ids: Set<BookRow.ID>) {
        edit("Remove from the series".ui, ids) { input in
            input.confirmation = .notInSeries(fields: input.confirmation.fields)
        }
    }

    /// いまの提案(シリーズと巻)をそのまま確定する = 「確かめた」印。シリーズに入っていない本は「シリーズではない」と確定する。
    func acceptProposedSeries(_ ids: Set<BookRow.ID>) {
        edit("Confirm the series and volume".ui, ids) { input in
            guard let row = self.row(input.id) else { return }
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
        var numbers: [String: (name: String, volume: String)] = [:]
        var number = start
        for id in orderedIDs {
            guard let name = row(id).map(Self.currentSeriesName), !name.isEmpty else { continue }
            let digits = String(abs(number))
            numbers[id] = (name, (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits)
            number += step
        }
        edit("Number the volumes again".ui, numbers.keys) { input in
            guard let (name, volume) = numbers[input.id] else { return }
            input.confirmation = .series(name: name, volume: volume, fields: input.confirmation.fields)
        }
    }

    /// 巻数を手で決める(選んだ本すべてに同じ表記を入れる)。シリーズ名の無い本は触らない
    /// ―― 巻数はシリーズの中の番号なので、シリーズが決まっていないと意味を持たない。
    func setVolumes(_ volume: String, for ids: Set<BookRow.ID>) {
        edit("Set the volume".ui, ids) { input in
            guard let name = self.row(input.id).map(Self.currentSeriesName), !name.isEmpty else { return }
            input.confirmation = .series(name: name, volume: volume, fields: input.confirmation.fields)
        }
    }

    /// 巻だけを消す(「巻は無い」と確定する)。
    func clearVolumes(_ ids: Set<BookRow.ID>) {
        edit("Clear the volume".ui, ids) { input in
            guard let name = self.row(input.id).map(Self.currentSeriesName), !name.isEmpty else { return }
            input.confirmation = .series(name: name, volume: "", fields: input.confirmation.fields)
        }
    }

    /// シリーズと巻の確定を取り消して、規則の提案に戻す(欄の直しはそのまま)。
    func revertSeries(_ ids: Set<BookRow.ID>) {
        edit("Revert the series to the proposal".ui, ids) { input in
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
        let changes = ids.sorted().compactMap { id -> BookChange? in
            guard var input = inputs[id] else { return nil }
            input.confirmation = .series(name: trimmed, volume: row(id).flatMap(Self.confirmedVolume), fields: input.confirmation.fields)
            return .upsert(input)
        }
        let delta = await Task.detached { [index] in try? await index.preview(changes) }.value
        var preview = SeriesChangePreview()
        for proposal in delta?.changed ?? [] {
            let old = row(proposal.id)?.metadata.series ?? ""
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

    /// その本の、いまの行。
    private func row(_ id: String) -> BookRow? { positionByID[id].map { books[$0] } }

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

    /// フォルダ(nil なら既定)に使う型の並びを替える。当たる本の名前を読み直す。
    func setPreset(_ name: String?, forFolder folder: String?) {
        var updated = presets
        if let folder {
            updated.folders[folder] = name
        } else {
            updated.defaultPreset = name
        }
        guard updated != presets else { return }
        let beforePresets = presets
        presets = updated
        var changed: [String] = []
        var previous: [String: BookInput] = [:]
        for id in order {
            let preset = presets.preset(for: id)
            guard let input = inputs[id], input.preset != preset else { continue }
            previous[id] = input
            inputs[id]?.preset = preset
            changed.append(id)
        }
        pushUndo("Change the format list".ui, previous, presets: beforePresets)
        hasUnsavedChanges = true
        push(changed)
    }

    // MARK: - 絞り込みと一覧

    static func keys(_ values: [String]) -> Set<ValueKey> {
        values.isEmpty ? [.empty] : Set(values.map(ValueKey.value))
    }

    /// その値の並びが、絞り込みの値に当たるか(1 冊ごとに集合を作らない ―― 絞り込みは全冊をなめる)。
    static func matches(_ values: [String], _ key: ValueKey) -> Bool {
        switch key {
        case .empty: values.isEmpty
        case .value(let value): values.contains(value)
        }
    }

    static func counts(_ books: [BookRow], _ values: (BookRow) -> [String]) -> [(key: ValueKey, count: Int)] {
        var counts: [ValueKey: Int] = [:]
        for book in books {
            let values = values(book)
            // 値が 1 つまでなら(ほとんどの本)、重なりを除くための集合は要らない。
            if values.count <= 1 { counts[values.first.map(ValueKey.value) ?? .empty, default: 0] += 1 }
            else { for key in keys(values) { counts[key, default: 0] += 1 } }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// ジャンルを変えたら、そのジャンルに無い著者の絞り込みは外す。
    func setGenreFilter(_ key: ValueKey?) {
        isBatching = true
        genreFilter = key
        rebuildCounts()
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
        isBatching = false
        applyFilters()
    }

    /// 一覧に出す本(作り置き)。
    var visibleBooks: [BookRow] { rows }

    private func matchesGenre(_ book: BookRow) -> Bool {
        switch genreFilter {
        case nil: true
        case .empty?: book.metadata.genre.isEmpty
        case .value(let genre)?: book.metadata.genre == genre
        }
    }

    /// 絞り込みの帯に出す、値ごとの冊数。本の中身か、ジャンルの絞り込みが変わったときだけ数え直す。
    private func rebuildCounts() {
        genreValues = Self.counts(books) { $0.metadata.values(.genre) }
        authorValues = Self.counts(genreFilter == nil ? books : books.filter(matchesGenre)) { $0.metadata.authors }
    }

    private func filtersChanged(countsToo: Bool = false) {
        guard !isBatching else { return }
        if countsToo { rebuildCounts() }
        applyFilters()
    }

    private func searchChanged() {
        pendingSearch?.cancel()
        // 語を消したときは、待たずに戻す。
        guard !searchText.isEmpty else { return applyFilters() }
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    /// 並べ替えの順で比べる(同じなら入れた順)。
    private func precedes(_ a: Int, _ b: Int) -> Bool {
        for comparator in sortOrder {
            switch comparator.compare(books[a], books[b]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return a < b
    }

    /// 全冊を並べ替える(本を入れ替えたとき・並べ替えの指定が変わったときだけ)。
    private func sortAll() {
        sortedPositions = books.indices.sorted(by: precedes)
    }

    /// 変わった本だけを、並びの正しい所へ入れ直す。変わった数が多いときは、全体を並べ替える。
    private func resort(_ changed: [Int]) {
        guard !changed.isEmpty else { return }
        guard sortedPositions.count == books.count, changed.count * 8 < books.count else { return sortAll() }
        let moving = Set(changed)
        sortedPositions.removeAll(where: moving.contains)
        for position in changed.sorted() {
            var low = 0, high = sortedPositions.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(sortedPositions[middle], position) { low = middle + 1 } else { high = middle }
            }
            sortedPositions.insert(position, at: low)
        }
    }

    /// 一覧に出す本を作り直す。**並べ替えはしない** ―― 並べ替え済みの順から、絞り込みと検索に合う本を抜き出すだけ。
    private func applyFilters() {
        pendingSearch?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let plain = genreFilter == nil && authorFilter == nil && stateFilter == .all && query.isEmpty
        rows = sortedPositions.compactMap { position in
            let book = books[position]
            if plain { return book }
            guard matchesGenre(book) else { return nil }
            if let a = authorFilter, !Self.matches(book.metadata.authors, a) { return nil }
            guard stateFilter.contains(book) else { return nil }
            return query.isEmpty || book.matches(query) ? book : nil
        }
        selectionChanged()
    }

    /// 選んだ本のうち、一覧に出ているものだけ(値の列や検索で隠れた本を、見えないまま書き換えないため)。
    private func selectionChanged() {
        let picked = selection.isEmpty ? [] : rows.filter { selection.contains($0.id) }
        if picked.map(\.id) != selectedBooks.map(\.id) { selectionToken += 1 }
        if picked != selectedBooks { selectedBooks = picked }
    }

    // MARK: - 取り消し

    /// 取り消せる操作(名前と、その前の持ちもの)。操作の単位は 1 回のまとめて編集。
    ///
    /// **持つのは、その操作で変わった本の、前の入力だけ。** 全冊の入力を 1 手ごとに丸ごと持つと、1 万冊で 50 手ぶん
    /// 百 MB に届き、冊数に比べて伸びる(2026-09-21 の監査)。本は足しも消しもしないので、変わった本だけで元に戻せる。
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
    /// **なめるのは、その操作が当たる本だけ**(1 冊直すのに、全冊の入力を見て回らない)。
    private func edit(_ name: String, _ ids: some Sequence<String>, _ change: (inout BookInput) -> Void) {
        var previous: [String: BookInput] = [:]
        var changed: [String] = []
        for id in ids {
            guard let before = inputs[id] else { continue }
            var input = before
            change(&input)
            guard input != before else { continue }
            previous[id] = before
            inputs[id] = input
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        pushUndo(name, previous, presets: presets)
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
        redoSteps.append(restore(step))
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(restore(step))
    }

    /// その操作の前へ戻し、逆向きの 1 歩(戻す前の値)を返す。
    private func restore(_ step: Step) -> Step {
        var current: [String: BookInput] = [:]
        for (id, input) in step.inputs {
            current[id] = inputs[id]
            inputs[id] = input
        }
        let reverse = Step(name: step.name, inputs: current, presets: presets)
        presets = step.presets
        hasUnsavedChanges = true
        push(order.filter { step.inputs[$0] != nil && current[$0] != step.inputs[$0] })
        return reverse
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
