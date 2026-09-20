import Foundation

/// 規則ファイルの読み込み: 型なしで読む → `schemaVersion` を見る → 既定値に差分を重ねる → 検証する。
///
/// 誤りは最初の 1 件で止めず、道筋と近い綴りの候補を付けてすべて集める(規則の編集画面で使うため)。
/// 組み立て(エンジンが使う形にすること)は RuleCompiler。
struct RuleLoader {
    enum Kind: String {
        case seriesRules = "qoometa.series-rules"
        case filenameFormats = "qoometa.filename-formats"
        case bundle = "qoometa.rules-bundle"
    }

    /// 上限。受け取った規則ファイルで、読み込みや照合を止められないようにする。
    enum Limits {
        static let bytes = 1_000_000
        static let items = 5_000
        static let wordLength = 100
        static let patternLength = 500
    }

    let source: String
    let engineLevel: Int
    var issues: [RulesIssue] = []
    /// 差分が変えた値の道筋(`rules show` で、どちらの値が効いているかを示す)。
    var changedPaths: [String] = []
    /// 既定値の `retiredIDs`・`aliases`(差分を読むときに使う)。
    var retiredIDs: Set<String> = []
    var aliases: [String: String] = [:]
    /// 本体の知らない必須の規則が差分にあった(そのファイルは適用しない)。
    var sawRequiredUnknown = false

    init(source: String, engineLevel: Int) {
        self.source = source
        self.engineLevel = engineLevel
    }

    mutating func report(_ code: RulesIssue.Code, _ path: String, _ detail: String? = nil, suggestion: String? = nil) {
        issues.append(RulesIssue(code, source: source, at: path, detail, suggestion: suggestion))
    }

    var hasErrors: Bool { issues.contains { !$0.isWarning } }

    static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    // MARK: - 包み

    /// 包み(`kind`・`schemaVersion`・`base`)を確かめる。`expected` のどれかでなければ誤り。
    mutating func envelope(_ root: JSONValue, expected: [Kind], isDiff: Bool) -> Kind? {
        guard let o = root.objectValue else {
            report(.invalidValue, "", "オブジェクトであるべきところが\(root.kindName)")
            return nil
        }
        var kind: Kind?
        switch o["kind"] {
        case .string(let k)?:
            if let known = Kind(rawValue: k), expected.contains(known) { kind = known }
            else { report(.wrongKind, "kind", k, suggestion: Spelling.suggestion(for: k, among: expected.map(\.rawValue))) }
        case nil: report(.missingKey, "kind")
        case let v?: report(.invalidValue, "kind", "文字列であるべきところが\(v.kindName)")
        }
        // 形式の版はファイルごと(filename-formats は第 6 版、ほかは第 2 版)。
        let expectedVersion = (kind ?? .seriesRules) == .filenameFormats ? 6.0 : 2.0
        switch o["schemaVersion"] {
        case .number(let v)? where v == expectedVersion: break
        case .number(let v)?: report(.unsupportedSchemaVersion, "schemaVersion", JSONValue.number(v).rendered())
        case nil: report(.missingKey, "schemaVersion")
        case let v?: report(.invalidValue, "schemaVersion", "数であるべきところが\(v.kindName)")
        }
        if let r = o["revision"], r.stringValue == nil { report(.invalidValue, "revision", "文字列であるべきところが\(r.kindName)") }
        switch (isDiff, o["base"]) {
        case (true, .string("builtin")?), (false, nil): break
        case (true, nil): report(.missingKey, "base", "差分には \"base\": \"builtin\" が必要")
        case (false, _?): report(.invalidValue, "base", "既定値のファイルには書かない")
        case (true, let v?): report(.invalidValue, "base", "\"builtin\" だけが書ける(\(v.rendered()))")
        }
        return kind
    }

    static let envelopeKeys = ["$schema", "kind", "schemaVersion", "revision", "base"]

    // MARK: - 既定値(全体)の検証

    /// シリーズの規則の既定値を、欠けなく正しいか確かめる。
    mutating func checkSeriesDefaults(_ root: JSONValue) {
        guard let o = root.objectValue else { return }
        let stageNames = RuleSchema.seriesStages.fields.map(\.name)
        let allowed = Self.envelopeKeys + ["lists", "policies", "retiredIDs", "aliases"] + stageNames
        unknownKeys(o, "", allowed: allowed)
        if let lists = required(o, "lists", "") { checkLists(lists) }
        if let policies = required(o, "policies", "") { checkPolicies(policies, "policies", full: true) }
        check(root, .object(RuleSchema.seriesStages), "", full: true, ignoring: Set(allowed).subtracting(stageNames))
        checkRetirement(o)
    }

    /// フォーマットの既定値。型には ID が無いので、`retiredIDs`・`aliases` は持たない(第 5 版で外した)。
    mutating func checkFormatDefaults(_ root: JSONValue) {
        guard let o = root.objectValue else { return }
        let stageNames = RuleSchema.formatStages.fields.map(\.name)
        let allowed = Self.envelopeKeys + stageNames
        unknownKeys(o, "", allowed: allowed)
        check(root, .object(RuleSchema.formatStages), "", full: true, ignoring: Set(allowed).subtracting(stageNames))
    }

