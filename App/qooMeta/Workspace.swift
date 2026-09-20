import Foundation
import Observation
import QooMetaKit
import QooMetaRules

/// 一覧の 1 冊。
struct BookRow: Identifiable, Hashable {
    /// 本の ID(開いたフォルダからの相対パス)。
    let id: String
    /// 拡張子を除いたファイル名(型で読んだもの。隠せない列)。
    let fileName: String
    /// 型で読んだ結果(提案。「提案に戻す」の戻り先)。
    let reading: FormatReading
    /// 今の値(提案 + 利用者が直した欄)。シリーズと巻は中核が導いたもの。
    var metadata: BookMetadata
    /// 利用者が直した欄。
    var edited: Set<BookMetadata.Field> = []
    /// 利用者が確定したシリーズと巻(中核へ渡す錨。`.none` なら規則の提案のまま)。
    var confirmation: Confirmation = .none
    var seriesID: SeriesID?

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

/// 開いた一覧と、それへの修正(作業ファイル。段階 8 で保存できるようにする)。ライブラリではない。
@MainActor @Observable
final class Workspace {
    private(set) var books: [BookRow] = []
    let formats: FilenameFormats
    private let derivation: SeriesDerivation

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

    init(files: [(id: String, name: String)], formats: FilenameFormats = .preset) {
        self.formats = formats
        derivation = SeriesDerivation(rules: .builtin, dictionaries: SystemDictionaries.all)
        books = files.map { file in
            let reading = formats.read(file.name)
            return BookRow(id: file.id, fileName: file.name, reading: reading, metadata: reading.metadata)
        }
        rederive()
    }

    // MARK: - シリーズと巻

    /// 中核でシリーズと巻を導き直す。段階 5 では全冊を計算し直す(架空のデータは小さい。変わった単位だけを計算し直すのは段階 7)。
    func rederive() {
        let results = derivation.derive(books.map {
            SeriesDerivation.Book(id: $0.id, metadata: $0.metadata, confirmation: $0.confirmation)
        })
        for i in books.indices {
            let r = results[books[i].id]
            books[i].seriesID = r?.seriesID
            books[i].metadata.series = r?.series ?? ""
            books[i].metadata.volume = r?.volume?.text ?? ""
            books[i].metadata.volumeSort = r?.volume?.sortKey
        }
        // 書き換えで消えた値の絞り込みは外す(残すと、どの本にも合わない絞り込みで一覧が空になる)。
        if let g = genreFilter, !genreValues.contains(where: { $0.key == g }) { genreFilter = nil }
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
    }

    // MARK: - まとめて書き換える

    /// 選んだ本の欄を、その値で置き換える(並びの欄は値の並び、1 つの値の欄は先頭だけ)。直したら、シリーズを組み直す。
    func set(_ field: BookMetadata.Field, to newValues: [String], for ids: Set<BookRow.ID>) {
        let values = newValues.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        edit("\(field.label)を書き換える") { books in
            for i in books.indices where ids.contains(books[i].id) {
                books[i].metadata.set(field, to: values)
                books[i].edited.insert(field)
            }
        }
    }

    /// 選んだ本の欄を、型で読んだ値(提案)に戻す。
    func revert(_ field: BookMetadata.Field, for ids: Set<BookRow.ID>) {
        edit("\(field.label)を提案に戻す") { books in
            for i in books.indices where ids.contains(books[i].id) {
                books[i].metadata.set(field, to: books[i].reading.metadata.values(field))
                books[i].edited.remove(field)
            }
        }
    }

    // MARK: - シリーズの操作

    /// 選んだ本のタイトルから、シリーズ名の候補(共通部分)。
    func suggestedSeriesName(for ids: Set<BookRow.ID>) -> String? {
        BulkEdit.suggestedSeriesName(forTitles: books.filter { ids.contains($0.id) }.map(\.metadata.title), rules: .builtin)
    }

    /// 選んだ本を 1 つのシリーズにする(巻は今の値を保つ)。確定した名前は錨になり、同じ単位のほかの本もそこへ寄る。
    func setSeries(_ name: String, for ids: Set<BookRow.ID>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("シリーズを「\(trimmed)」にする") { books in
            for i in books.indices where ids.contains(books[i].id) {
                books[i].confirmation = .series(name: trimmed, volume: Self.confirmedVolume(books[i]),
                                                fields: books[i].confirmation.fields)
            }
        }
    }

