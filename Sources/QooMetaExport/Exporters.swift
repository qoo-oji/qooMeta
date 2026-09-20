import Foundation
import QooMetaKit

/// 提案を、ほかのアプリが取り込める形にする。**`Data` を返すだけで、ファイルには書かない**(置き場所は利用側が決める)。
///
/// 第三者のアプリの欄に合わせる対応表(ShelfRow のどの欄へ入れるか、など)はここに入れない(相手の変更で壊れるため。
/// docs/api.md「書き出し」)。ここにあるのは、形式が公開されていて qooMeta が直接書き出す相手だけ。
public enum Exporter {
    /// 本のファイルの事実(走査で分かること)。本体はファイルを見ないので、利用側が渡す。
    public struct FileFacts: Sendable, Hashable {
        public var path: String
        /// 小文字の拡張子。フォルダの本(画像フォルダ)は空。
        public var fileExtension: String
        /// 取り込んだ日(作成日など)。無ければ Options.defaultDateAdded。
        public var dateAdded: Date?

        public init(path: String, fileExtension: String, dateAdded: Date? = nil) {
            self.path = path
            self.fileExtension = fileExtension
            self.dateAdded = dateAdded
        }

        public var isFolder: Bool { fileExtension.isEmpty }
    }

    /// qooViewer がファイルを同定する手段(パスが変わっても追える)。
    public struct FileIdentity: Sendable, Hashable {
        public var path: String
        public var inodeNumber: Int64?
        public var volumeDeviceNumber: Int64?
        public var volumeUUID: String?

        public init(path: String, inodeNumber: Int64? = nil, volumeDeviceNumber: Int64? = nil, volumeUUID: String? = nil) {
            self.path = path
            self.inodeNumber = inodeNumber
            self.volumeDeviceNumber = volumeDeviceNumber
            self.volumeUUID = volumeUUID
        }
    }

    public struct StackroomOptions: Sendable {
        /// Book Type。0 = 厚い本、1 = 薄い本(StackNest の BookTypeClassifier の値)。ページ数を数えないので本ごとには決めない。
        public var bookType: Int = 0
        public var defaultDateAdded = Date(timeIntervalSince1970: 0)

        public init(bookType: Int = 0, defaultDateAdded: Date = Date(timeIntervalSince1970: 0)) {
            self.bookType = bookType
            self.defaultDateAdded = defaultDateAdded
        }
    }

    // MARK: - Stackroom