    mutating func checkRetirement(_ o: [String: JSONValue]) {
        if let retired = required(o, "retiredIDs", "") {
            if let items = retired.arrayValue, items.allSatisfy({ $0.stringValue != nil }) {
                retiredIDs = Set(items.compactMap(\.stringValue))
            } else {
                report(.invalidValue, "retiredIDs", "文字列の配列であるべきところ")
            }
        }
        if let a = required(o, "aliases", "") {
            if let map = a.objectValue, map.values.allSatisfy({ $0.stringValue != nil }) {
                aliases = map.mapValues { $0.stringValue! }
            } else {
                report(.invalidValue, "aliases", "文字列から文字列への対応表であるべきところ")
            }
        }
    }

    mutating func required(_ o: [String: JSONValue], _ key: String, _ path: String) -> JSONValue? {
        guard let v = o[key] else { report(.missingKey, Self.join(path, key)); return nil }
        return v
    }

    mutating func unknownKeys(_ o: [String: JSONValue], _ path: String, allowed: [String]) {
        for key in o.keys.sorted() where !allowed.contains(key) {
            report(.unknownKey, Self.join(path, key), suggestion: Spelling.suggestion(for: key, among: allowed))
        }
    }

    mutating func checkLists(_ value: JSONValue) {
        guard let o = value.objectValue else {
            report(.invalidValue, "lists", "オブジェクトであるべきところが\(value.kindName)")
            return
        }
        unknownKeys(o, "lists", allowed: RuleSchema.lists.keys.sorted())
        for (name, kind) in RuleSchema.lists.sorted(by: { $0.key < $1.key }) {
            if let v = required(o, name, "lists") { checkListValue(v, kind, "lists.\(name)") }
        }
    }

    mutating func checkPolicies(_ value: JSONValue, _ path: String, full: Bool) {
        guard let o = value.objectValue else {
            report(.invalidValue, path, "オブジェクトであるべきところが\(value.kindName)")
            return
        }
        for (name, choices) in RuleSchema.policies {
            guard let v = o[name] else {
                if full { report(.missingKey, Self.join(path, name)) }
                continue
            }
            checkChoice(v, choices, Self.join(path, name))
        }
        for key in o.keys.sorted() where !RuleSchema.policies.contains(where: { $0.name == key }) {
            skipUnknown(key, o[key]!, path, candidates: RuleSchema.policies.map(\.name))
        }
    }

    mutating func checkChoice(_ v: JSONValue, _ choices: [String], _ path: String) {
        guard let s = v.stringValue else { report(.invalidValue, path, "文字列であるべきところが\(v.kindName)"); return }
        if !choices.contains(s) {
            report(.invalidValue, path, "\(s)。選べる値: \(choices.joined(separator: " / "))",
                   suggestion: Spelling.suggestion(for: s, among: choices))
        }
    }

    /// 形に従って値を確かめる。`full` なら、書くべきキーが欠けていないかも見る(既定値のファイル)。
    mutating func check(_ value: JSONValue, _ shape: RuleSchema.Shape, _ path: String, full: Bool,
                        ignoring: Set<String> = []) {
        switch shape {
        case .bool:
            if value.boolValue == nil { report(.invalidValue, path, "真偽であるべきところが\(value.kindName)") }
        case .int(let range):
            guard let n = value.intValue else { report(.invalidValue, path, "整数であるべきところが\(value.kindName)"); return }
            if !range.contains(n) { report(.invalidValue, path, "\(n)。\(range.lowerBound)〜\(range.upperBound) の範囲") }
        case .choice(let choices):
            checkChoice(value, choices, path)
        case .fixedString:
            if value.stringValue == nil { report(.invalidValue, path, "文字列であるべきところが\(value.kindName)") }
        case .string:
            guard let s = value.stringValue, !s.isEmpty else { report(.invalidValue, path, "空でない文字列であるべきところ"); return }
            if s.count > Limits.patternLength { report(.tooLarge, path, "\(s.count) 文字") }
        case .separators, .strings:
            checkListValue(value, .words, path)
        case .list(let kind):
            if let ref = value.stringValue {
                checkListReference(ref, kind, path)
            } else {
                checkListValue(value, kind, path)
            }
        case .patterns:
            checkPatterns(value, path)
        case .formats:
            guard let items = value.arrayValue else { report(.invalidValue, path, "配列であるべきところが\(value.kindName)"); return }
            if items.count > Limits.items { report(.tooLarge, path, "\(items.count) 件") }
            for (i, item) in items.enumerated() { checkFormatEntry(item, "\(path)[\(i)]") }
        case .object(let node):
            checkObject(value, node, path, full: full, ignoring: ignoring)
        case .readers:
            checkReaders(value, path, full: full)
        case .markers:
            checkMarkers(value, path)
        case .presets:
            guard let o = value.objectValue else { report(.invalidValue, path, "プリセットの名前をキーにしたオブジェクトであるべきところが\(value.kindName)"); return }
            // どの名前のプリセットがあるかは JSON が決める(コードは名前を決め打ちしない)。
            for name in o.keys.sorted() where checkPresetName(name, path) { checkPreset(o[name]!, "\(path).\(name)") }
        case .presetDefaults:
            guard let o = value.objectValue else { report(.invalidValue, path, "欄の名前をキーにしたオブジェクトであるべきところが\(value.kindName)"); return }
            unknownKeys(o, path, allowed: RuleSchema.presetDefaultFields)
            for name in RuleSchema.presetDefaultFields {
                guard let v = o[name] else { continue }
                if (v.stringValue ?? "").isEmpty { report(.invalidValue, "\(path).\(name)", "空でない文字列であるべきところ") }
            }
        }
    }

