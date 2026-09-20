import Foundation

/// 規則の一覧(種類・パラメータの型と範囲・今の値・既定値・利用者が変えたかどうか)。規則の編集画面用。表示の言葉は含まない。
///
/// 並びは処理の段階の順(docs/rules-format-design.md「段階と規則」)。巻の読み手だけは今の優先の順。
public struct RuleCatalog: Sendable, Hashable {
    /// 好みで選ぶ方針(版・総集編・雑誌の扱い …)。規則より手前の、ふつうの設定として見せる。
    public struct Policy: Sendable, Hashable, Identifiable {
        public let id: String
        public let choices: [String]
        public let current: String
        public let defaultChoice: String
        public var isModified: Bool { current != defaultChoice }
    }

    public struct Parameter: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case bool
            case int(ClosedRange<Int>)
            case choice([String])
            /// 一覧(`"@list:名前"` で指すか、その場の値)。中身の種類は characters / words / pairs。
            case list(String)
            case patterns
        }

        public let name: String
        public let kind: Kind
        public let current: JSONValue
        public let defaultValue: JSONValue
        public var isModified: Bool { current != defaultValue }
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        /// 規則の ID(差分でのキー)。
        public let id: String
        /// 段階(`grouping`・`volume.readers` など、JSON の中の道筋)。
        public let stage: String
        /// 止められる規則か(方針が働きを決める規則は止められない)。
        public let canDisable: Bool
        public let isEnabled: Bool
        public let isModified: Bool
        public let parameters: [Parameter]
    }

    public struct ListEntry: Sendable, Hashable, Identifiable {
        public let id: String
        /// characters / words / pairs。
        public let kind: String
        /// 今の中身(対応表は「左→右」の形)。
        public let items: [String]
        /// 利用者が足した・外した語(既定値との違い)。
        public let added: [String]
        public let removed: [String]
    }

    public let policies: [Policy]
    public let entries: [Entry]
    public let lists: [ListEntry]
}

extension CompiledRules {
    public var catalog: RuleCatalog {
        let policiesNow = mergedSeriesRules["policies"]?.objectValue ?? [:]
        let policiesDefault = defaultSeriesRules["policies"]?.objectValue ?? [:]
        let policies = RuleSchema.policies.map { p in
            RuleCatalog.Policy(id: p.name, choices: p.choices,
                               current: policiesNow[p.name]?.stringValue ?? p.choices[0],
                               defaultChoice: policiesDefault[p.name]?.stringValue ?? p.choices[0])
        }

        var entries: [RuleCatalog.Entry] = []
        func parameterKind(_ shape: RuleSchema.Shape) -> RuleCatalog.Parameter.Kind? {
            switch shape {
            case .bool: .bool
            case .int(let r): .int(r)
            case .choice(let c): .choice(c)
            case .list(let k): .list(k.rawValue)
            case .patterns: .patterns
            default: nil
            }
        }
        func entry(_ id: String, stage: String, node: RuleSchema.Node, now: JSONValue?, before: JSONValue?) -> RuleCatalog.Entry {
            let parameters = node.fields.compactMap { f -> RuleCatalog.Parameter? in
                guard let kind = parameterKind(f.shape) else { return nil }
                return RuleCatalog.Parameter(name: f.name, kind: kind, current: now?[f.name] ?? .null,
                                             defaultValue: before?[f.name] ?? .null)
            }
            let enabled = now?["enabled"]?.boolValue ?? true
            let modified = parameters.contains(where: \.isModified) || enabled != (before?["enabled"]?.boolValue ?? true)
            return RuleCatalog.Entry(id: id, stage: stage, canDisable: node.hasEnabled, isEnabled: enabled,
                                     isModified: modified, parameters: parameters)
        }
        func walk(_ node: RuleSchema.Node, path: String, now: JSONValue?, before: JSONValue?) {
            for field in node.fields {
                let childPath = path.isEmpty ? field.name : "\(path).\(field.name)"
                switch field.shape {
                case .object(let child):
                    if child.isRule {
                        entries.append(entry(field.name, stage: path, node: child, now: now?[field.name], before: before?[field.name]))
                    }
                    walk(child, path: childPath, now: now?[field.name], before: before?[field.name])
                case .readers:
                    let current = now?[field.name]?.arrayValue ?? []
                    let defaults = before?[field.name]?.arrayValue ?? []
                    for reader in current {
                        guard let id = reader["id"]?.stringValue,
                              let type = RuleSchema.readerTypes.first(where: { $0.id == id }) else { continue }
                        entries.append(entry(id, stage: childPath, node: RuleSchema.Node(type.fields, rule: true, enabled: true),
                                             now: reader, before: defaults.first { $0["id"]?.stringValue == id }))
                    }
                case .markers:
                    let defaults = before?[field.name]?.arrayValue ?? []
                    for rule in now?[field.name]?.arrayValue ?? [] {
                        guard let id = rule["id"]?.stringValue else { continue }
                        entries.append(entry(id, stage: childPath, node: RuleSchema.markerNode, now: rule,
                                             before: defaults.first { $0["id"]?.stringValue == id }))
                    }
                default: break
                }
            }
        }
        walk(RuleSchema.seriesStages, path: "", now: mergedSeriesRules, before: defaultSeriesRules)
        walk(RuleSchema.formatStages, path: "", now: mergedFilenameFormats, before: defaultFilenameFormats)

        let listsNow = mergedSeriesRules["lists"]?.objectValue ?? [:]
        let listsDefault = defaultSeriesRules["lists"]?.objectValue ?? [:]
        let lists = RuleSchema.lists.keys.sorted().map { name -> RuleCatalog.ListEntry in
            func items(_ v: JSONValue?) -> [String] {
                if let map = v?.objectValue { return map.keys.sorted().map { "\($0)→\(map[$0]?.stringValue ?? "")" } }
                return v?.arrayValue?.compactMap(\.stringValue) ?? []
            }
            let now = items(listsNow[name]), before = items(listsDefault[name])
            return RuleCatalog.ListEntry(id: name, kind: RuleSchema.lists[name]!.rawValue, items: now,
                                         added: now.filter { !before.contains($0) }, removed: before.filter { !now.contains($0) })
        }
        return RuleCatalog(policies: policies, entries: entries, lists: lists)
    }
}

