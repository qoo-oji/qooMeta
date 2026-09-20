import Foundation
import QooMetaAI
import QooMetaExport
import QooMetaKit
import QooMetaScan

/// CLI の提案ファイル。走査の結果(入力)と端末内モデルの判定だけを持ち、提案はそのつど計算し直す
/// (規則を変えても走査をやり直さずに済み、古い提案が残ることもない)。
///
/// **中身は蔵書の名前そのもの**なので、リポジトリの外に置く(CLI は Git の作業ツリーの中へは書かない)。
struct ScanDocument: Codable {
    var formatVersion = 2
    var createdAt: Date
    var rootPath: String
    var files: [ScannedFile]
    /// 端末内モデルの判定(規則のシリーズの本の ID の並び → 判定)。
    var judgements: [Judgement] = []

    struct Judgement: Codable {
        /// 判定した組(規則のシリーズの本の ID。並べ替えたもの)。
        var memberIDs: [String]
        var ruleName: String
        var verdict: AIVerdict?
        /// 判定できなかった理由(安全装置による拒否など。名前は含まない)。
        var error: String?
    }

    static func load(_ path: String) throws -> ScanDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["formatVersion"] as? Int,
           version != 2 {
            throw CLIError("提案ファイルの形式が古い(formatVersion \(version))。scan をやり直してください")
        }
        return try decoder.decode(ScanDocument.self, from: data)
    }

    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// フォルダごとに使う型の並び(プリセット)。走査の起点からの相対パスの頭が合うものを使う。
    /// **蔵書のフォルダ名を含む**ので、リポジトリの外のファイルから読む(`--presets`)。
    struct PresetMap: Sendable {
        /// 相対パスの頭 → プリセットの名前(長い頭から先に見る)。
        var byPrefix: [(prefix: String, preset: String)] = []
        var fallback: String?

        static func load(_ path: String) throws -> PresetMap {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError("プリセットの割り当てファイルはオブジェクトで書きます")
            }
            var map = PresetMap()
            map.fallback = o["default"] as? String
            for (prefix, preset) in (o["folders"] as? [String: String] ?? [:]) {
                map.byPrefix.append((prefix, preset))
            }
            map.byPrefix.sort { $0.prefix.count > $1.prefix.count }
            return map
        }

        func preset(for relativePath: String) -> String? {
            byPrefix.first { relativePath == $0.prefix || relativePath.hasPrefix($0.prefix + "/") }?.preset ?? fallback
        }
    }

    /// 本の入力。`useAI` なら、端末内モデルの判定を確定した内容として渡す(確定した名前は錨になる)。
    func inputs(useAI: Bool, rulesOnly: ProposalSet? = nil, presets: PresetMap? = nil) -> [BookInput] {
        var confirmations: [String: Confirmation] = [:]
        if useAI, let rulesOnly {
            let seriesByMembers = Dictionary(rulesOnly.series.map { ($0.memberIDs.sorted(), $0) },
                                             uniquingKeysWith: { a, _ in a })
            for j in judgements {
                guard let verdict = j.verdict, let series = seriesByMembers[j.memberIDs] else { continue }
                confirmations.merge(verdict.confirmations(for: series)) { a, _ in a }
            }
        }
        return files.map { file in
            var input = file.bookInput(confirmation: confirmations[file.relativePath] ?? .none)
            input.preset = presets?.preset(for: file.relativePath)
            return input
        }
    }
}

/// CLI が読める入力: `scan` が作る提案ファイルか、アプリの作業ファイル。どちらも中身は蔵書の名前なので、リポジトリの外に置く。
///
/// 作業ファイルを読めるようにしてあるのは、アプリで直した内容のまま**一括で書き出し・集計をやり直せる**ように
/// (docs/roadmap.md の段階 10)。作業ファイルはファイルの事実(日付・iノード)を持たないので、パスは起点と相対パスから組み立てる。
enum InputDocument {
    case scan(ScanDocument)
    case work(Workfile)