    /// 1 つのプリセット(全体)。要るのは `formats` だけ。
    mutating func checkPreset(_ value: JSONValue, _ path: String) {
        checkObject(value, RuleSchema.presetNode, path, full: true)
    }

    /// プリセットの名前。`$` で始まる名前は差分の操作と紛れるので使えない。
    mutating func checkPresetName(_ name: String, _ path: String) -> Bool {
        if name.isEmpty || name.hasPrefix("$") || name.count > Limits.wordLength {
            report(.invalidValue, Self.join(path, name), "プリセットの名前は、$ で始まらない 1〜\(Limits.wordLength) 文字")
            return false
        }
        return true
    }

    /// 1 つの型: 文字列か、その型だけの区切り・既定の欄を添えたオブジェクト。型の書き方そのものは組み立てのときに確かめる。
    mutating func checkFormatEntry(_ item: JSONValue, _ path: String) {
        if item.objectValue != nil { checkObject(item, RuleSchema.formatEntryNode, path, full: true); return }
        if (item.stringValue ?? "").isEmpty { report(.invalidValue, path, "空でない文字列か、\"format\" を持つオブジェクトであるべきところ") }
    }

    /// 型の文字列(並びの中で型を見分ける鍵。オブジェクトで書いた型も、`format` の文字列で見分ける)。
    static func formatText(_ item: JSONValue) -> JSONValue { item["format"] ?? item }

    mutating func checkObject(_ value: JSONValue, _ node: RuleSchema.Node, _ path: String, full: Bool,
                              ignoring: Set<String> = []) {
        guard let o = value.objectValue else {
            report(.invalidValue, path, "オブジェクトであるべきところが\(value.kindName)")
            return
        }
        var allowed = node.fields.map(\.name)
        if node.isRule { allowed += ["since", "required"] + (node.hasEnabled ? ["enabled"] : []) }
        for key in o.keys.sorted() where !allowed.contains(key) && !ignoring.contains(key) {
            skipUnknown(key, o[key]!, path, candidates: allowed)
        }
        if node.hasEnabled {
            if let e = o["enabled"] { check(e, .bool, Self.join(path, "enabled"), full: full) }
            else if full { report(.missingKey, Self.join(path, "enabled")) }
        }
        if node.isRule {
            if let s = o["since"], s.intValue == nil { report(.invalidValue, Self.join(path, "since"), "整数であるべきところ") }
            if let r = o["required"], r.boolValue == nil { report(.invalidValue, Self.join(path, "required"), "真偽であるべきところ") }
        }
        for field in node.fields {
            guard let v = o[field.name] else {
                if full, !field.optional { report(.missingKey, Self.join(path, field.name)) }
                continue
            }
            check(v, field.shape, Self.join(path, field.name), full: full)
        }
    }

    /// 知らないキー。廃止された ID・新しい版の規則なら警告で飛ばし、それ以外は書き間違いとして誤りにする。
    mutating func skipUnknown(_ key: String, _ value: JSONValue, _ path: String, candidates: [String]) {
        let place = Self.join(path, key)
        if retiredIDs.contains(key) {
            report(.retiredID, place)
            return
        }
        if let since = value["since"]?.intValue, since > engineLevel {
            report(.newerRuleSkipped, place, "since \(since)")
            if value["required"]?.boolValue == true {
                sawRequiredUnknown = true
                report(.requiredRuleUnknown, place)
            }
            return
        }
        report(.unknownKey, place, suggestion: Spelling.suggestion(for: key, among: candidates))
    }

    mutating func checkListReference(_ ref: String, _ kind: RuleSchema.ListKind, _ path: String) {
        guard ref.hasPrefix("@list:") else {
            report(.invalidValue, path, "一覧は \"@list:名前\" で指すか、その場に配列で書く")
            return
        }
        let name = String(ref.dropFirst("@list:".count))
        guard let actual = RuleSchema.lists[name] else {
            report(.unresolvedList, path, name, suggestion: Spelling.suggestion(for: name, among: RuleSchema.lists.keys))
            return
        }
        if actual != kind { report(.invalidValue, path, "一覧 \(name) は \(actual.rawValue) で、ここには \(kind.rawValue) が要る") }
    }

