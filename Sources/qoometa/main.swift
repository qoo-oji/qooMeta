import Foundation
import QooMetaAI
import QooMetaCore

// qoometa — ファイル名の一覧から蔵書のメタデータを提案する。
//
// **標準出力には集計だけを出し、蔵書の名前は出さない。** 名前を含む生成物(提案ファイル・見直し表・
// 書き出し)はすべて --out で指定したファイルへ書き、Git の作業ツリーの中へは書かない。

let usage = """
使い方:
  qoometa scan <フォルダ> --out <提案.json> [--min-prefix N]
      (ファイル名は qooLibrary の同人誌のフォーマットで読む。本の種別の語彙は config.json の mediaTypes。
       本の種別が違う本は同じシリーズにしない)
      書庫ファイルを集め、名前を解析し、規則でシリーズ候補を作る
  qoometa judge --in <提案.json> [--out <提案.json>] [--limit N]
      シリーズ候補を端末内モデル(Apple Intelligence)で判定する
  qoometa stats --in <提案.json> [--rules-only]
      集計を表示する(名前は出さない)
  qoometa report --in <提案.json> --out <見直し表.html>
      手元で開く見直し表を書く(名前を含む)
  qoometa export --in <提案.json> --format stackroom|qooviewer --out <ファイル> [--book-type N] [--rules-only]
      StackNest が取り込める Stackroom XML、または qooViewer の保存データ JSON を書く
  qoometa series-list --in <提案.json> --out <一覧.csv> [--rules-only] [--exclude-from <以前の一覧.csv>]
      シリーズが付いた本の一覧を CSV で書く(名前を含む)
  qoometa evaluate --corpus <正解付き.jsonl>
      正解付きのデータ(author / title / series)で候補づくりを採点する
  qoometa rules test [<例.json> …] [--only <例の ID>] [--verbose]
      例のファイル(架空の名前)を今の規則で処理し、期待値と比べる。ファイルを省くと同梱の例
  qoometa rules validate <規則.json>
      規則ファイル(差分、rules-bundle、または既定値の全体)を確かめ、誤りと警告をすべて出す
  qoometa rules show
      既定値に利用者の変更を重ねた結果と、変更が効いている所を出す

どのコマンドにも --rules <変更.json> を付けられる(既定値に重ねる利用者の変更。差分か rules-bundle)。
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if ["rules-only", "allow-in-repo", "verbose"].contains(name) {
                    flags.insert(name)
                } else if i + 1 < raw.count {
                    options[name] = raw[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func require(_ name: String) throws -> String {
        guard let v = options[name] else { throw CLIError("--\(name) が必要です") }
        return v
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// 名前を含むファイルを Git の作業ツリーの中へ書かせない(リポジトリへ紛れ込む事故を防ぐ)。
func checkedOutputURL(_ path: String, _ args: Arguments) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard !args.flags.contains("allow-in-repo") else { return url }
    var dir = url.deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            throw CLIError("Git の作業ツリーの中へは書きません(蔵書の名前を含むため): 出力先を変えてください")
        }
        dir = dir.deletingLastPathComponent()
    }
    return url
}

/// 利用者ごとの設定。**蔵書の言葉(本の種別の名前など)を含むので、リポジトリの外に置く**
/// (`~/Library/Application Support/qooMeta-dev/config.json`)。
struct Config: Decodable {
    /// 本の種別(`@mediatype`)の語彙。ファイル名の先頭の丸括弧がこのどれかなら本の種別、そうでなければイベント。
    var mediaTypes: [String]?

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/qooMeta-dev/config.json")

    static func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
}

func load(_ path: String) throws -> ProposalDocument {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProposalDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func save(_ doc: ProposalDocument, _ url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(doc).write(to: url, options: .atomic)
}

func run() async throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else { print(usage); return }
    let args = Arguments(Array(raw.dropFirst()))
    // 規則: 同梱の既定値に、利用者の変更(--rules)を重ねたもの。処理の各所へ値で渡す。
    var engine = RuleEngine.builtin
    if let path = args.options["rules"] {
        engine = RuleEngine(rules: try compileRules(userChanges: Data(contentsOf: URL(fileURLWithPath: path))),
                            englishWords: .system)
    }

    switch command {
    case "scan":
        guard let root = args.positional.first else { throw CLIError("フォルダを指定してください") }
        let out = try checkedOutputURL(try args.require("out"), args)
        let minPrefix = Int(args.options["min-prefix"] ?? "") ?? 4
        let files = try BookScanner.scan(root: URL(fileURLWithPath: root))
        // ファイル名は qooLibrary のフォーマット処理(同人誌のプリセット)で読む。一致しなければ qooMeta 自身の解析へ戻す。
        // 本の種別の語彙は利用者の設定から(リポジトリに置けない語なので)。
        let config = try Config.load()
        if config.mediaTypes?.isEmpty ?? true {
            FileHandle.standardError.write(Data("注意: 本の種別の語彙が設定に無いので、先頭の丸括弧はイベントとして読みます(\(Config.url.path) の mediaTypes)\n".utf8))
        }
        let books = BookScanner.proposals(
            from: files, qooLibrary: try QooLibraryNameParser(mediaTypes: config.mediaTypes ?? [], rules: engine.rules.formats),
            engine: engine)
        print("qooLibrary のフォーマットで読めた: \(books.filter { $0.parsed.mediaType != nil }.count) 冊(本の種別あり \(books.filter { !($0.parsed.mediaType ?? "").isEmpty }.count))")
        let groups = SeriesGrouper(engine: engine, minPrefix: minPrefix).group(books)
        var doc = ProposalDocument(rootPath: URL(fileURLWithPath: root).standardizedFileURL.path,
                                   minPrefix: minPrefix, books: books, groups: groups)
        ProposalFinalizer.finalize(&doc, engine: engine)
        try save(doc, out)
        StatsReport.lines(doc, engine: engine).forEach { print($0) }

    case "judge":
        let input = try args.require("in")
        let out = try checkedOutputURL(args.options["out"] ?? input, args)
        guard SeriesJudge.isAvailable else {
            throw CLIError("端末内モデルを使えません: \(SeriesJudge.availability)")
        }
        var doc = try load(input)
        let limit = Int(args.options["limit"] ?? "") ?? Int.max
        let titles = Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, $0.parsed.title) })
        let judge = SeriesJudge()
        var done = 0
        for i in doc.groups.indices where doc.groups[i].aiVerdict == nil && done < limit {
            do {
                doc.groups[i].aiVerdict = try await judge.judge(group: doc.groups[i], titlesByID: titles)
                doc.groups[i].aiError = nil
            } catch {
                doc.groups[i].aiError = SeriesJudge.describe(error)
            }
            done += 1
            if done % 20 == 0 {
                FileHandle.standardError.write(Data("  \(done) 組を判定\n".utf8))
                try save(doc, out)  // 途中で止めても、そこまでの判定は残す
            }
        }
        ProposalFinalizer.finalize(&doc, engine: engine)
        try save(doc, out)
        StatsReport.lines(doc, engine: engine).forEach { print($0) }

    case "stats":
        var doc = try load(try args.require("in"))
        ProposalFinalizer.finalize(&doc, useAI: !args.flags.contains("rules-only"), engine: engine)
        StatsReport.lines(doc, engine: engine).forEach { print($0) }

    case "report":
        var doc = try load(try args.require("in"))
        ProposalFinalizer.finalize(&doc, engine: engine)
        let out = try checkedOutputURL(try args.require("out"), args)
        try ReviewReport.html(doc).write(to: out, atomically: true, encoding: .utf8)
        print("見直し表を書きました(\(doc.groups.count) 組)")

    case "export":
        var doc = try load(try args.require("in"))
        ProposalFinalizer.finalize(&doc, useAI: !args.flags.contains("rules-only"), engine: engine)
        let out = try checkedOutputURL(try args.require("out"), args)
        switch try args.require("format") {
        case "stackroom":
            let bookType = Int(args.options["book-type"] ?? "") ?? 0
            try StackroomExporter.write(doc, to: out, options: .init(bookType: bookType))
        case "qooviewer":
            try QooViewerExporter.write(doc, to: out)
        default:
            throw CLIError("--format は stackroom か qooviewer")
        }
        print("書き出しました: \(doc.books.count) 冊(シリーズ付き \(doc.books.filter { !$0.series.isEmpty }.count))")

    case "series-list":
        var doc = try load(try args.require("in"))
        ProposalFinalizer.finalize(&doc, useAI: !args.flags.contains("rules-only"), engine: engine)
        let out = try checkedOutputURL(try args.require("out"), args)
        // --exclude-from <以前の一覧.csv>: そこに載っているファイル名の本は出さない。
        var excluded = Set<String>()
        if let previous = args.options["exclude-from"] {
            excluded = SeriesListExporter.fileNames(inList: try String(contentsOfFile: previous, encoding: .utf8))
        }
        let csv = SeriesListExporter.csv(doc, excludingFileNames: excluded)
        try csv.write(to: out, atomically: true, encoding: .utf8)
        let written = doc.books.filter {
            !$0.series.isEmpty && !excluded.contains(($0.file.relativePath as NSString).lastPathComponent.precomposedStringWithCanonicalMapping)
        }
        print("シリーズの一覧を書きました: \(Set(written.compactMap(\.groupID)).count) シリーズ / \(written.count) 冊"
              + (excluded.isEmpty ? "" : "(以前の一覧の \(excluded.count) 件の名前と一致した \(doc.books.filter { !$0.series.isEmpty }.count - written.count) 冊を除いた)"))

    case "evaluate":
        // 正解付きのデータ(1 行 1 冊の JSON)で候補づくりを採点する。出すのは集計だけ。
        let labeled = try Evaluator.load(URL(fileURLWithPath: try args.require("corpus")))
        let namings: [(String, (SeriesGroup) -> String)] = [
            ("共通部分そのまま", { $0.ruleName }),
            ("最初の区切りで切る", { SeriesNaming.firstCut($0.ruleName, engine: engine) }),
        ]
        print("本 \(labeled.count) 冊")
        // --examples N: 誤りの例を出す。**公開データの分析専用**(蔵書から作ったデータには使わない)。
        if let ex = Int(args.options["examples"] ?? "") {
            let s = Evaluator.score(labeled, grouper: SeriesGrouper(engine: engine, minPrefix: 4), examples: ex)
            print("--- 誤って同じ組にした例")
            for (a, b) in s.falsePairs { print("[\(a.author)] \(a.title)〔\(a.series)〕 / \(b.title)〔\(b.series)〕") }
            print("--- 取りこぼした例")
            for (a, b) in s.missedPairs { print("[\(a.author)] \(a.title)〔\(a.series)〕 / \(b.title)〔\(b.series)〕") }
            return
        }
        for single in [true, false] {
          for n in [4] {
            for (label, naming) in namings.prefix(1) {
                var grouper = SeriesGrouper(engine: engine, minPrefix: n)
                grouper.rejectsCommonEnglishTitles = single
                let s = Evaluator.score(labeled, grouper: grouper, nameFor: naming)
                print(String(format: "一般英語だけのタイトルを%@ n=%d %@: 適合率 %.3f 再現率 %.3f(正解の組 %d、候補の組 %d)名前一致 %d/%d",
                             single ? "除く" : "許す", n, label, s.precision, s.recall, s.truePairs, s.predictedPairs,
                             s.nameMatches, s.namedBooks))
            }
          }
        }

    case "rules":
        switch args.positional.first {
        case "test":
            try testExamples(paths: Array(args.positional.dropFirst()), only: args.options["only"],
                             verbose: args.flags.contains("verbose"), engine: engine)
        case "validate":
            guard let path = args.positional.dropFirst().first else { throw CLIError("確かめる規則ファイルを指定してください") }
            try validateRules(Data(contentsOf: URL(fileURLWithPath: path)))
        case "show":
            let rules = engine.rules
            print("// シリーズの規則(qoometa.series-rules)")
            print(rules.mergedSeriesRules.rendered())
            print("// ファイル名のフォーマット(qoometa.filename-formats)")
            print(rules.mergedFilenameFormats.rendered())
            print("// 内容のハッシュ: \(rules.contentHash)")
            if rules.changedPaths.isEmpty {
                print("// 利用者の変更: なし(既定値のまま)")
            } else {
                print("// 利用者の変更が効いている所:")
                rules.changedPaths.forEach { print("//   \($0)") }
            }
        default:
            throw CLIError("rules のあとに test・validate・show のどれかを指定してください")
        }

    default:
        print(usage)
    }
}

/// 渡せる辞書(規則は辞書を名前で指す。ここでは macOS の英単語の一覧だけ)。
func availableDictionaries() -> Set<String> { EnglishWords.isAvailable ? ["english"] : [] }

func printIssues(_ issues: [RulesIssue]) {
    for issue in issues { FileHandle.standardError.write(Data("\(issue)\n".utf8)) }
}

/// 既定値に利用者の変更を重ねて組み立てる。警告は出して続け、誤りがあれば止める。
func compileRules(userChanges: Data) throws -> CompiledRules {
    let compilation = CompiledRules.compile(RuleSources(builtIn: try BuiltInRules.bundled(), userChanges: userChanges),
                                            dictionaries: availableDictionaries())
    printIssues(compilation.warnings)
    guard let rules = compilation.rules else {
        printIssues(compilation.errors)
        throw CLIError("規則の変更に誤りがある(\(compilation.errors.count) 件)")
    }
    return rules
}

/// 規則ファイルを確かめる。`"base": "builtin"` があれば差分(または rules-bundle)として既定値に重ね、
/// 無ければ既定値の全体(同梱の同じ種類のファイルの代わり)として確かめる。
func validateRules(_ data: Data) throws {
    var builtIn = try BuiltInRules.bundled()
    var userChanges: Data? = data
    if let root = try? JSONValue.parse(data, source: "user"), root["base"] == nil {
        switch root["kind"]?.stringValue {
        case "qoometa.series-rules": builtIn.seriesRules = data
        case "qoometa.filename-formats": builtIn.filenameFormats = data
        default: break
        }
        if builtIn.seriesRules == data || builtIn.filenameFormats == data { userChanges = nil }
    }
    let compilation = CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: userChanges),
                                            dictionaries: availableDictionaries())
    for issue in compilation.errors + compilation.warnings { print(issue) }
    print("誤り \(compilation.errors.count) 件、警告 \(compilation.warnings.count) 件"
          + (compilation.rules.map { "(内容のハッシュ \($0.contentHash))" } ?? ""))
    if compilation.rules == nil { exit(1) }
}

/// 例のファイルを走らせる。例は架空の名前だけなので、食い違いは名前ごと表示する。
/// 1 つでも通らなければ(読めない例のファイルを含む)終了コード 1。
func testExamples(paths: [String], only: String?, verbose: Bool, engine: RuleEngine) throws {
    var files: [(label: String, file: ExampleFile)] = []
    var broken = 0
    if paths.isEmpty {
        files.append(("同梱の例", try ExampleFile.bundled()))
    }
    for path in paths {
        switch ExampleFile.load(try Data(contentsOf: URL(fileURLWithPath: path))) {
        case .success(let file): files.append((path, file))
        case .failure(let issues):
            print("\(path): 読めない")
            issues.issues.forEach { print("  \($0)") }
            broken += 1
        }
    }
    var passed = 0, failed = 0
    for (label, var file) in files {
        if let only { file.examples = file.examples.filter { $0.id == only } }
        for outcome in try ExampleRunner.run(file, engine: engine) {
            if outcome.passed {
                passed += 1
                if verbose { print("ok    \(outcome.id)") }
            } else {
                failed += 1
                print("FAIL  \(outcome.id)(\(label))")
                outcome.mismatches.forEach { print("      \($0)") }
            }
        }
    }
    print("例: \(passed + failed) 件(通った \(passed)、通らなかった \(failed))" + (broken > 0 ? "、読めないファイル \(broken)" : ""))
    if failed > 0 || broken > 0 { exit(1) }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("エラー: \(error)\n".utf8))
    exit(1)
}
