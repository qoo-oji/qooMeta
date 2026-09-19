import Foundation

/// 例のファイル(`qoometa.examples`)。規則と一緒に持ち運ぶ確認手段(docs/rules-format-design.md「例のファイル」)。
///
/// 規則や処理を変える前に、確かめたい形をここへ足す。手元の蔵書での確認はこのマシンでしかできないが、例のファイルは
/// リポジトリに入り、CI でも、利用者の手元でも同じように走る。**例には架空の名前だけを書く**(公開するファイル)。
public struct ExampleFile: Sendable {
    public static let kind = "qoometa.examples"
    public static let supportedSchemaVersion = 2

    /// ファイル全体の本の種別の語彙(例ごとに上書きできる)。
    public var genres: [String]
    public var examples: [Example]

    /// 同梱の例(Resources/examples.json)。
    public static func bundled() throws -> ExampleFile {
        guard let url = Bundle.module.url(forResource: "examples", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "examples", withExtension: "json") else {
            throw RulesIssue(.missingKey, source: "examples", at: "", "同梱の examples.json")
        }
        return try load(Data(contentsOf: url)).get()
    }

    /// 読んで検証する。誤りは最初の 1 件で止めず、すべて集めて返す。
    public static func load(_ data: Data) -> Result<ExampleFile, RulesIssues> {
        let root: JSONValue
        do { root = try JSONValue.parse(data, source: "examples") } catch {
            return .failure(RulesIssues([error]))
        }
        var reader = ExampleReader()
        let file = reader.file(root)
        if let file, reader.issues.isEmpty { return .success(file) }
        return .failure(RulesIssues(reader.issues))
    }
}

public struct Example: Sendable {
    public var id: String
    public var books: [ExampleBook]
    /// `books` と同じ順。書いた項目だけを確かめる。
    public var expectations: [Expectation]
    /// この例が確かめる規則の ID(規則を止めたときに壊れる例が分かるように)。
    public var covers: [String]
    /// 本の種別の語彙(書いてあればファイル全体の既定を置き換える)。
    public var genres: [String]?
    /// この例で選ぶ方針(書いた方針だけを、渡された規則の上で置き換える)。
    public var policies: [String: String] = [:]
}

public struct ExampleBook: Sendable {
    /// 拡張子を除いたファイル名。
    public var name: String
    /// 入っているフォルダ(外側から)。サークルの無い名前は、いちばん内側のフォルダが書き手になる。
    public var folders: [String]
}

public struct Expectation: Sendable {
    /// 確かめられる項目。
    public enum Field: String, CaseIterable, Sendable {
        case series, volume, volumeSort, inferred, circle, authors, title, relation, genre, event, editions, sources
    }

    /// 書いた順に確かめる。`"series": null` は「シリーズに入ってはいけない」。
    public var checks: [(field: Field, value: JSONValue)]
}

/// 例のファイルの読み手。道筋(`examples[2].expect[0]`)を付けて誤りを集める。
struct ExampleReader {
    var issues: [RulesIssue] = []

    mutating func error(_ path: String, _ code: RulesIssue.Code, _ detail: String? = nil, suggestion: String? = nil) {
        issues.append(RulesIssue(code, source: "examples", at: path, detail, suggestion: suggestion))
    }

    /// 知らないキーを誤りにする(読み飛ばすと、書き間違えた期待値が黙って確かめられなくなる)。
    mutating func object(_ value: JSONValue, _ path: String, allowed: [String]) -> [String: JSONValue]? {
        guard case .object(let o) = value else {
            error(path, .invalidValue, "オブジェクトであるべきところが\(value.kindName)")
            return nil
        }
        for key in o.keys.sorted() where !allowed.contains(key) {
            error(join(path, key), .unknownKey, suggestion: Spelling.suggestion(for: key, among: allowed))
        }
        return o
    }

    mutating func string(_ value: JSONValue?, _ path: String) -> String? {
        guard let value else { error(path, .missingKey); return nil }
        guard case .string(let s) = value else { error(path, .invalidValue, "文字列であるべきところが\(value.kindName)"); return nil }
        return s
    }

    mutating func strings(_ value: JSONValue?, _ path: String) -> [String]? {
        guard let value else { return nil }
        guard case .array(let items) = value else { error(path, .invalidValue, "文字列の配列であるべきところが\(value.kindName)"); return nil }
        return items.enumerated().compactMap { string($0.element, "\(path)[\($0.offset)]") }
    }