    mutating func checkListValue(_ value: JSONValue, _ kind: RuleSchema.ListKind, _ path: String) {
        switch kind {
        case .characters, .words:
            guard let items = value.arrayValue else {
                report(.invalidValue, path, "文字列の配列であるべきところが\(value.kindName)")
                return
            }
            if items.count > Limits.items { report(.tooLarge, path, "\(items.count) 件") }
            for (i, item) in items.enumerated() { checkListItem(item, kind, "\(path)[\(i)]") }
        case .pairs:
            guard let map = value.objectValue else {
                report(.invalidValue, path, "1 文字から 1 文字への対応表であるべきところが\(value.kindName)")
                return
            }
            if map.count > Limits.items { report(.tooLarge, path, "\(map.count) 件") }
            for key in map.keys.sorted() {
                if key.count != 1 { report(.invalidValue, Self.join(path, key), "キーは 1 文字") }
                checkListItem(map[key]!, .characters, Self.join(path, key))
            }
        }
    }

    mutating func checkListItem(_ item: JSONValue, _ kind: RuleSchema.ListKind, _ path: String) {
        guard let s = item.stringValue else { report(.invalidValue, path, "文字列であるべきところが\(item.kindName)"); return }
        switch kind {
        case .characters, .pairs:
            if s.count != 1 { report(.invalidValue, path, "1 文字であるべきところが \(s.count) 文字") }
        case .words:
            if s.isEmpty { report(.invalidValue, path, "空の語") }
            if s.count > Limits.wordLength { report(.tooLarge, path, "\(s.count) 文字") }
        }
    }

    mutating func checkPatterns(_ value: JSONValue, _ path: String) {
        guard let items = value.arrayValue else {
            report(.invalidValue, path, "正規表現の配列であるべきところが\(value.kindName)")
            return
        }
        if items.count > Limits.items { report(.tooLarge, path, "\(items.count) 件") }
        for (i, item) in items.enumerated() { checkPattern(item, "\(path)[\(i)]") }
    }

    /// 正規表現(ICU)。読めないもの、指数時間になりうる形(量指定子の付いたグループの入れ子、後方参照)は誤り。
    mutating func checkPattern(_ item: JSONValue, _ path: String) {
        guard let s = item.stringValue, !s.isEmpty else {
            report(.invalidValue, path, "空でない文字列であるべきところ")
            return
        }
        if s.count > Limits.patternLength { report(.tooLarge, path, "\(s.count) 文字"); return }
        do { _ = try NSRegularExpression(pattern: s) } catch {
            report(.unsafePattern, path, "正規表現として読めない")
            return
        }
        for finding in PatternSafety.findings(s) {
            switch finding {
            case .quantifiedGroup: report(.unsafePattern, path, "量指定子の付いたグループの中に量指定子か選択肢がある")
            case .backreference: report(.unsafePattern, path, "後方参照")
            }
        }
    }

    mutating func checkReaders(_ value: JSONValue, _ path: String, full: Bool) {
        guard let items = value.arrayValue else {
            report(.invalidValue, path, "読み手の配列であるべきところが\(value.kindName)")
            return
        }
        var seen = Set<String>()
        for (i, item) in items.enumerated() {
            let p = "\(path)[\(i)]"
            guard let id = item["id"]?.stringValue else { report(.missingKey, "\(p).id"); continue }
            guard let reader = RuleSchema.readerTypes.first(where: { $0.id == id }) else {
                if item["since"]?.intValue.map({ $0 > engineLevel }) == true {
                    skipUnknown(id, item, path, candidates: [])
                } else {
                    report(.notYetSupported, "\(p).id", "読み手を足すこと(\(id))",
                           suggestion: Spelling.suggestion(for: id, among: RuleSchema.readerTypes.map(\.id)))
                }
                continue
            }
            if !seen.insert(id).inserted { report(.duplicateID, "\(p).id", id) }
            if item["type"]?.stringValue != reader.type {
                report(.invalidValue, "\(p).type", "読み手 \(id) の種類は \(reader.type)")
            }
            check(item, .object(RuleSchema.Node(reader.fields, rule: true, enabled: true)), p, full: full,
                  ignoring: ["id", "type"])
        }
        if full {
            for reader in RuleSchema.readerTypes where !seen.contains(reader.id) {
                report(.missingKey, path, "読み手 \(reader.id)")
            }
        }
    }

    /// 語の規則の並び(全体)。ID は JSON が決める(重なりだけを見る)。
    mutating func checkMarkers(_ value: JSONValue, _ path: String) {
        guard let items = value.arrayValue else {
            report(.invalidValue, path, "語の規則の配列であるべきところが\(value.kindName)")
            return
        }
        if items.count > Limits.items { report(.tooLarge, path, "\(items.count) 件") }
        var seen = Set<String>()
        for (i, item) in items.enumerated() {
            let p = "\(path)[\(i)]"
            guard let id = item["id"]?.stringValue else { report(.missingKey, "\(p).id"); continue }
            guard checkRuleID(id, p) else { continue }
            if !seen.insert(id).inserted { report(.duplicateID, "\(p).id", id) }
            check(item, .object(RuleSchema.markerNode), p, full: true, ignoring: ["id"])
        }
    }