    static func load(_ path: String) throws -> InputDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let kind = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["kind"] as? String
        if kind == Workfile.kind { return .work(try Workfile.decoded(data)) }
        return .scan(try ScanDocument.load(path))
    }

    var rootPath: String {
        switch self {
        case .scan(let d): d.rootPath
        case .work(let w): w.rootPath
        }
    }

    var createdAt: Date {
        switch self {
        case .scan(let d): d.createdAt
        case .work(let w): w.savedAt ?? Date(timeIntervalSince1970: 0)
        }
    }

    /// 端末内モデルの判定(作業ファイルは持たない)。
    var judgements: [ScanDocument.Judgement] {
        switch self {
        case .scan(let d): d.judgements
        case .work: []
        }
    }

    var bookCount: Int {
        switch self {
        case .scan(let d): d.files.count
        case .work(let w): w.books.count
        }
    }

    /// 読み取りの入力。作業ファイルは、自分の持つ割り当て(`--presets` があればそちら)と、利用者の修正を渡す。
    func inputs(useAI: Bool, rulesOnly: ProposalSet? = nil, presets: ScanDocument.PresetMap? = nil) -> [BookInput] {
        switch self {
        case .scan(let d): d.inputs(useAI: useAI, rulesOnly: rulesOnly, presets: presets)
        case .work(let w):
            w.inputs.map { input in
                guard let presets else { return input }
                var copy = input
                copy.preset = presets.preset(for: input.id)
                return copy
            }
        }
    }

    /// 名前とプリセット(型の一致を数える `formats` 用)。
    var namesAndPresets: [(name: String, preset: String?)] {
        switch self {
        case .scan(let d): d.files.map { (name: $0.baseName, preset: nil) }
        case .work(let w): w.inputs.map { (name: $0.name, preset: $0.preset) }
        }
    }

    /// 書き出しに要るファイルの事実。作業ファイルには日付が無いので、起点からのパスと拡張子だけを組み立てる。
    var fileFacts: [String: Exporter.FileFacts] {
        switch self {
        case .scan(let d):
            Dictionary(d.files.map { f in
                (f.relativePath, Exporter.FileFacts(path: f.path, fileExtension: f.fileExtension,
                                                    dateAdded: f.created ?? f.modified))
            }, uniquingKeysWith: { a, _ in a })
        case .work(let w):
            Dictionary(w.books.map { book in
                (book.id, Exporter.FileFacts(path: (w.rootPath as NSString).appendingPathComponent(book.id),
                                             fileExtension: book.fileExtension))
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// qooViewer がファイルを同定する手段。作業ファイルにはファイルノードが無いので、パスだけ。
    var identities: [String: Exporter.FileIdentity] {
        switch self {
        case .scan(let d):
            Dictionary(d.files.map { f in
                (f.relativePath, Exporter.FileIdentity(path: f.path, inodeNumber: f.inodeNumber,
                                                       volumeDeviceNumber: f.volumeDeviceNumber, volumeUUID: f.volumeUUID))
            }, uniquingKeysWith: { a, _ in a })
        case .work(let w):
            Dictionary(w.books.map { book in
                (book.id, Exporter.FileIdentity(path: (w.rootPath as NSString).appendingPathComponent(book.id)))
            }, uniquingKeysWith: { a, _ in a })
        }
    }
}

/// 提案を計算する道具一式(規則・語彙)。
struct Proposer {
    let rules: CompiledRules
    let dictionaries: [String: WordSet]
    /// フォルダごとのプリセットの割り当て(`--presets`)。無ければ既定のプリセットで読む。
    var presets: ScanDocument.PresetMap?
    /// 説明(組になりかけた相手など)も作るか(見直し表のため)。
    var explanations = false

    /// 規則だけの提案と、端末内モデルの判定を反映した提案(提案ファイルでも作業ファイルでも同じ)。
    func proposals(_ doc: InputDocument, useAI: Bool) -> (rulesOnly: ProposalSet, final: ProposalSet) {
        let options = ProposalOptions(explanations: explanations)
        let rulesOnly = proposeSync(doc.inputs(useAI: false, presets: presets), rules: rules, dictionaries: dictionaries,
                                    options: options)
        guard useAI, doc.judgements.contains(where: { $0.verdict != nil }) else { return (rulesOnly, rulesOnly) }
        return (rulesOnly, proposeSync(doc.inputs(useAI: true, rulesOnly: rulesOnly, presets: presets), rules: rules,
                                       dictionaries: dictionaries, options: options))
    }
}
