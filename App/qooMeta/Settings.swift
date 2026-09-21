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
        guard !rulesDiff.isEmpty else { return .none }
        // 規則の窓は、描くたびに何度もこれを読む。差分の文字が同じあいだは、JSON を読み直さない。
        if let parsed = parsedChanges, parsed.text == rulesDiff { return parsed.changes }
        let changes = (try? RuleChanges(data: Data(rulesDiff.utf8))) ?? .none
        parsedChanges = (rulesDiff, changes)
        return changes
    }

    @ObservationIgnored private var parsedChanges: (text: String, changes: RuleChanges)?

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
    ///
    /// `keepingUnreadable` は、設定ファイルから読むときだけ真にする: 組み立てられなかった差分も**文字のまま持ち続ける**。
    /// 捨ててしまうと、次に何かを保存したときに空の差分で上書きされ、利用者の規則が黙って消える(版を上げて、前の差分が
    /// 通らなくなったとき。2026-09-21 の監査)。持っていれば、差分の画面に理由と一緒に出るので、直すか戻すかを選べる。
    @discardableResult
    func setRulesDiff(_ text: String, keepingUnreadable: Bool = false) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rulesDiff = ""
            rules = .builtin
            ruleIssues = []
            save()
            return []
        }
        guard let builtIn = try? BuiltInRules.bundled() else {
            if keepingUnreadable { rulesDiff = trimmed }
            return ["The bundled rules could not be read".ui]
        }
        let compiled = CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: Data(trimmed.utf8)))
        guard let compiledRules = compiled.rules else {
            ruleIssues = compiled.errors.map(\.description)
            if keepingUnreadable { rulesDiff = trimmed }
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
        var quitsWhenLastWindowCloses = false

        init(rulesDiff: String, stamps: [Stamp], mappings: [FieldMapping], language: AppLanguage,
             quitsWhenLastWindowCloses: Bool) {
            self.rulesDiff = rulesDiff
            self.stamps = stamps
            self.mappings = mappings
            self.language = language
            self.quitsWhenLastWindowCloses = quitsWhenLastWindowCloses
        }

        /// **鍵が無くても、知らない値があっても、読める所だけを読む。** 自動で作られる読み方は、既定値のある欄でも鍵が
        /// 無ければ全体を失敗にする。欄を足す前の設定ファイルや、新しい版が書いた値(知らない言語・書き出し先)で
        /// 全体が読めなくなり、次の保存で規則の差分もスタンプも既定値に上書きされていた(2026-09-21 の監査)。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            /// 鍵が無ければ既定値。鍵はあるのに読めなければ、既定値にしたうえで「読み落とした」と覚えておく。
            var skipped = false
            func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                guard c.contains(key) else { return fallback }
                if let value = try? c.decode(T.self, forKey: key) { return value }
                skipped = true
                return fallback
            }
            rulesDiff = read(.rulesDiff, "")
            let readStamps = read(.stamps, [Lossy<Stamp>]()), readMappings = read(.mappings, [Lossy<FieldMapping>]())
            stamps = readStamps.compactMap(\.value)
            mappings = readMappings.compactMap(\.value)
            language = read(.language, AppLanguage.system)
            quitsWhenLastWindowCloses = read(.quitsWhenLastWindowCloses, false)
            skippedSomething = skipped || stamps.count != readStamps.count || mappings.count != readMappings.count
        }

        /// 読めずに飛ばした所がある(新しい版が書いた値など)。保存する前に、元のファイルの写しを残す合図。
        var skippedSomething = false

        enum CodingKeys: String, CodingKey { case rulesDiff, stamps, mappings, language, quitsWhenLastWindowCloses }
    }

    /// 並びの 1 件。読めない 1 件で、並びの全体を失敗にしない。
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    /// 設定ファイルの読み書きで起きた問題。言葉にするのは画面に出すとき(起動の途中、言語を効かせる前に起きうるため)。
    enum StorageIssue: Hashable {
        /// 読めなかったので既定値で始めた。読めなかったファイルは、この名前で残してある。
        case unreadableKept(String)
        /// 一部だけ読めた(新しい版が書いた値などを飛ばした)。元のファイルは、この名前で残してある。
        case partlyReadKept(String)
        /// 読めず、写しも残せなかった。上書きしないので、設定の変更は保存されない。
        case unreadableNotKept
        case notSaved(String)
    }

    /// nil なら問題なし。
    private(set) var storageIssue: StorageIssue?

    /// 画面に出す文。
    var storageIssueText: String? {
        switch storageIssue {
        case nil: nil
        case .unreadableKept(let name):
            "The settings file could not be read, so qooMeta started with the defaults. The unreadable file was kept as “%@”.".ui(name)
        case .partlyReadKept(let name):
            "Part of the settings file could not be read and was skipped. The file as it was is kept as “%@”.".ui(name)
        case .unreadableNotKept:
            "The settings file could not be read, and no copy of it could be kept. qooMeta will not overwrite it, so changes to the settings are not saved.".ui
        case .notSaved(let reason): "The settings could not be saved: %@".ui(reason)
        }
    }

    /// 読めなかった設定ファイルを、まだ退避できていない。このあいだは上書きしない(中身を失わないため)。
    private var holdsSaving = false

    func dismissStorageIssue() { storageIssue = nil }

    func load() { load(from: Self.url) }

    /// 設定ファイルを読む。**読めなかったファイルは、別の名前で残してから使い始める**(黙って既定値で上書きしない)。
    func load(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            // 読めずに飛ばした所は、次の保存で消える。その前に、元のファイルの写しを残す。
            if stored.skippedSomething { keepCopy(of: url, partly: true) }
            stamps = stored.stamps
            mappings = Dictionary(stored.mappings.map { ($0.target, $0) }, uniquingKeysWith: { a, _ in a })
            language = stored.language
            quitsWhenLastWindowCloses = stored.quitsWhenLastWindowCloses
            setRulesDiff(stored.rulesDiff, keepingUnreadable: true)
        } catch {
            // JSON として壊れている、または読めない。中身は利用者の規則やスタンプかもしれないので、写しを残す。
            keepCopy(of: url, partly: false)
        }
    }

    /// 読めなかった(または一部を読み落とした)設定ファイルの写しを、隣に残す。残せなければ、上書きを止める。
    private func keepCopy(of url: URL, partly: Bool) {
        let folder = url.deletingLastPathComponent(), prefix = "settings.unreadable-"
        // 同じ中身の写しがもうあれば、それを指す(直さないまま起動するたびに、写しを増やさない)。
        let original = try? Data(contentsOf: url)
        let kept = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        if let original, let same = kept.first(where: { (try? Data(contentsOf: $0)) == original }) {
            storageIssue = partly ? .partlyReadKept(same.lastPathComponent) : .unreadableKept(same.lastPathComponent)
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let copy = folder.appendingPathComponent("\(prefix)\(stamp).json")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            storageIssue = partly ? .partlyReadKept(copy.lastPathComponent) : .unreadableKept(copy.lastPathComponent)
        } catch {
            holdsSaving = true
            storageIssue = .unreadableNotKept
        }
    }

    func save() { save(to: Self.url) }

    func save(to url: URL) {
        guard !holdsSaving else { return }
        let stored = Stored(rulesDiff: rulesDiff, stamps: stamps, mappings: Array(mappings.values), language: language,
                            quitsWhenLastWindowCloses: quitsWhenLastWindowCloses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(stored)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // 保存できなかったことを黙っていない(次に起動したとき、直したはずの規則が消えていることになる)。
            storageIssue = .notSaved(error.localizedDescription)
        }
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