    /// 利用者が付けられる規則の ID。`$` で始まる名前は差分の操作と紛れるので使えない。
    mutating func checkRuleID(_ id: String, _ path: String) -> Bool {
        if id.isEmpty || id.hasPrefix("$") || id.count > Limits.wordLength {
            report(.invalidValue, "\(path).id", "規則の ID は、$ で始まらない 1〜\(Limits.wordLength) 文字")
            return false
        }
        return true
    }

    // MARK: - 差分を重ねる

    /// シリーズの規則の差分を、既定値に重ねる。
    mutating func applySeries(_ diff: [String: JSONValue], to base: JSONValue) -> JSONValue {
        guard var merged = base.objectValue else { return base }
        let stageNames = RuleSchema.seriesStages.fields.map(\.name)
        let allowed = Self.envelopeKeys + ["lists", "policies"] + stageNames
        for key in diff.keys.sorted() where !allowed.contains(key) {
            if ["retiredIDs", "aliases"].contains(key) {
                report(.invalidValue, key, "既定値のファイルにだけ書ける")
            } else {
                skipUnknown(key, diff[key]!, "", candidates: allowed)
            }
        }
        if let lists = diff["lists"] { merged["lists"] = applyLists(lists, to: merged["lists"] ?? .object([:])) }
        if let policies = diff["policies"] {
            checkPolicies(policies, "policies", full: false)
            if case .object(var current) = merged["policies"] ?? .object([:]), let changes = policies.objectValue {
                for (name, v) in changes where RuleSchema.policies.contains(where: { $0.name == name }) && v.stringValue != nil {
                    current[name] = v
                    changedPaths.append("policies.\(name)")
                }
                merged["policies"] = .object(current)
            }
        }
        for field in RuleSchema.seriesStages.fields {
            if let d = diff[field.name], let b = merged[field.name] {
                merged[field.name] = apply(d, to: b, field.shape, field.name)
            }
        }
        return .object(merged)
    }

    mutating func applyFormats(_ diff: [String: JSONValue], to base: JSONValue) -> JSONValue {
        guard var merged = base.objectValue else { return base }
        let stageNames = RuleSchema.formatStages.fields.map(\.name)
        let allowed = Self.envelopeKeys + stageNames
        for key in diff.keys.sorted() where !allowed.contains(key) {
            if ["retiredIDs", "aliases"].contains(key) {
                report(.invalidValue, key, "既定値のファイルにだけ書ける")
            } else {
                skipUnknown(key, diff[key]!, "", candidates: allowed)
            }
        }
        for field in RuleSchema.formatStages.fields {
            if let d = diff[field.name], let b = merged[field.name] ?? missingBase(field) {
                merged[field.name] = apply(d, to: b, field.shape, field.name)
            }
        }
        return .object(merged)
    }

    /// 省けるキーが既定値の側に無いとき、差分を重ねる土台。区切りは外側(ファイル全体)の値から始める
    /// (「このプリセットでは × も区切りにする」を `$add` だけで書けるように)。
    func missingBase(_ field: RuleSchema.Field) -> JSONValue? {
        guard field.optional else { return nil }
        switch field.shape {
        case .string: return .null
        case .separators: return .array(FilenameFormats.defaultSeparators.map(JSONValue.string))
        case .presetDefaults, .object: return .object([:])
        case .strings, .patterns: return .array([])
        default: return nil
        }
    }

    mutating func applyLists(_ diff: JSONValue, to base: JSONValue) -> JSONValue {
        guard let changes = diff.objectValue, case .object(var lists) = base else {
            report(.invalidValue, "lists", "オブジェクトであるべきところが\(diff.kindName)")
            return base
        }
        for key in changes.keys.sorted() {
            var name = key
            if RuleSchema.lists[name] == nil, let renamed = aliases[name], RuleSchema.lists[renamed] != nil { name = renamed }
            guard let kind = RuleSchema.lists[name], let current = lists[name] else {
                skipUnknown(key, changes[key]!, "lists", candidates: RuleSchema.lists.keys.sorted())
                continue
            }
            lists[name] = applyListOps(changes[key]!, to: current, kind, "lists.\(key)")
        }
        return .object(lists)
    }

