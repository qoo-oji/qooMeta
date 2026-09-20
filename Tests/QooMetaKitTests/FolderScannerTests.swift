import Foundation
import QooMetaExport
import QooMetaKit
import QooMetaScan
import Testing

/// 走査が何を 1 冊と数えるか(qooViewer が本として開けるものと同じ)。名前は合成したものだけ。
@Suite struct FolderScannerTests {
    /// 一時フォルダに、空のファイルで木を作る。
    static func tree(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qoometa-scan-\(UUID().uuidString)")
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return root
    }

    @Test func findsEveryKindOfBook() throws {
        let root = try Self.tree([
            "棚/[架空工房] 月の庭 1.zip", "棚/[架空工房] 月の庭 2.EPUB", "棚/[架空工房] 月の庭 3.pdf", "棚/[架空工房] 月の庭 4.cb7",
            "棚/メモ.txt", "棚/.隠し.zip",
            // 規則 1: 直下に画像があるフォルダは 1 冊。中のフォルダや書庫は、その本の中身。
            "棚/[架空工房] 星の海 第1.5巻/001.jpg", "棚/[架空工房] 星の海 第1.5巻/おまけ/002.png", "棚/[架空工房] 星の海 第1.5巻/付録.zip",
            // 規則 2: 本のファイルが無く、画像のフォルダが並ぶフォルダも 1 冊。
            "棚/[架空工房] 夜の森/第1章/001.webp", "棚/[架空工房] 夜の森/第2章/001.webp",
            // 規則 3: 本のファイルが直下にあれば棚。画像のフォルダは 1 冊ずつ。
            "棚/作者別/[架空作家] 風の丘 1.cbz", "棚/作者別/[架空作家] 風の丘 2/001.avif",
            // 画像も本も無いフォルダは拾わない。
            "棚/空/読んでね.txt",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FolderScanner.scan(root: root)
        #expect(files.map(\.relativePath) == [
            "棚/[架空工房] 夜の森", "棚/[架空工房] 星の海 第1.5巻",
            "棚/[架空工房] 月の庭 1.zip", "棚/[架空工房] 月の庭 2.EPUB", "棚/[架空工房] 月の庭 3.pdf", "棚/[架空工房] 月の庭 4.cb7",
            "棚/作者別/[架空作家] 風の丘 1.cbz", "棚/作者別/[架空作家] 風の丘 2",
        ])
        // フォルダの本の名前は、フォルダの名前の全体(「.5巻」を拡張子として落とさない)。拡張子は空。
        let folder = try #require(files.first { $0.relativePath == "棚/[架空工房] 星の海 第1.5巻" })
        #expect(folder.baseName == "[架空工房] 星の海 第1.5巻")
        #expect(folder.isFolder && folder.fileExtension.isEmpty)
        let epub = try #require(files.first { $0.relativePath.hasSuffix(".EPUB") })
        #expect(epub.baseName == "[架空工房] 月の庭 2" && epub.fileExtension == "epub" && !epub.isFolder)
    }

    /// 起点そのものは本にしない: 起点の直下に画像のフォルダだけが並んでいても、1 つずつの本になる。
    @Test func theRootIsNeverABook() throws {
        let root = try Self.tree(["[架空工房] 月の庭 1/001.jpg", "[架空工房] 月の庭 2/001.jpg", "表紙.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FolderScanner.scan(root: root).map(\.relativePath) == ["[架空工房] 月の庭 1", "[架空工房] 月の庭 2"])
    }

    /// フォルダの本であることは作業ファイルに残り、書き出しのファイルの種類(StackNest は 4)に渡る。
    @Test func folderBooksSurviveTheWorkfile() throws {
        let book = Workfile.Book(id: "棚/[架空工房] 星の海 第1.5巻", name: "[架空工房] 星の海 第1.5巻", isFolder: true)
        let data = try JSONEncoder().encode(Workfile(rootPath: "/nowhere", books: [book, .init(id: "a.CBZ", name: "a")]))
        let back = try JSONDecoder().decode(Workfile.self, from: data)
        #expect(back.books.map(\.isFolder) == [true, false])
        #expect(back.books.map(\.fileExtension) == ["", "cbz"])
        #expect(Exporter.FileFacts(path: "/nowhere/x", fileExtension: "").isFolder)
    }
}
