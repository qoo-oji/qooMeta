import Foundation
import QooMetaKit

/// フォルダの下の本を集める。読むのは名前と属性だけで、書庫の中身は開かない。
///
/// 本体(QooMetaKit)はファイルを読まないので、走査はこのモジュールで行う。
///
/// **何を 1 冊と数えるかは、ターゲットの qooViewer と同じにする**(2026-09-20、利用者の指示。qooViewer が本として開けるものを
/// すべて拾う。調べたのは qooViewer `4b912b1` の ArchiveReading・ShelfFolderResolver)。要件として合わせるのは「本の定義」で、
/// コードは qooMeta で書く。
///
/// - ファイルの本: 書庫(zip・cbz・rar・cbr・7z・cb7)、PDF、EPUB。
/// - フォルダの本(画像フォルダ):
///   1. 直下に画像があるフォルダは、それ自体が 1 冊(下のフォルダの画像もその本のページなので、中へは降りない)。
///   2. 直下に本のファイルが無く、画像を直に持つフォルダが並んでいるフォルダも 1 冊(章ごとに画像を分けた本)。
///   3. どちらでもないフォルダは棚。直下の本のファイルを拾い、下のフォルダを同じ規則で見る。
/// - **走査の起点そのものは本にしない**(利用者は「本が入っている場所」として起点を選ぶ)。起点の直下に画像フォルダの本だけが
///   並んでいても、規則 2 で起点ごと 1 冊にはならず、1 つずつの本になる。
public enum FolderScanner {
    public static let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7"]
    /// 1 冊の本になるファイルの拡張子(書庫・PDF・EPUB)。
    public static let bookFileExtensions: Set<String> = archiveExtensions.union(["pdf", "epub"])
    /// ページになる画像の拡張子(画像フォルダの本を見分けるのに使う)。
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "avif"]

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .volumeUUIDStringKey,
    ]

    public static func scan(root: URL) throws -> [ScannedFile] {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var result: [ScannedFile] = []
        visit(root, rootPath: root.path, isRoot: true, into: &result)
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// 直下の項目(隠しファイルは見ない。パッケージの中へは降りない。シンボリックリンクは辿らないので、循環しない)。
    static func children(of folder: URL) -> (files: [URL], folders: [URL]) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        var files: [URL] = [], folders: [URL] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true { folders.append(item) } else if values?.isRegularFile == true { files.append(item) }
        }
        return (files, folders)
    }

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    static func visit(_ folder: URL, rootPath: String, isRoot: Bool, into result: inout [ScannedFile]) {
        let (files, folders) = children(of: folder)
        let bookFiles = files.filter { bookFileExtensions.contains($0.pathExtension.lowercased()) }
        if !isRoot {
            // 規則 1・2: このフォルダ自体が 1 冊。
            let isBook = files.contains(where: isImage)
                || (bookFiles.isEmpty && folders.contains { children(of: $0).files.contains(where: isImage) })
            if isBook {
                result.append(scanned(folder, rootPath: rootPath, isFolder: true))
                return
            }
        }
        for file in bookFiles { result.append(scanned(file, rootPath: rootPath, isFolder: false)) }
        for child in folders { visit(child, rootPath: rootPath, isRoot: false, into: &result) }
    }

    static func scanned(_ url: URL, rootPath: String, isFolder: Bool) -> ScannedFile {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let path = url.standardizedFileURL.path
        var relative = path
        if path.hasPrefix(rootPath + "/") { relative = String(path.dropFirst(rootPath.count + 1)) }
        var st = stat()
        let hasStat = stat(path, &st) == 0
        return ScannedFile(
            path: path,
            relativePath: relative,
            // フォルダの名前は丸ごとが本の名前(「第1.5巻」の「.5巻」を拡張子として落とさない)。
            baseName: isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
            fileExtension: isFolder ? "" : url.pathExtension.lowercased(),
            size: isFolder ? nil : values?.fileSize.map(Int64.init),
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            // ネットワークボリュームでは iノード番号が Int64 の範囲を超える(実測)。qooViewer は
            // `NSNumber.int64Value` でビット列のまま読み替えているので、同じ値になるよう bitPattern で読む。
            inodeNumber: hasStat ? Int64(bitPattern: UInt64(st.st_ino)) : nil,
            volumeDeviceNumber: hasStat ? Int64(st.st_dev) : nil,
            volumeUUID: values?.volumeUUIDString
        )
    }
}

/// 走査で見つけた本 1 冊分のファイル情報。
public struct ScannedFile: Codable, Sendable, Equatable {
    public var path: String
    /// 走査の起点からの相対パス(本の ID に使う。フォルダの手がかりにもなる)。
    public var relativePath: String
    /// 本の名前(ファイルは拡張子を除いたもの。フォルダの本は名前の全体)。
    public var baseName: String
    /// 小文字の拡張子。**フォルダの本(画像フォルダ)は空**(拡張子の無いファイルは本として拾わないので、空ならフォルダ)。
    public var fileExtension: String
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    /// qooViewer がファイルを同定する手段(パスが変わっても追える)。qooViewer の JSON へそのまま書く。
    public var inodeNumber: Int64?
    public var volumeDeviceNumber: Int64?
    public var volumeUUID: String?

    public init(path: String, relativePath: String, baseName: String, fileExtension: String,
                size: Int64? = nil, created: Date? = nil, modified: Date? = nil,
                inodeNumber: Int64? = nil, volumeDeviceNumber: Int64? = nil, volumeUUID: String? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.size = size
        self.created = created
        self.modified = modified
        self.inodeNumber = inodeNumber
        self.volumeDeviceNumber = volumeDeviceNumber
        self.volumeUUID = volumeUUID
    }

    /// フォルダの本(画像フォルダ)か。
    public var isFolder: Bool { fileExtension.isEmpty }

    /// 入っているフォルダ(近い順。起点の直下なら空)。
    public var folders: [String] {
        Array(relativePath.split(separator: "/").dropLast().reversed().map(String.init))
    }

    /// 提案の入力(ID は相対パス)。
    public func bookInput(confirmation: Confirmation = .none) -> BookInput {
        BookInput(id: relativePath, name: baseName, confirmation: confirmation)
    }
}