    /// 形に従って差分を重ねる。値(数・文字列・真偽)は置き換え、一覧は `$add` などの操作で変える。
    mutating func apply(_ diff: JSONValue, to base: JSONValue, _ shape: RuleSchema.Shape, _ path: String) -> JSONValue {
        switch shape {
        case .bool, .int, .choice:
            let before = issues.count
            check(diff, shape, path, full: false)
            guard issues.count == before else { return base }
            if diff != base { changedPaths.append(path) }
            return diff
        case .fixedString:
            if diff != base { report(.invalidValue, path, "変えられない") }
            return base
        case .string:
            let before = issues.count
            check(diff, shape, path, full: false)
            guard issues.count == before else { return base }
            if diff != base { changedPaths.append(path) }
            return diff
        case .separators, .strings:
            return applyArrayOps(diff, to: base, path, allowsAt: false) { this, item, p in this.checkListItem(item, .words, p) }
        case .list(let kind):
            if let ref = diff.stringValue {
                let before = issues.count
                checkListReference(ref, kind, path)
                guard issues.count == before else { return base }
                if diff != base { changedPaths.append(path) }
                return diff
            }
            if let ref = base.stringValue {
                report(.invalidValue, path, "この値は一覧 \(ref.dropFirst("@list:".count)) を指している。語は lists の側で変える")
                return base
            }
            return applyListOps(diff, to: base, kind, path)
        case .patterns:
            return applyArrayOps(diff, to: base, path, allowsAt: false) { this, item, p in this.checkPattern(item, p) }
        case .formats:
            // 型は `format` の文字列で見分ける(区切りを添えた型も、文字列だけを書けば外せる)。
            return applyArrayOps(diff, to: base, path, allowsAt: true, identity: Self.formatText) { this, item, p in
                this.checkFormatEntry(item, p)
            }
        case .object(let node):
            return applyObject(diff, to: base, node, path)
        case .presetDefaults:
            guard let changes = diff.objectValue, case .object(var merged) = base else {
                report(.invalidValue, path, "欄の名前をキーにしたオブジェクトであるべきところが\(diff.kindName)")
                return base
            }
            for name in changes.keys.sorted() {
                guard RuleSchema.presetDefaultFields.contains(name) else {
                    skipUnknown(name, changes[name]!, path, candidates: RuleSchema.presetDefaultFields)
                    continue
                }
                // null で既定を消せる(その欄を入れない)。
                if changes[name]! == .null { merged[name] = nil } else { merged[name] = changes[name]! }
                changedPaths.append("\(path).\(name)")
            }
            return .object(merged)
        case .readers:
            return applyReaders(diff, to: base, path)
        case .markers:
            return applyMarkers(diff, to: base, path)
        case .presets:
            guard let changes = diff.objectValue, case .object(var merged) = base else {
                report(.invalidValue, path, "プリセットの名前をキーにしたオブジェクトであるべきところが\(diff.kindName)")
                return base
            }
            for name in changes.keys.sorted() where checkPresetName(name, path) {
                if let current = merged[name] {
                    merged[name] = applyObject(changes[name]!, to: current, RuleSchema.presetNode, "\(path).\(name)")
                    continue
                }
                // 既定値に無い名前は、利用者の新しいプリセット。重ねる相手が無いので、全体を書く(`$add` などの操作は書けない)。
                let before = issues.count
                if changes[name]!["formats"]?.arrayValue == nil {
                    report(.invalidValue, "\(path).\(name)", "新しいプリセットは全体を書く({ \"formats\": [\"…\"] })。同梱のプリセットを変えるなら名前を確かめる",
                           suggestion: Spelling.suggestion(for: name, among: merged.keys.sorted()))
                } else {
                    checkPreset(changes[name]!, "\(path).\(name)")
                }
                guard issues.count == before else { continue }
                merged[name] = changes[name]!
                changedPaths.append("\(path).\(name)")
            }
            return .object(merged)
        }
    }

    mutating func applyObject(_ diff: JSONValue, to base: JSONValue, _ node: RuleSchema.Node, _ path: String,
                              extraAllowed: [String] = []) -> JSONValue {
        guard let changes = diff.objectValue, case .object(var merged) = base else {
            report(.invalidValue, path, "オブジェクトであるべきところが\(diff.kindName)")
            return base
        }
        var candidates = node.fields.map(\.name)
        if node.isRule { candidates += ["since", "required"] + (node.hasEnabled ? ["enabled"] : []) }
        for key in changes.keys.sorted() {
            let value = changes[key]!
            if key == "enabled", node.hasEnabled {
                if let current = merged["enabled"] { merged["enabled"] = apply(value, to: current, .bool, Self.join(path, key)) }
                continue
            }
            if key == "since" || key == "required", node.isRule { continue }
            if extraAllowed.contains(key) { continue }
            var name = key
            if node.field(name) == nil, let renamed = aliases[name], node.field(renamed) != nil { name = renamed }
            guard let field = node.field(name), let current = merged[name] ?? missingBase(field) else {
                skipUnknown(key, value, path, candidates: candidates)
                continue
            }
            merged[name] = apply(value, to: current, field.shape, Self.join(path, name))
        }
        return .object(merged)
    }

