import Foundation
import Observation
import QooMetaExport
import QooMetaKit

/// アプリの設定。**作業ファイル(いま直している一覧)とは分ける**: 設定はどの一覧にも共通で、作業ファイルは一覧ごと。
///
/// 中身は、規則の差分(画面で変えた方針・語の一覧)・スタンプ・書き出しの対応表。
/// 蔵書の名前は入りうる(スタンプの値・規則に足した語)ので、保存先は利用者の手元だけ
/// (`~/Library/Application Support/qooMeta/settings.json`)。
@MainActor @Observable
final class AppSettings {
    /// 画面で変えた規則(同梱の既定値に重ねる差分。concept.md の原則 8)。空なら既定のまま。
    var rulesDiff: String = ""
    /// スタンプ(よく使う値を選んだ本へ一度に押す)。
    var stamps: [Stamp] = []
    /// 書き出し先ごとの欄の対応表(既定からの変更だけを持つ)。
    var mappings: [ExportTarget: FieldMapping] = [:]
    /// 画面の言葉の言語(`system` なら macOS の設定に従う)。
    private(set) var language: AppLanguage = .system
    /// すべての窓を閉じたときに、アプリを終わらせるか。
    ///
    /// macOS の作法では、窓を閉じてもアプリは残る(Dock から次の一覧を開ける)。qooMeta は 1 回きりの流れを
    /// 1 つずつ片付ける道具なので、閉じたら終わってほしい利用者もいる ―― どちらが良いかは使い方で変わるので選べるようにする
    /// (2026-09-20、利用者の指示)。**既定はこれまでどおり残す側**。
    private(set) var quitsWhenLastWindowCloses = false

    /// 規則の差分を読み込んだ結果(誤りがあれば既定のまま使い、理由を持つ)。
    private(set) var rules: CompiledRules = .builtin
    private(set) var ruleIssues: [String] = []

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/qooMeta/settings.json")

    /// 設定はアプリに 1 組(どの窓も、規則の窓も、同じものを見る)。
    static let shared = AppSettings()

    init() {
        load()
    }

    /// すべての窓を閉じたら終わるかを変える。次に窓を閉じたときから効く(いま開いている窓には何もしない)。
    func setQuitsWhenLastWindowCloses(_ quits: Bool) {
        guard quits != quitsWhenLastWindowCloses else { return }
        quitsWhenLastWindowCloses = quits
        save()
    }

    /// 画面の言葉の言語を変える。すぐ効かせる(`Bundle.main` の引き先を替え、画面を描き直させる)。
    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        language.apply()
        save()
    }

    /// 画面で変えた規則(差分を、操作しやすい形で)。
    var changes: RuleChanges {
        rulesDiff.isEmpty ? .none : ((try? RuleChanges(data: Data(rulesDiff.utf8))) ?? .none)
    }

    /// 規則の半分(ファイル名の解析 / シリーズと巻数)だけを、書いた JSON で差し替える。
    @discardableResult
    func setRulesDiff(_ text: String, for half: RuleChanges.Half) -> [String] {
        var next = changes
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            next.reset(half)
        } else {
            do { try next.replace(half, with: Data(trimmed.utf8)) } catch { return [error.description] }
        }
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    /// その半分で、既定から変えている所の数(窓の下の帯に出す)。
    func changedCount(_ half: RuleChanges.Half) -> Int {
        // 変えた値の道筋は、シリーズの規則が段の名前で始まり、ファイル名の解析は presets / separators などで始まる。
        let fileNameRoots = ["presets", "separators", "defaultPreset", "defaults", "plain"]
        return rules.changedPaths.filter { path in
            let root = String(path.prefix { $0 != "." })
            return (half == .fileNames) == fileNameRoots.contains(root)
        }.count
    }

    /// 規則の半分だけを既定に戻す。
    @discardableResult
    func resetRules(_ half: RuleChanges.Half) -> [String] {
        var next = changes
        next.reset(half)
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    /// 規則を 1 か所変える。組み立ててみて誤りがあれば、変えずに理由を返す(画面がその場で示す)。
    @discardableResult
    func update(_ body: (inout RuleChanges) -> Void) -> [String] {
        var next = changes
        body(&next)
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    func mapping(for target: ExportTarget) -> FieldMapping { mappings[target] ?? .standard(for: target) }

    func setMapping(_ mapping: FieldMapping) {
        mappings[mapping.target] = mapping
        save()
    }

    /// 規則の差分を入れ替える。読めたら効かせ、誤りがあれば既定のままにして理由を返す。
    @discardableResult
    func setRulesDiff(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rulesDiff = ""
            rules = .builtin
            ruleIssues = []
            save()
            return []
        }
        guard let builtIn = try? BuiltInRules.bundled() else { return ["The bundled rules could not be read".ui] }
        let compiled = CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: Data(trimmed.utf8)))
        guard let compiledRules = compiled.rules else {
            ruleIssues = compiled.errors.map(\.description)
            return ruleIssues
        }
        rulesDiff = trimmed
        rules = compiledRules
        ruleIssues = compiled.warnings.map(\.description)
        save()
        return []
    }

    // MARK: - 保存

    private struct Stored: Codable {
        var rulesDiff: String = ""
        var stamps: [Stamp] = []
        var mappings: [FieldMapping] = []
        var language: AppLanguage = .system
        /// 古い設定ファイルには無いので、既定(残す側)で読む。
        var quitsWhenLastWindowCloses = false
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.url), let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        stamps = stored.stamps
        mappings = Dictionary(stored.mappings.map { ($0.target, $0) }, uniquingKeysWith: { a, _ in a })
        language = stored.language
        quitsWhenLastWindowCloses = stored.quitsWhenLastWindowCloses
        setRulesDiff(stored.rulesDiff)
    }

    func save() {
        let stored = Stored(rulesDiff: rulesDiff, stamps: stamps, mappings: Array(mappings.values), language: language,
                            quitsWhenLastWindowCloses: quitsWhenLastWindowCloses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// スタンプ: よく使う欄の値をまとめて、選んだ本へ一度に押すもの(StackNest のスタンプと同じ操作)。
/// 値の無い欄は触らない。
struct Stamp: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// 欄 → 値(並びの欄は値の並び)。
    var values: [BookMetadata.Field: [String]]

    init(id: UUID = UUID(), name: String, values: [BookMetadata.Field: [String]]) {
        self.id = id
        self.name = name
        self.values = values
    }

    /// 押したときに何が変わるかの短い説明。
    var summary: String {
        BookMetadata.Field.allCases.compactMap { field in
            guard let value = values[field], !value.isEmpty else { return nil }
            return "\(field.labelKey.ui): \(value.joined(separator: ", "))"
        }.joined(separator: " / ")
    }

    // 欄は文字列の鍵にする(Swift の既定の書き方だと鍵と値が交互に並ぶ配列になり、手で直せない)。
    enum CodingKeys: String, CodingKey { case id, name, values }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .values) ?? [:]
        values = raw.reduce(into: [:]) { result, pair in
            guard let field = BookMetadata.Field(rawValue: pair.key) else { return }
            result[field] = pair.value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: .values)
    }
}