    func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    mutating func file(_ root: JSONValue) -> ExampleFile? {
        guard let o = object(root, "", allowed: ["$schema", "kind", "schemaVersion", "revision", "vocabulary", "examples"])
        else { return nil }
        if let kind = string(o["kind"], "kind"), kind != ExampleFile.kind {
            error("kind", .wrongKind, kind)
        }
        switch o["schemaVersion"] {
        case .number(let v) where v == Double(ExampleFile.supportedSchemaVersion): break
        case .number(let v): error("schemaVersion", .unsupportedSchemaVersion, JSONValue.number(v).rendered())
        case nil: error("schemaVersion", .missingKey)
        case let v?: error("schemaVersion", .invalidValue, "数であるべきところが\(v.kindName)")
        }
        let genres = o["vocabulary"].flatMap { vocabulary($0, "vocabulary") } ?? []
        guard case .array(let items)? = o["examples"] else {
            if o["examples"] == nil { error("examples", .missingKey) } else { error("examples", .invalidValue, "配列であるべきところ") }
            return nil
        }
        var seen = Set<String>()
        var examples: [Example] = []
        for (i, item) in items.enumerated() {
            let path = "examples[\(i)]"
            guard let e = example(item, path) else { continue }
            if !seen.insert(e.id).inserted { error("\(path).id", .duplicateID, e.id) }
            examples.append(e)
        }
        return ExampleFile(genres: genres, examples: examples)
    }

    mutating func vocabulary(_ value: JSONValue, _ path: String) -> [String]? {
        guard let o = object(value, path, allowed: ["genres"]) else { return nil }
        return strings(o["genres"], join(path, "genres")) ?? []
    }

    mutating func example(_ value: JSONValue, _ path: String) -> Example? {
        guard let o = object(value, path, allowed: ["id", "files", "expect", "covers", "vocabulary", "policies"]) else { return nil }
        let id = string(o["id"], join(path, "id")) ?? ""
        if id.isEmpty, o["id"] != nil { error(join(path, "id"), .invalidValue, "空の ID") }

        var books: [ExampleBook] = []
        if case .array(let files)? = o["files"], !files.isEmpty {
            for (i, f) in files.enumerated() {
                let p = "\(path).files[\(i)]"
                switch f {
                case .string(let name): books.append(ExampleBook(name: name, folders: []))
                case .object:
                    guard let b = object(f, p, allowed: ["name", "folders"]), let name = string(b["name"], "\(p).name")
                    else { continue }
                    books.append(ExampleBook(name: name, folders: strings(b["folders"], "\(p).folders") ?? []))
                default: error(p, .invalidValue, "文字列か { \"name\": …, \"folders\": […] } であるべきところが\(f.kindName)")
                }
            }
        } else {
            error(join(path, "files"), .invalidValue, "本の名前の配列(1 冊以上)が必要")
        }

        var expectations: [Expectation] = []
        if case .array(let items)? = o["expect"] {
            if items.count != books.count, !books.isEmpty {
                error(join(path, "expect"), .invalidValue, "files と同じ数の期待値が必要(files \(books.count)、expect \(items.count))")
            }
            for (i, item) in items.enumerated() {
                if let e = expectation(item, "\(path).expect[\(i)]") { expectations.append(e) }
            }
        } else {
            error(join(path, "expect"), .invalidValue, "期待値の配列が必要")
        }

        let covers = strings(o["covers"], join(path, "covers")) ?? []
        for (i, rule) in covers.enumerated() where !KnownRuleIDs.all.contains(rule) {
            error("\(path).covers[\(i)]", .unknownKey, rule, suggestion: Spelling.suggestion(for: rule, among: KnownRuleIDs.all))
        }
        let genres = o["vocabulary"].flatMap { vocabulary($0, join(path, "vocabulary")) }
        var policies: [String: String] = [:]
        if let p = o["policies"] {
            let names = RuleSchema.policies.map(\.name)
            if let map = object(p, join(path, "policies"), allowed: names) {
                for (name, v) in map.sorted(by: { $0.key < $1.key }) {
                    guard let choices = RuleSchema.policies.first(where: { $0.name == name })?.choices else { continue }
                    let place = join(join(path, "policies"), name)
                    if let choice = string(v, place) {
                        if choices.contains(choice) { policies[name] = choice }
                        else { error(place, .invalidValue, choice, suggestion: Spelling.suggestion(for: choice, among: choices)) }
                    }
                }
            }
        }
        return Example(id: id, books: books, expectations: expectations, covers: covers, genres: genres, policies: policies)
    }

    mutating func expectation(_ value: JSONValue, _ path: String) -> Expectation? {
        guard let o = object(value, path, allowed: Expectation.Field.allCases.map(\.rawValue)) else { return nil }
        var checks: [(Expectation.Field, JSONValue)] = []
        for field in Expectation.Field.allCases {
            guard let v = o[field.rawValue] else { continue }
            let p = join(path, field.rawValue)
            switch (field, v) {
            case (.inferred, .bool), (.volumeSort, .number), (.volumeSort, .null): break
            case (.authors, .array(let a)), (.editions, .array(let a)), (.sources, .array(let a)):
                _ = strings(.array(a), p)
            // 文字列の項目の null は「空であること」(`"series": null` は「シリーズに入ってはいけない」)。
            case (.series, .string), (.series, .null), (.volume, .string), (.volume, .null),
                 (.circle, .string), (.circle, .null), (.title, .string), (.title, .null),
                 (.relation, .string), (.relation, .null), (.genre, .string), (.genre, .null),
                 (.event, .string), (.event, .null):
                break
            default:
                error(p, .invalidValue, "この項目に\(v.kindName)は書けない")
                continue
            }
            checks.append((field, v))
        }
        return Expectation(checks: checks)
    }
}