    /// 巻の読み手: `{ "roman": { "enabled": false }, "$order": ["ordinal", "number"] }`。
    mutating func applyReaders(_ diff: JSONValue, to base: JSONValue, _ path: String) -> JSONValue {
        guard let changes = diff.objectValue, var readers = base.arrayValue else {
            report(.invalidValue, path, "読み手の ID をキーにしたオブジェクトであるべきところが\(diff.kindName)")
            return base
        }
        let ids = readers.compactMap { $0["id"]?.stringValue }
        for key in changes.keys.sorted() where key != "$order" {
            var id = key
            if !ids.contains(id), let renamed = aliases[id], ids.contains(renamed) { id = renamed }
            guard let i = ids.firstIndex(of: id), let reader = RuleSchema.readerTypes.first(where: { $0.id == id }) else {
                skipUnknown(key, changes[key]!, path, candidates: ids + ["$order"])
                continue
            }
            let node = RuleSchema.Node(reader.fields, rule: true, enabled: true)
            if let o = changes[key]?.objectValue {
                if let t = o["type"], t.stringValue != reader.type { report(.invalidValue, "\(path).\(key).type", "読み手の種類は変えられない") }
                if let v = o["id"], v.stringValue != id { report(.invalidValue, "\(path).\(key).id", "ID は変えられない") }
            }
            readers[i] = applyObject(changes[key]!, to: readers[i], node, "\(path).\(id)", extraAllowed: ["id", "type"])
        }
        if let order = changes["$order"] { applyOrder(order, to: &readers, path) }
        return .array(readers)
    }

    /// `$order`: 挙げた ID をこの順で先頭に寄せ、挙げなかったものは今の順で後ろに続ける(巻の読み手と語の規則で同じ)。
    mutating func applyOrder(_ order: JSONValue, to items: inout [JSONValue], _ path: String) {
        guard let wanted = order.arrayValue?.compactMap(\.stringValue), wanted.count == order.arrayValue?.count else {
            report(.invalidValue, "\(path).$order", "ID の配列であるべきところ")
            return
        }
        let ids = items.compactMap { $0["id"]?.stringValue }
        var front: [JSONValue] = []
        for (i, raw) in wanted.enumerated() {
            let id = ids.contains(raw) ? raw : (aliases[raw] ?? raw)
            if front.contains(where: { $0["id"]?.stringValue == id }) {
                report(.duplicateID, "\(path).$order[\(i)]", raw)
            } else if let item = items.first(where: { $0["id"]?.stringValue == id }) {
                front.append(item)
            } else if retiredIDs.contains(raw) {
                report(.retiredID, "\(path).$order[\(i)]", raw)
            } else {
                report(.unknownKey, "\(path).$order[\(i)]", raw, suggestion: Spelling.suggestion(for: raw, among: ids))
            }
        }
        let reordered = front + items.filter { r in !front.contains { $0["id"] == r["id"] } }
        if reordered != items { changedPaths.append("\(path).$order") }
        items = reordered
    }

    /// 語の規則: `{ "plain": { "enabled": false }, "my-guide": { "treat": "keep", "words": ["…"] }, "$order": [...] }`。
    /// 同梱に無い ID は、利用者の新しい規則(全体を書く。要るのは `treat`)。**新しい規則は並びの先頭に入る**
    /// (例外は、守りたい規則より上に置くものだから)。別の位置に置くなら `$order` で並べる。
    mutating func applyMarkers(_ diff: JSONValue, to base: JSONValue, _ path: String) -> JSONValue {
        guard let changes = diff.objectValue, var rules = base.arrayValue else {
            report(.invalidValue, path, "規則の ID をキーにしたオブジェクトであるべきところが\(diff.kindName)")
            return base
        }
        var added: [JSONValue] = []
        for key in changes.keys.sorted() where key != "$order" {
            let ids = rules.compactMap { $0["id"]?.stringValue }
            var id = key
            if !ids.contains(id), let renamed = aliases[id], ids.contains(renamed) { id = renamed }
            if let i = ids.firstIndex(of: id) {
                if let v = changes[key]?["id"], v.stringValue != id { report(.invalidValue, "\(path).\(key).id", "ID は変えられない") }
                rules[i] = applyObject(changes[key]!, to: rules[i], RuleSchema.markerNode, "\(path).\(id)", extraAllowed: ["id"])
                continue
            }
            // 廃止した ID と、本体の知らない新しい版の規則は、警告で読み飛ばす。
            let value = changes[key]!
            if retiredIDs.contains(key) || (value["since"]?.intValue).map({ $0 > engineLevel }) == true {
                skipUnknown(key, value, path, candidates: ids)
                continue
            }
            guard checkRuleID(key, "\(path).\(key)"), var fresh = value.objectValue, fresh["treat"] != nil else {
                report(.invalidValue, "\(path).\(key)", "新しい規則は全体を書く({ \"treat\": \"keep\", \"words\": [\"…\"] })。同梱の規則を変えるなら ID を確かめる",
                       suggestion: Spelling.suggestion(for: key, among: ids))
                continue
            }
            fresh["id"] = .string(key)
            fresh["enabled"] = fresh["enabled"] ?? .bool(true)
            fresh["words"] = fresh["words"] ?? .array([])
            fresh["patterns"] = fresh["patterns"] ?? .array([])
            let before = issues.count
            check(.object(fresh), .object(RuleSchema.markerNode), "\(path).\(key)", full: true, ignoring: ["id"])
            guard issues.count == before else { continue }
            added.append(.object(fresh))
            changedPaths.append("\(path).\(key)")
        }
        rules = added + rules
        if let order = changes["$order"] { applyOrder(order, to: &rules, path) }
        return .array(rules)
    }

