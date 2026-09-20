import Foundation
import QooMetaAI
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

/// 提案を計算する道具一式(規則・語彙)。
struct Proposer {
    let rules: CompiledRules
    let dictionaries: [String: WordSet]
    /// フォルダごとのプリセットの割り当て(`--presets`)。無ければ既定のプリセットで読む。
    var presets: ScanDocument.PresetMap?
    /// 説明(組になりかけた相手など)も作るか(見直し表のため)。
    var explanations = false

    /// 規則だけの提案と、端末内モデルの判定を反映した提案。
    func proposals(_ doc: ScanDocument, useAI: Bool) -> (rulesOnly: ProposalSet, final: ProposalSet) {
        let options = ProposalOptions(explanations: explanations)
        let rulesOnly = proposeSync(doc.inputs(useAI: false, presets: presets), rules: rules, dictionaries: dictionaries,
                                    options: options)
        guard useAI, doc.judgements.contains(where: { $0.verdict != nil }) else { return (rulesOnly, rulesOnly) }
        return (rulesOnly, proposeSync(doc.inputs(useAI: true, rulesOnly: rulesOnly, presets: presets), rules: rules,
                                       dictionaries: dictionaries, options: options))
    }
}
