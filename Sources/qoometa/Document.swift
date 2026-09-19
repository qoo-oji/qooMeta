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

    /// 本の入力。`useAI` なら、端末内モデルの判定を確定した内容として渡す(確定した名前は錨になる)。
    func inputs(useAI: Bool, rulesOnly: ProposalSet? = nil) -> [BookInput] {
        var confirmations: [String: Confirmation] = [:]
        if useAI, let rulesOnly {
            let seriesByMembers = Dictionary(rulesOnly.series.map { ($0.memberIDs.sorted(), $0) },
                                             uniquingKeysWith: { a, _ in a })
            for j in judgements {
                guard let verdict = j.verdict, let series = seriesByMembers[j.memberIDs] else { continue }
                confirmations.merge(verdict.confirmations(for: series)) { a, _ in a }
            }
        }
        return files.map { $0.bookInput(confirmation: confirmations[$0.relativePath] ?? .none) }
    }
}

/// 提案を計算する道具一式(規則・語彙)。
struct Proposer {
    let rules: CompiledRules
    let vocabulary: Vocabulary

    /// 規則だけの提案と、端末内モデルの判定を反映した提案。
    func proposals(_ doc: ScanDocument, useAI: Bool) -> (rulesOnly: ProposalSet, final: ProposalSet) {
        let rulesOnly = proposeSync(doc.inputs(useAI: false), rules: rules, vocabulary: vocabulary)
        guard useAI, doc.judgements.contains(where: { $0.verdict != nil }) else { return (rulesOnly, rulesOnly) }
        return (rulesOnly, proposeSync(doc.inputs(useAI: true, rulesOnly: rulesOnly), rules: rules, vocabulary: vocabulary))
    }
}
