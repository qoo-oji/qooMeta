import Foundation

/// Stackroom 2.1b のライブラリ XML(Apple Property List)を書く。StackNest はこれを取り込んで
/// **新しいライブラリを作る**(既存のライブラリへは足せない。docs/design.md「StackNest への渡し方」)。
///
/// 形は StackNest の `StackroomFormat`(BookRecord / LibraryDocument)が読む範囲に合わせる。
/// 必須: ID, Title, Cover Image Path, Date Added, Book Type, File Type。
public enum StackroomExporter {
    public struct Options: Sendable {
        /// Book Type。0 = 厚い本、1 = 薄い本(StackNest の BookTypeClassifier の値)。
        /// ページ数を数えないので本ごとには決めない。
        public var bookType: Int = 0

        public init(bookType: Int = 0) { self.bookType = bookType }
    }

    /// File Type(StackNest の BookImporter.FileTypeCode と同じ値)。
    static func fileType(forExtension ext: String) -> Int {
        switch ext.lowercased() {
        case "rar", "cbr": 3
        case "7z", "cb7": 5
        default: 2
        }
    }

    public static func makeDocument(_ document: ProposalDocument, options: Options = Options()) -> [String: Any] {
        var books: [String: Any] = [:]
        for book in document.books {
            var entry: [String: Any] = [
                "ID": book.id,
                "Title": book.parsed.title,
                "Path": book.file.path,
                // 表紙の画像は用意しない。本そのものを指しておけば、StackNest は本のパスとして扱える
                // (StackroomPathRecovery)。表紙は StackNest の「表紙の再生成」で作る。
                "Cover Image Path": book.file.path,
                "Date Added": book.file.created ?? book.file.modified ?? document.createdAt,
                "Book Type": options.bookType,
                "File Type": fileType(forExtension: book.file.fileExtension),
                "My Rate": 0,
                "Unseen": true,
            ]
            let authors = authorValues(book.parsed)
            if !authors.isEmpty { entry["Author"] = authors.joined(separator: ", ") }
            if !book.parsed.leading.isEmpty { entry["Genre"] = book.parsed.leading }
            if !book.parsed.trailing.isEmpty { entry["Neta"] = book.parsed.trailing }
            // 版(フルカラー版・完全版 …)は Keyword C へ(利用者との取り決め)。入手経路(DL版など)は書かない。
            if let editions = book.parsed.editions, !editions.isEmpty { entry["Keyword C"] = editions.joined(separator: ", ") }
            if !book.series.isEmpty { entry["Series"] = book.series }
            if let volume = book.volumeNumber { entry["Volume"] = volume }
            books[String(book.id)] = entry
        }
        return ["Books": books, "Playlists": [Any]()]
    }

    /// Author に入れる値。サークル名と作者名を別々の値として並べる(StackNest は Author を
    /// カンマ区切りの複数値として扱い、値ごとに絞り込める)。
    static func authorValues(_ parsed: ParsedName) -> [String] {
        var values: [String] = []
        for name in [parsed.circle] + parsed.authors where !name.isEmpty && !values.contains(name) {
            values.append(name.replacingOccurrences(of: ",", with: " "))
        }
        return values
    }

    public static func write(_ document: ProposalDocument, to url: URL, options: Options = Options()) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: makeDocument(document, options: options), format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

/// qooViewer の保存データ JSON(formatVersion 4 の `metadata` だけ)を書く。
/// qooViewer の「保存データの読み込み」で取り込める。照合はファイルノード(iノード番号+ボリューム)が主で、
/// パス(bookID)は最終手段(qooViewer の LibraryJSONSchema.swift)。
public enum QooViewerExporter {
    struct File: Encodable {
        var formatVersion = 4
        var metadata: [Entry]
    }

    struct Entry: Encodable {
        var bookID: String
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?
        var author: String
        var title: String
        var series: String
        var seriesIndex: String
    }

    public static func makeData(_ document: ProposalDocument) throws -> Data {
        let entries = document.books.map { book in
            Entry(
                bookID: book.file.path,
                inodeNumber: book.file.inodeNumber,
                volumeDeviceNumber: book.file.volumeDeviceNumber,
                volumeUUID: book.file.volumeUUID,
                // qooViewer の著者欄は 1 つなので、サークル名を入れる(それまでの手入力の登録と同じ使い方)。
                author: book.parsed.circle,
                title: book.parsed.title,
                series: book.series,
                seriesIndex: book.volumeText
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(metadata: entries))
    }

    public static func write(_ document: ProposalDocument, to url: URL) throws {
        try makeData(document).write(to: url, options: .atomic)
    }
}
