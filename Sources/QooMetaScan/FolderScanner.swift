import Foundation
import QooMetaKit

/// フォルダの下の書庫ファイルを集める。読むのは名前と属性だけで、書庫の中身は開かない。
///
/// 本体(QooMetaKit)はファイルを読まないので、走査はこのモジュールで行う。
public enum FolderScanner {
    public static let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7"]

    public static func scan(root: URL) throws -> [ScannedFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .volumeUUIDStringKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootPath = root.standardizedFileURL.path
        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard archiveExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            var relative = path
            if path.hasPrefix(rootPath + "/") { relative = String(path.dropFirst(rootPath.count + 1)) }
            var st = stat()
            let hasStat = stat(path, &st) == 0
            result.append(ScannedFile(
                path: path,
                relativePath: relative,
                baseName: url.deletingPathExtension().lastPathComponent,
                fileExtension: ext,
                size: values?.fileSize.map(Int64.init),
                created: values?.creationDate,
                modified: values?.contentModificationDate,
                // ネットワークボリュームでは iノード番号が Int64 の範囲を超える(実測)。qooViewer は
                // `NSNumber.int64Value` でビット列のまま読み替えているので、同じ値になるよう bitPattern で読む。
                inodeNumber: hasStat ? Int64(bitPattern: UInt64(st.st_ino)) : nil,
                volumeDeviceNumber: hasStat ? Int64(st.st_dev) : nil,
                volumeUUID: values?.volumeUUIDString
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }
}

/// 走査で見つけた本 1 冊分のファイル情報。
public struct ScannedFile: Codable, Sendable, Equatable {
    public var path: String
    /// 走査の起点からの相対パス(本の ID に使う。フォルダの手がかりにもなる)。
    public var relativePath: String
    public var baseName: String
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

    /// 入っているフォルダ(近い順。起点の直下なら空)。
    public var folders: [String] {
        Array(relativePath.split(separator: "/").dropLast().reversed().map(String.init))
    }

    /// 提案の入力(ID は相対パス)。
    public func bookInput(confirmation: Confirmation = .none) -> BookInput {
        BookInput(id: relativePath, name: baseName, confirmation: confirmation)
    }
}