    /// シリーズから外す(規則が組にしても入れない)。
    func removeFromSeries(_ ids: Set<BookRow.ID>) {
        edit("シリーズから外す") { books in
            for i in books.indices where ids.contains(books[i].id) {
                books[i].confirmation = .notInSeries(fields: books[i].confirmation.fields)
            }
        }
    }

    /// いまの提案(シリーズと巻)をそのまま確定する = 「確かめた」印。シリーズに入っていない本は「シリーズではない」と確定する。
    func acceptProposedSeries(_ ids: Set<BookRow.ID>) {
        edit("シリーズと巻を確かめる") { books in
            for i in books.indices where ids.contains(books[i].id) {
                let fields = books[i].confirmation.fields
                if books[i].seriesID != nil, !books[i].metadata.series.isEmpty {
                    books[i].confirmation = .series(name: books[i].metadata.series,
                                                    volume: books[i].metadata.volume.isEmpty ? nil : books[i].metadata.volume,
                                                    fields: fields)
                } else {
                    books[i].confirmation = .notInSeries(fields: fields)
                }
            }
        }
    }

    /// 選んだ本に、並んだ順で巻を振る(シリーズ名は今の値。無い本は飛ばす)。
    func numberSequentially(_ orderedIDs: [BookRow.ID], start: Int = 1, step: Int = 1, width: Int = 0) {
        edit("巻を振り直す") { books in
            var number = start
            for id in orderedIDs {
                guard let i = books.firstIndex(where: { $0.id == id }) else { continue }
                let name = Self.currentSeriesName(books[i])
                guard !name.isEmpty else { continue }
                let digits = String(abs(number))
                let text = (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
                books[i].confirmation = .series(name: name, volume: text, fields: books[i].confirmation.fields)
                number += step
            }
        }
    }

    /// 巻だけを消す(「巻は無い」と確定する)。
    func clearVolumes(_ ids: Set<BookRow.ID>) {
        edit("巻を空にする") { books in
            for i in books.indices where ids.contains(books[i].id) {
                let name = Self.currentSeriesName(books[i])
                guard !name.isEmpty else { continue }
                books[i].confirmation = .series(name: name, volume: "", fields: books[i].confirmation.fields)
            }
        }
    }

    /// シリーズと巻の確定を取り消して、規則の提案に戻す(欄の直しはそのまま)。
    func revertSeries(_ ids: Set<BookRow.ID>) {
        edit("シリーズを提案に戻す") { books in
            for i in books.indices where ids.contains(books[i].id) {
                books[i].confirmation = books[i].confirmation.fields.values.isEmpty
                    ? .none : .fields(books[i].confirmation.fields)
            }
        }
    }

    /// 今のシリーズ名(確定した名前、無ければ提案)。
    static func currentSeriesName(_ book: BookRow) -> String {
        if case .series(let name, _, _) = book.confirmation { return name }
        return book.metadata.series
    }

    /// 今の巻の表記(確定した巻、無ければ提案。推定した巻は確定させない)。
    static func confirmedVolume(_ book: BookRow) -> String? {
        if case .series(_, let volume?, _) = book.confirmation { return volume }
        return book.metadata.volume.isEmpty ? nil : book.metadata.volume
    }

    // MARK: - 取り消し

    /// 取り消せる操作(名前と、その前の一覧)。操作の単位は 1 回のまとめて編集。
    private struct Step { let name: String; let books: [BookRow] }
    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// 取り消しで戻れる回数の上限(作業ファイルは段階 8。それまでは窓が閉じるまで)。
    private static let undoLimit = 50

    var undoName: String? { undoSteps.last?.name }
    var redoName: String? { redoSteps.last?.name }

    /// 一覧を書き換える操作を、取り消せる 1 歩として行う。
    private func edit(_ name: String, _ change: (inout [BookRow]) -> Void) {
        let before = books
        var updated = books
        change(&updated)
        guard updated != books else { return }
        books = updated
        undoSteps.append(Step(name: name, books: before))
        if undoSteps.count > Self.undoLimit { undoSteps.removeFirst() }
        redoSteps.removeAll()
        rederive()
    }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        redoSteps.append(Step(name: step.name, books: books))
        books = step.books
        rederive()
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(Step(name: step.name, books: books))
        books = step.books
        rederive()
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
}