    /// Stackroom 2.1b のライブラリ XML(Apple Property List)。StackNest はこれを取り込んで**新しいライブラリを作る**
    /// (既存のライブラリへは足せない。docs/design.md「StackNest への渡し方」)。
    ///
    /// 形は StackNest の `StackroomFormat`(BookRecord / LibraryDocument)が読む範囲に合わせる。
    /// 必須: ID, Title, Cover Image Path, Date Added, Book Type, File Type。`files` に無い本は書かない。
    public static func stackroomXML(_ set: ProposalSet, files: [String: FileFacts],
                                    mapping: FieldMapping = .standard(for: .stackNest),
                                    options: StackroomOptions = StackroomOptions()) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: stackroomDocument(set, files: files, mapping: mapping, options: options),
            format: .xml, options: 0)
    }

    static func stackroomDocument(_ set: ProposalSet, files: [String: FileFacts], mapping: FieldMapping,
                                  options: StackroomOptions) -> [String: Any] {
        var books: [String: Any] = [:]
        var number = 0
        let keysBySlot = mapping.keysBySlot
        for book in set.proposals {
            guard let file = files[book.id] else { continue }
            number += 1
            var entry: [String: Any] = [
                "ID": number,
                // Title は StackNest・ShelfRow が必須で読むので、対応表から外されていても空で入れる。
                "Title": "",
                "Path": file.path,
                // 表紙の画像は用意しない。本そのものを指しておけば、StackNest は本のパスとして扱える
                // (StackroomPathRecovery)。表紙は StackNest の「表紙の再生成」で作る。
                "Cover Image Path": file.path,
                "Date Added": file.dateAdded ?? options.defaultDateAdded,
                "Book Type": options.bookType,
                "File Type": fileType(forExtension: file.fileExtension),
                "My Rate": 0,
                "Unseen": true,
            ]
            // どの欄をどこへ渡すかは対応表が決める(書いていない欄は落ちる)。
            for (slot, key) in keysBySlot {
                guard let xmlKey = slot.stackroomKey else { continue }
                let values = key.values(book.metadata)
                guard let first = values.first, !first.isEmpty else { continue }
                if slot == .volume {
                    // Volume は数の欄。数に読めない表記は渡さない(落ちる欄としてプレビューに出る)。
                    if let number = Double(first) { entry[xmlKey] = number }
                } else if key == .authors {
                    entry[xmlKey] = mapping.target.takesAllAuthors
                        ? authorValues(book.metadata).joined(separator: ", ") : first
                } else {
                    entry[xmlKey] = first
                }
            }
            books[String(number)] = entry
        }
        return ["Books": books, "Playlists": [Any]()]
    }

    /// File Type(StackNest の BookImporter.FileTypeCode と同じ値)。
    static func fileType(forExtension ext: String) -> Int {
        switch ext.lowercased() {
        // 拡張子が空なのはフォルダの本(StackNest の取り込みは、画像フォルダを 4 で持つ)。
        case "": 4
        case "rar", "cbr": 3
        case "7z", "cb7": 5
        default: 2
        }
    }

    /// Author に入れる値。著者の並びをそのまま並べる(StackNest は Author を
    /// カンマ区切りの複数値として扱い、値ごとに絞り込める)。
    static func authorValues(_ metadata: BookMetadata) -> [String] {
        var values: [String] = []
        for name in metadata.authors where !name.isEmpty && !values.contains(name) {
            values.append(name.replacingOccurrences(of: ",", with: " "))
        }
        return values
    }

    // MARK: - qooViewer

    struct QooViewerFile: Encodable {
        var formatVersion = 4
        var metadata: [QooViewerEntry]
    }

    struct QooViewerEntry: Encodable {
        var bookID: String
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?
        var author: String
        var title: String
        var series: String
        var seriesIndex: String
    }

    /// qooViewer の保存データ JSON(formatVersion 4 の `metadata` だけ)。qooViewer の「保存データの読み込み」で取り込める。
    /// 照合はファイルノード(iノード番号 + ボリューム)が主で、パス(bookID)は最終手段(qooViewer の LibraryJSONSchema.swift)。
    public static func qooViewerJSON(_ set: ProposalSet, identities: [String: FileIdentity],
                                     mapping: FieldMapping = .standard(for: .qooViewer)) throws -> Data {
        let keysBySlot = mapping.keysBySlot
        let entries = set.proposals.compactMap { book -> QooViewerEntry? in
            guard let file = identities[book.id] else { return nil }
            // qooViewer の著者欄は 1 つなので、どの欄を渡しても先頭だけを入れる。
            func value(_ slot: ExportSlot) -> String { keysBySlot[slot]?.values(book.metadata).first ?? "" }
            return QooViewerEntry(
                bookID: file.path, inodeNumber: file.inodeNumber, volumeDeviceNumber: file.volumeDeviceNumber,
                volumeUUID: file.volumeUUID,
                author: value(.author), title: value(.title), series: value(.series), seriesIndex: value(.seriesIndex))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(QooViewerFile(metadata: entries))
    }

    // MARK: - ComicInfo

    /// ComicInfo.xml(書庫の中に置く、コミックのメタデータの広く使われる形)。1 冊ぶん。
    /// 著者は Writer、原作は Tags、ジャンルは Genre、情報は Notes に入れる。
    public static func comicInfoXML(_ proposal: BookProposal, series: SeriesProposal?) -> Data {
        let m = proposal.metadata
        var fields: [(String, String)] = [("Title", m.title)]
        if let series { fields.append(("Series", series.name)) }
        if !m.volume.isEmpty { fields.append(("Number", m.volume)) }
        if !m.authors.isEmpty { fields.append(("Writer", m.authors.joined(separator: ", "))) }
        if !m.genre.isEmpty { fields.append(("Genre", m.genre)) }
        if !m.source.isEmpty { fields.append(("Tags", m.source)) }
        if !m.info.isEmpty { fields.append(("Notes", m.info)) }
        let body = fields.map { "  <\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        \(body)
        </ComicInfo>

        """.utf8)
    }

    /// XML の文字のエスケープ。XML 1.0 で書けない制御文字は落とす(名前に紛れ込んでいても壊れた XML にしない)。
    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && !(0xFFFE...0xFFFF).contains(scalar.value) { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