/// 利用者の変更(既定値との差分)。保存先は利用側が決める。`data()` は rules-bundle の形で、ほかのアプリへも持ち運べる。
///
/// ここで作る差分は、そのまま `RuleSources.userChanges` に渡せる。値の正しさは組み立てのとき(`CompiledRules.compile`)に
/// すべて確かめる。
public struct RuleChanges: Sendable, Hashable {
    var series: [String: JSONValue] = [:]
    var formats: [String: JSONValue] = [:]

    /// 初期化(変更なし)。
    public static var none: RuleChanges { RuleChanges() }

    init() {}

    /// 差分(シリーズの規則・フォーマット)か rules-bundle を読む。形の細かい誤りは組み立てのときに出る。
    public init(data: Data) throws(RulesIssue) {
        let root = try JSONValue.parse(data, source: "user")
        guard let o = root.objectValue else { throw RulesIssue(.invalidValue, source: "user", at: "", "オブジェクトであるべきところ") }
        guard o["base"]?.stringValue == "builtin" else { throw RulesIssue(.missingKey, source: "user", at: "base") }
        let envelope = Set(RuleLoader.envelopeKeys)
        func body(_ v: JSONValue?) -> [String: JSONValue] { (v?.objectValue ?? [:]).filter { !envelope.contains($0.key) } }
        switch o["kind"]?.stringValue {
        case RuleLoader.Kind.seriesRules.rawValue: series = body(root)
        case RuleLoader.Kind.filenameFormats.rawValue: formats = body(root)
        case RuleLoader.Kind.bundle.rawValue:
            series = body(o["seriesRules"])
            formats = body(o["filenameFormats"])
        default: throw RulesIssue(.wrongKind, source: "user", at: "kind", o["kind"]?.stringValue)
        }
    }

    public var isEmpty: Bool { series.isEmpty && formats.isEmpty }

    /// 保存・持ち運び用(rules-bundle)。キーは並べ替える(同じ変更なら同じバイト列)。
    public func data() -> Data {
        var bundle: [String: JSONValue] = [
            "kind": .string(RuleLoader.Kind.bundle.rawValue), "schemaVersion": .number(2), "base": .string("builtin"),
        ]
        if !series.isEmpty { bundle["seriesRules"] = .object(series) }
        if !formats.isEmpty { bundle["filenameFormats"] = .object(formats) }
        return Data((JSONValue.object(bundle).rendered() + "\n").utf8)
    }