/// 例を今の規則で処理し、期待値と比べる。
public enum ExampleRunner {
    public struct Outcome: Sendable {
        public var id: String
        public var covers: [String]
        /// 食い違い(空なら通った)。例は架空の名前だけなので、名前をそのまま含めてよい。
        public var mismatches: [String]
        public var passed: Bool { mismatches.isEmpty }
    }

    /// - Parameter engine: 例を確かめる規則(既定値、または利用者の変更を重ねたもの)。例が方針を書いていれば、その上で置き換える。
    public static func run(_ file: ExampleFile, engine: RuleEngine = .builtin) throws -> [Outcome] {
        var engines: [[String: String]: RuleEngine] = [[:]: engine]
        var parsers: [String: QooLibraryNameParser] = [:]
        return try file.examples.map { example in
            if engines[example.policies] == nil {
                let compilation = engine.rules.applying(policies: example.policies)
                guard let rules = compilation.rules else {
                    return Outcome(id: example.id, covers: example.covers,
                                   mismatches: compilation.errors.map { "方針を選べない: \($0)" })
                }
                engines[example.policies] = RuleEngine(rules: rules, englishWords: engine.english)
            }
            let exampleEngine = engines[example.policies]!
            let genres = example.genres ?? file.genres
            let parserKey = genres.joined(separator: "\u{1}") + "\u{2}" + exampleEngine.rules.contentHash
            if parsers[parserKey] == nil {
                parsers[parserKey] = try QooLibraryNameParser(mediaTypes: genres, rules: exampleEngine.rules.formats)
            }
            let books = propose(example.books, parser: parsers[parserKey]!, engine: exampleEngine)
            var mismatches: [String] = []
            for (i, expectation) in example.expectations.enumerated() where i < books.count {
                for (field, expected) in expectation.checks {
                    let actual = value(of: field, in: books[i])
                    if !matches(actual, expected) {
                        mismatches.append("\(i + 1) 冊目「\(example.books[i].name)」の \(field.rawValue): "
                                          + "期待 \(show(expected))、結果 \(show(actual))")
                    }
                }
            }
            return Outcome(id: example.id, covers: example.covers, mismatches: mismatches)
        }
    }

    /// CLI の scan と同じ流れ(ファイル名の解析 → 組 → 巻)を、規則だけで通す(端末内モデルは使わない)。
    static func propose(_ books: [ExampleBook], parser: QooLibraryNameParser, engine: RuleEngine) -> [BookProposal] {
        let files = books.enumerated().map { i, book in
            let relative = (book.folders + [book.name + ".cbz"]).joined(separator: "/")
            return BookFile(path: "/example/\(i + 1)/" + relative, relativePath: relative, baseName: book.name,
                            fileExtension: "cbz")
        }
        let proposals = BookScanner.proposals(from: files, qooLibrary: parser, engine: engine)
        let grouper = SeriesGrouper(engine: engine)
        var doc = ProposalDocument(rootPath: "/example", minPrefix: grouper.minPrefix, books: proposals,
                                   groups: grouper.group(proposals))
        ProposalFinalizer.finalize(&doc, useAI: false, engine: engine)
        return doc.books
    }

    /// 結果の値を、期待値と同じ形(空は null)にする。
    static func value(of field: Expectation.Field, in book: BookProposal) -> JSONValue {
        func text(_ s: String?) -> JSONValue { (s ?? "").isEmpty ? .null : .string(s!) }
        func list(_ a: [String]?) -> JSONValue { .array((a ?? []).map(JSONValue.string)) }
        switch field {
        case .series: return text(book.series)
        case .volume: return text(book.volumeText)
        case .volumeSort: return book.volumeNumber.map(JSONValue.number) ?? .null
        case .inferred: return .bool(book.volumeInferred == true)
        case .circle: return text(book.parsed.circle)
        case .authors: return list(book.parsed.authors)
        case .title: return text(book.parsed.title)
        case .relation: return text(book.parsed.trailing)
        case .genre: return text(book.parsed.mediaType)
        case .event: return text(book.parsed.event)
        case .editions: return list(book.parsed.editions)
        case .sources: return list(book.parsed.sources)
        }
    }

    /// 文字列は正規化の違い(合成済みかどうか)を問わない。数は並べ替え用の値なので、小数の誤差を許す。
    static func matches(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        switch (actual, expected) {
        case (.string(let a), .string(let e)): a.precomposedStringWithCanonicalMapping == e.precomposedStringWithCanonicalMapping
        case (.number(let a), .number(let e)): abs(a - e) < 1e-9
        case (.array(let a), .array(let e)): a.count == e.count && zip(a, e).allSatisfy { matches($0, $1) }
        case (.null, .string(let e)): e.isEmpty
        default: actual == expected
        }
    }

    static func show(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): "\"\(s)\""
        case .array(let a): "[" + a.map(show).joined(separator: ", ") + "]"
        case .object: "{…}"
        }
    }
}
