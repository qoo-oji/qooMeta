import Foundation
import FoundationModels
import QooMetaCore

/// 規則で作ったシリーズ候補 1 組を、端末内モデル(Apple Intelligence)に判定させる。
///
/// モデルに任せるのは「小さな組を見て判断する」ことだけ。蔵書全体を渡して分類させない
/// (一度に読める量は macOS 27 で 8,192 トークン。小さなモデルは多数の見比べが苦手)。
/// 1 組ごとに新しいセッションを作り、前の組の内容を持ち越さない。
public struct SeriesJudge: Sendable {
    /// 1 回に見せる冊数の上限。これより大きい組は分けて判定し、結果を合わせる。
    public var chunkSize = 20

    public init() {}

    public static var availability: String {
        "\(SystemLanguageModel.default.availability)"
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct Judgement {
        @Guide(description: "同じ作品のシリーズ(続編・番外編・総集編を含む)なら true。タイトルの前半が同じでも、ありふれた言葉がたまたま一致しているだけで内容が別の作品なら false")
        var isSeries: Bool
        @Guide(description: "シリーズ名。タイトルに実際に現れる共通部分を、語の途中で切らずに書く。巻数・副題・記号は含めない")
        var seriesName: String
        @Guide(description: "シリーズに含めない本の番号(全部含めるなら空)")
        var excludedNumbers: [Int]
        @Guide(description: "判断の確からしさ", .anyOf(["high", "medium", "low"]))
        var confidence: String
    }

    static let instructions = """
    あなたは漫画・同人誌の蔵書整理を手伝う。同じ書き手による本のタイトルの一覧と、\
    機械的に求めたシリーズ名の候補が与えられる。これらが同じ作品のシリーズかどうかを判定し、\
    自然なシリーズ名を答える。タイトルに書かれていないことを推測で補わない。
    """

    public func judge(group: SeriesGroup, titlesByID: [Int: String]) async throws -> AIVerdict {
        let started = Date()
        let chunks = stride(from: 0, to: group.memberIDs.count, by: chunkSize).map {
            Array(group.memberIDs[$0..<min($0 + chunkSize, group.memberIDs.count)])
        }
        var results: [(Judgement, [Int])] = []
        for ids in chunks {
            let session = LanguageModelSession(instructions: Self.instructions)
            let list = ids.enumerated().map { "\($0.offset + 1). \(titlesByID[$0.element] ?? "")" }
                .joined(separator: "\n")
            let prompt = "シリーズ名の候補: \(group.ruleName)\nタイトル:\n\(list)"
            let response = try await session.respond(
                to: prompt, generating: Judgement.self, options: GenerationOptions(temperature: 0))
            results.append((response.content, ids))
        }
        let first = results[0].0
        let excluded = results.flatMap { judgement, ids in
            judgement.excludedNumbers.compactMap { n in (1...ids.count).contains(n) ? ids[n - 1] : nil }
        }
        let rank: [String: Int] = ["low": 0, "medium": 1, "high": 2]
        let confidence = results.map(\.0.confidence).min { (rank[$0] ?? 0) < (rank[$1] ?? 0) } ?? "low"
        return AIVerdict(
            isSeries: results.contains { $0.0.isSeries },
            seriesName: first.seriesName,
            excludedIDs: excluded,
            confidence: AIVerdict.Confidence(rawValue: confidence) ?? .low,
            seconds: Date().timeIntervalSince(started)
        )
    }

    /// 判定できなかった理由を、名前を含まない短い文にする(エラーの説明に入力が写ることがあるため)。
    public static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "guardrailViolation"
            case .exceededContextWindowSize: return "exceededContextWindowSize"
            case .refusal: return "refusal"
            case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
            case .decodingFailure: return "decodingFailure"
            case .rateLimited: return "rateLimited"
            case .concurrentRequests: return "concurrentRequests"
            case .assetsUnavailable: return "assetsUnavailable"
            case .unsupportedGuide: return "unsupportedGuide"
            @unknown default: return "generationError"
            }
        }
        return String(describing: type(of: error))
    }
}