    public mutating func setPolicy(_ choice: String, for policy: String) {
        Self.set(&series, ["policies", policy], .string(choice))
    }

    public mutating func resetPolicy(_ policy: String) {
        Self.remove(&series, ["policies", policy])
    }

    /// 規則を止める・動かす。知らない規則の ID なら何もしない(false を返す)。
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, rule: String) -> Bool {
        guard let (inFormats, path) = Self.path(of: rule) else { return false }
        if inFormats { Self.set(&formats, path + ["enabled"], .bool(enabled)) } else { Self.set(&series, path + ["enabled"], .bool(enabled)) }
        return true
    }

    /// パラメータを変える。配列の値は丸ごと置き換える(`$replace`)。
    @discardableResult
    public mutating func setValue(_ value: JSONValue, rule: String, parameter: String) -> Bool {
        guard let (inFormats, path) = Self.path(of: rule) else { return false }
        let stored: JSONValue = if case .array = value { .object(["$replace": value]) } else { value }
        if inFormats { Self.set(&formats, path + [parameter], stored) } else { Self.set(&series, path + [parameter], stored) }
        return true
    }

    /// 巻の読み手の優先の順(挙げた読み手を先頭に寄せる)。
    public mutating func setReaderOrder(_ ids: [String]) {
        Self.set(&series, ["volume", "readers", "$order"], .array(ids.map(JSONValue.string)))
    }

    public mutating func add(_ words: [String], to list: String) { edit(list, adding: words, removing: []) }
    public mutating func remove(_ words: [String], from list: String) { edit(list, adding: [], removing: words) }

    /// その規則だけ既定値に戻す。
    public mutating func reset(rule: String) {
        guard let (inFormats, path) = Self.path(of: rule) else { return }
        if inFormats { Self.remove(&formats, path) } else { Self.remove(&series, path) }
    }

    public mutating func resetList(_ list: String) { Self.remove(&series, ["lists", list]) }

    // MARK: - 内部

    /// 足す語は `$remove` から、外す語は `$add` から除く(最後の操作が効くように)。
    mutating func edit(_ list: String, adding: [String], removing: [String]) {
        var ops = series["lists"]?[list]?.objectValue ?? [:]
        var add = ops["$add"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var remove = ops["$remove"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for w in adding { remove.removeAll { $0 == w }; if !add.contains(w) { add.append(w) } }
        for w in removing { add.removeAll { $0 == w }; if !remove.contains(w) { remove.append(w) } }
        ops["$add"] = add.isEmpty ? nil : .array(add.map(JSONValue.string))
        ops["$remove"] = remove.isEmpty ? nil : .array(remove.map(JSONValue.string))
        if ops.isEmpty { Self.remove(&series, ["lists", list]) } else { Self.set(&series, ["lists", list], .object(ops)) }
    }

    /// 規則の ID → (フォーマットのファイルか, 差分の中の道筋)。
    static func path(of rule: String) -> (Bool, [String])? {
        func find(_ node: RuleSchema.Node, _ path: [String]) -> [String]? {
            for field in node.fields {
                switch field.shape {
                case .object(let child):
                    if child.isRule, field.name == rule { return path + [field.name] }
                    if let found = find(child, path + [field.name]) { return found }
                case .readers:
                    if RuleSchema.readerTypes.contains(where: { $0.id == rule }) { return path + [field.name, rule] }
                case .markers:
                    if RuleSchema.builtInMarkerIDs.contains(rule) { return path + [field.name, rule] }
                default: break
                }
            }
            return nil
        }
        if let p = find(RuleSchema.seriesStages, []) { return (false, p) }
        if let p = find(RuleSchema.formatStages, []) { return (true, p) }
        return nil
    }

    static func set(_ root: inout [String: JSONValue], _ path: [String], _ value: JSONValue) {
        guard let head = path.first else { return }
        if path.count == 1 { root[head] = value; return }
        var child = root[head]?.objectValue ?? [:]
        set(&child, Array(path.dropFirst()), value)
        root[head] = .object(child)
    }

    /// 道筋の値を消し、空になったオブジェクトも消す。
    static func remove(_ root: inout [String: JSONValue], _ path: [String]) {
        guard let head = path.first else { return }
        if path.count == 1 { root[head] = nil; return }
        guard var child = root[head]?.objectValue else { return }
        remove(&child, Array(path.dropFirst()))
        root[head] = child.isEmpty ? nil : .object(child)
    }
}