    /// プロファイル: `{ "doujinshi": { "formats": { "$add": [...], "at": "end" } } }`。
    /// 一覧への操作。配列は `$add`・`$remove`・`$replace`、対応表は `$set`・`$unset`・`$replace`。
    mutating func applyListOps(_ diff: JSONValue, to base: JSONValue, _ kind: RuleSchema.ListKind, _ path: String) -> JSONValue {
        switch kind {
        case .characters, .words:
            return applyArrayOps(diff, to: base, path, allowsAt: false) { this, item, p in this.checkListItem(item, kind, p) }
        case .pairs:
            guard let ops = diff.objectValue else {
                report(.invalidValue, path, "差分では { \"$set\": {...}, \"$unset\": [...] } か { \"$replace\": {...} } で書く")
                return base
            }
            let allowed = ["$set", "$unset", "$replace"]
            guard checkOps(ops, allowed: allowed, path) else { return base }
            if let replacement = ops["$replace"] {
                let before = issues.count
                checkListValue(replacement, .pairs, "\(path).$replace")
                guard issues.count == before else { return base }
                if replacement != base { changedPaths.append(path) }
                return replacement
            }
            guard var map = base.objectValue else { return base }
            let original = map
            if let set = ops["$set"] {
                let before = issues.count
                checkListValue(set, .pairs, "\(path).$set")
                if issues.count == before, let s = set.objectValue { map.merge(s) { _, new in new } }
            }
            if let unset = ops["$unset"] {
                if let keys = unset.arrayValue?.compactMap(\.stringValue), keys.count == unset.arrayValue?.count {
                    for k in keys { map[k] = nil }
                } else {
                    report(.invalidValue, "\(path).$unset", "キーの配列であるべきところ")
                }
            }
            if map != original { changedPaths.append(path) }
            return .object(map)
        }
    }

    /// 配列への `$add`・`$remove`・`$replace`。`allowsAt` なら `$add` の位置を `"at": "start" | "end"` で選べる(既定は先頭)。
    /// `identity` は、2 つの項目が同じものかを見る鍵(既定は値そのもの)。
    mutating func applyArrayOps(_ diff: JSONValue, to base: JSONValue, _ path: String, allowsAt: Bool,
                                identity: (JSONValue) -> JSONValue = { $0 },
                                checkItem: (inout RuleLoader, JSONValue, String) -> Void) -> JSONValue {
        guard let ops = diff.objectValue else {
            report(.invalidValue, path, "差分では { \"$add\": [...], \"$remove\": [...] } か { \"$replace\": [...] } で書く"
                   + "(配列をそのまま書くと既定の語がすべて消えるので、置き換えるときは $replace と書く)")
            return base
        }
        let allowed = ["$add", "$remove", "$replace"] + (allowsAt ? ["at"] : [])
        guard checkOps(ops, allowed: allowed, path) else { return base }
        func items(_ key: String) -> [JSONValue]? {
            guard let v = ops[key] else { return nil }
            guard let a = v.arrayValue else {
                report(.invalidValue, "\(path).\(key)", "配列であるべきところが\(v.kindName)")
                return nil
            }
            if a.count > Limits.items { report(.tooLarge, "\(path).\(key)", "\(a.count) 件") }
            let before = issues.count
            for (i, item) in a.enumerated() { checkItem(&self, item, "\(path).\(key)[\(i)]") }
            return issues.count == before ? a : nil
        }
        if ops["$replace"] != nil {
            guard let replacement = items("$replace") else { return base }
            if .array(replacement) != base { changedPaths.append(path) }
            return .array(replacement)
        }
        guard var current = base.arrayValue else { return base }
        let original = current
        if let removed = items("$remove")?.map(identity) { current.removeAll { removed.contains(identity($0)) } }
        if let added = items("$add") {
            let present = current.map(identity), keys = added.map(identity)
            let fresh = added.enumerated().filter { i, _ in !present.contains(keys[i]) && !keys[..<i].contains(keys[i]) }.map(\.element)
            var atEnd = false
            if let at = ops["at"] {
                switch at.stringValue {
                case "start": atEnd = false
                case "end": atEnd = true
                default: report(.invalidValue, "\(path).at", "\"start\" か \"end\"")
                }
            }
            current = atEnd ? current + fresh : fresh + current
        }
        if current.count > Limits.items { report(.tooLarge, path, "\(current.count) 件") }
        if current != original { changedPaths.append(path) }
        return .array(current)
    }

    mutating func checkOps(_ ops: [String: JSONValue], allowed: [String], _ path: String) -> Bool {
        var ok = true
        for key in ops.keys.sorted() where !allowed.contains(key) {
            if key == "since" || key == "required" { continue }
            report(.unknownKey, Self.join(path, key), suggestion: Spelling.suggestion(for: key, among: allowed))
            ok = false
        }
        if ops["$replace"] != nil, ops.keys.contains(where: { $0 != "$replace" && $0.hasPrefix("$") }) {
            report(.invalidValue, path, "$replace はほかの操作と一緒に書けない")
            ok = false
        }
        return ok
    }
}
