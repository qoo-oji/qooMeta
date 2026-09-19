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
    var seriesID: SeriesID?

    /// 一覧のセルに出す文字(並びの欄は「、」でつなぐ)。
    subscript(text field: BookMetadata.Field) -> String {
        metadata.values(field).joined(separator: "、")
    }

    /// 並べ替えの鍵。シリーズは シリーズ → 巻(シリーズの無い本は後ろ)、巻は数の順(数に読めない表記は後ろ)。
    subscript(sortKey field: BookMetadata.Field) -> String {
        switch field {
        case .series:
            guard !metadata.series.isEmpty else { return "\u{10FFFF}" + metadata.title }
            return metadata.series + "\u{1}" + self[sortKey: .volume]
        case .volume:
            if let n = metadata.volumeNumber { return String(format: "%012.3f", n) }
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
        case all, notInSeries, noVolume, unmatched, edited
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "すべて"
            case .notInSeries: "シリーズに入っていない"
            case .noVolume: "巻が空"
            case .unmatched: "型に合わなかった"
            case .edited: "直した本"
            }
        }
        func contains(_ book: BookRow) -> Bool {
            switch self {
            case .all: true
            case .notInSeries: book.seriesID == nil
            case .noVolume: book.metadata.volume.isEmpty
            case .unmatched: book.reading.formatIndex == nil
            case .edited: !book.edited.isEmpty
            }
        }
    }

    init(files: [(id: String, name: String)], formats: FilenameFormats = .preset) {
        self.formats = formats
        derivation = SeriesDerivation(rules: .builtin, vocabulary: Vocabulary(dictionaries: SystemDictionaries.all))
        books = files.map { file in
            let reading = formats.read(file.name)
            return BookRow(id: file.id, fileName: file.name, reading: reading, metadata: reading.metadata)
        }
        rederive()
    }

    // MARK: - シリーズと巻

    /// 中核でシリーズと巻を導き直す。段階 5 では全冊を計算し直す(架空のデータは小さい。変わった単位だけを計算し直すのは段階 7)。
    func rederive() {
        let results = derivation.derive(books.map { SeriesDerivation.Book(id: $0.id, metadata: $0.metadata) })
        for i in books.indices {
            let r = results[books[i].id]
            books[i].seriesID = r?.seriesID
            books[i].metadata.series = r?.series ?? ""
            books[i].metadata.volume = r?.volume?.text ?? ""
            books[i].metadata.volumeNumber = r?.volume?.sortKey
        }
        // 書き換えで消えた値の絞り込みは外す(残すと、どの本にも合わない絞り込みで一覧が空になる)。
        if let g = genreFilter, !genreValues.contains(where: { $0.key == g }) { genreFilter = nil }
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
    }

    // MARK: - まとめて書き換える

    /// 選んだ本の欄を、その値で置き換える(並びの欄は値の並び、1 つの値の欄は先頭だけ)。直したら、シリーズを組み直す。
    func set(_ field: BookMetadata.Field, to newValues: [String], for ids: Set<BookRow.ID>) {
        let values = newValues.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for i in books.indices where ids.contains(books[i].id) {
            books[i].metadata.set(field, to: values)
            books[i].edited.insert(field)
        }
        rederive()
    }

    /// 選んだ本の欄を、型で読んだ値(提案)に戻す。
    func revert(_ field: BookMetadata.Field, for ids: Set<BookRow.ID>) {
        for i in books.indices where ids.contains(books[i].id) {
            books[i].metadata.set(field, to: books[i].reading.metadata.values(field))
            books[i].edited.remove(field)
        }
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
