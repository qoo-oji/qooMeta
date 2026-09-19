import Foundation

/// フォルダの下の書庫ファイルを集める。読むのは名前と属性だけで、書庫の中身は開かない。
public enum BookScanner {
    public static let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7"]

    public static func scan(root: URL) throws -> [BookFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .volumeUUIDStringKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootPath = root.standardizedFileURL.path
        var result: [BookFile] = []
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
            result.append(BookFile(
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

    /// 走査結果に名前の解析をかけて、提案の下地を作る。
    ///
    /// - Parameter qooLibrary: 渡すと qooLibrary のフォーマット処理で先に読み、一致しなければ NameParser へ戻す。
    public static func proposals(from files: [BookFile], qooLibrary: QooLibraryNameParser? = nil) -> [BookProposal] {
        files.enumerated().map { index, file in
            var parsed = qooLibrary?.parse(baseName: file.baseName) ?? NameParser.parse(baseName: file.baseName)
            let split = EditionMarkers.split(parsed.title)
            if split.base != parsed.title {
                parsed.workTitle = split.base
                parsed.editions = split.editions.isEmpty ? nil : split.editions
                parsed.sources = split.sources.isEmpty ? nil : split.sources
            }
            if let reordered = Compilation.normalizedTitle(parsed.baseTitle) { parsed.workTitle = reordered }
            let owner = parsed.circle.isEmpty ? file.folderName : parsed.circle
            let key = String(ComparableText(owner).key)
            return BookProposal(id: index + 1, file: file, parsed: parsed, circleKey: key)
        }
    }
}
