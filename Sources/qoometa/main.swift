import Foundation
import QooMetaAI
import QooMetaExport
import QooMetaRules
import QooMetaScan
import QooMetaKit

// qoometa — ファイル名の一覧から蔵書のメタデータを提案する。
//
// **標準出力には集計だけを出し、蔵書の名前は出さない。** 名前を含む生成物(提案ファイル・見直し表・
// 書き出し)はすべて --out で指定したファイルへ書き、Git の作業ツリーの中へは書かない。

let usage = """
使い方:
  qoometa scan <フォルダ> --out <提案.json>
      書庫ファイルを集め、名前を解析し、規則でシリーズを提案する(集計を出す)
      (ファイル名は同人誌のフォーマットで読む。本の種別の語彙は config.json の mediaTypes)
  qoometa judge --in <提案.json> [--out <提案.json>] [--limit N]
      規則のシリーズを端末内モデル(Apple Intelligence)で判定する(macOS 26 以降)
  qoometa stats --in <提案.json> [--rules-only] [--explain]
      集計を表示する(名前は出さない)。--explain はシリーズにならなかった本を組にしなかった規則も数える
  qoometa report --in <提案.json> --out <見直し表.html> [--rules-only]
      手元で開く見直し表を書く(名前を含む)
  qoometa export --in <提案.json> --format stackroom|qooviewer --out <ファイル> [--book-type N] [--rules-only]
      StackNest が取り込める Stackroom XML、または qooViewer の保存データ JSON を書く
  qoometa series-list --in <提案.json> --out <一覧.csv> [--rules-only] [--exclude-from <以前の一覧.csv>]
      シリーズが付いた本の一覧を CSV で書く(名前を含む)
  qoometa formats --in <提案.json>
      同梱のファイル名フォーマット(新しい書き方)で名前を読み、型ごとの一致冊数と合わなかった冊数を出す(名前は出さない)
  qoometa bench --in <提案.json>
      一括の提案と、1 冊の追加・変更にかかる時間を測る(名前は出さない)
  qoometa evaluate --corpus <正解付き.jsonl> [--examples N]
      正解付きのデータ(author / title / series)で提案を採点する
  qoometa rules test [<例.json> …] [--only <例の ID>] [--verbose]
      例のファイル(架空の名前)を今の規則で処理し、期待値と比べる。ファイルを省くと同梱の例
  qoometa rules validate <規則.json>
      規則ファイル(差分、rules-bundle、または既定値の全体)を確かめ、誤りと警告をすべて出す
  qoometa rules show
      既定値に利用者の変更を重ねた結果と、変更が効いている所を出す

どのコマンドにも --rules <変更.json> を付けられる(既定値に重ねる利用者の変更。差分か rules-bundle)。
--rules-only は端末内モデルの判定を使わず、規則だけで提案する。
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
                if ["rules-only", "allow-in-repo", "verbose", "explain"].contains(name) {
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

func run() async throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else { print(usage); return }
    let args = Arguments(Array(raw.dropFirst()))
    // 規則: 同梱の既定値に、利用者の変更(--rules)を重ねたもの。
    var rules = CompiledRules.builtin
    if let path = args.options["rules"] {
        rules = try compileRules(userChanges: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    let useAI = !args.flags.contains("rules-only")

    switch command {
    case "scan":
        guard let root = args.positional.first else { throw CLIError("フォルダを指定してください") }
        let out = try checkedOutputURL(try args.require("out"), args)
        let proposer = try makeProposer(rules)
        let files = try FolderScanner.scan(root: URL(fileURLWithPath: root))
        let doc = ScanDocument(createdAt: Date(), rootPath: URL(fileURLWithPath: root).standardizedFileURL.path, files: files)
        try doc.save(out)
        StatsReport.lines(proposer.proposals(doc, useAI: false).final, doc: doc).forEach { print($0) }

    case "judge":
        let input = try args.require("in")
        let out = try checkedOutputURL(args.options["out"] ?? input, args)
        guard #available(macOS 26.0, *) else { throw CLIError("端末内モデルは macOS 26 以降で使えます") }
        guard SeriesJudge.isAvailable else {
            throw CLIError("端末内モデルを使えません: \(SeriesJudge.availability)")
        }
        var doc = try ScanDocument.load(input)
        let proposer = try makeProposer(rules)
        let set = proposer.proposals(doc, useAI: false).rulesOnly
        let limit = Int(args.options["limit"] ?? "") ?? Int.max
        let titles = Dictionary(set.proposals.map { ($0.id, $0.parsed.title) }, uniquingKeysWith: { a, _ in a })
        let done = Set(doc.judgements.filter { $0.verdict != nil }.map(\.memberIDs))
        let judge = SeriesJudge()
        var count = 0
        for series in set.series where !done.contains(series.memberIDs.sorted()) && count < limit {
            var judgement = ScanDocument.Judgement(memberIDs: series.memberIDs.sorted(), ruleName: series.name)
            do {
                judgement.verdict = try await judge.judge(series: series, titlesByID: titles)
            } catch {
                judgement.error = SeriesJudge.describe(error)
            }
            doc.judgements.removeAll { $0.memberIDs == judgement.memberIDs }
            doc.judgements.append(judgement)
            count += 1
            if count % 20 == 0 {
                FileHandle.standardError.write(Data("  \(count) 組を判定\n".utf8))
                try doc.save(out)  // 途中で止めても、そこまでの判定は残す
            }
        }
        try doc.save(out)
        StatsReport.lines(proposer.proposals(doc, useAI: true).final, doc: doc).forEach { print($0) }

    case "stats":
        let doc = try ScanDocument.load(try args.require("in"))
        var proposer = try makeProposer(rules)
        proposer.explanations = args.flags.contains("explain")
        StatsReport.lines(proposer.proposals(doc, useAI: useAI).final, doc: doc).forEach { print($0) }

    case "report":
        let doc = try ScanDocument.load(try args.require("in"))
        var proposer = try makeProposer(rules)
        proposer.explanations = true
        let (rulesOnly, set) = proposer.proposals(doc, useAI: useAI)
        let out = try checkedOutputURL(try args.require("out"), args)
        try ReviewReport.html(set, doc: doc, rulesOnly: rulesOnly).write(to: out, atomically: true, encoding: .utf8)
        print("見直し表を書きました(\(set.series.count) 組)")

    case "export":
        let doc = try ScanDocument.load(try args.require("in"))
        let set = try makeProposer(rules).proposals(doc, useAI: useAI).final
        let out = try checkedOutputURL(try args.require("out"), args)
        let data: Data
        switch try args.require("format") {
        case "stackroom":
            let files = Dictionary(doc.files.map { f in
                (f.relativePath, Exporter.FileFacts(path: f.path, fileExtension: f.fileExtension, dateAdded: f.created ?? f.modified))
            }, uniquingKeysWith: { a, _ in a })
            data = try Exporter.stackroomXML(set, files: files, options: .init(
                bookType: Int(args.options["book-type"] ?? "") ?? 0, defaultDateAdded: doc.createdAt))
        case "qooviewer":
            let identities = Dictionary(doc.files.map { f in
                (f.relativePath, Exporter.FileIdentity(path: f.path, inodeNumber: f.inodeNumber,
                                                       volumeDeviceNumber: f.volumeDeviceNumber, volumeUUID: f.volumeUUID))
            }, uniquingKeysWith: { a, _ in a })
            data = try Exporter.qooViewerJSON(set, identities: identities)
        default:
            throw CLIError("--format は stackroom か qooviewer")
        }
        try data.write(to: out, options: .atomic)
        print("書き出しました: \(set.proposals.count) 冊(シリーズ付き \(set.proposals.filter { $0.seriesID != nil }.count))")

    case "series-list":
        let doc = try ScanDocument.load(try args.require("in"))
        let set = try makeProposer(rules).proposals(doc, useAI: useAI).final
        let out = try checkedOutputURL(try args.require("out"), args)
        // --exclude-from <以前の一覧.csv>: そこに載っているファイル名の本は出さない。
        var excluded = Set<String>()
        if let previous = args.options["exclude-from"] {
            excluded = SeriesListCSV.fileNames(inList: try String(contentsOfFile: previous, encoding: .utf8))
        }
        let files = Dictionary(doc.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        try SeriesListCSV.csv(set, files: files, excluding: excluded).write(to: out, atomically: true, encoding: .utf8)
        let inSeries = set.proposals.filter { $0.seriesID != nil }
        let written = inSeries.filter { !excluded.contains(($0.id as NSString).lastPathComponent.precomposedStringWithCanonicalMapping) }
        print("シリーズの一覧を書きました: \(Set(written.compactMap(\.seriesID)).count) シリーズ / \(written.count) 冊"
              + (excluded.isEmpty ? "" : "(以前の一覧の \(excluded.count) 件の名前と一致した \(inSeries.count - written.count) 冊を除いた)"))

    case "formats":
        let doc = try ScanDocument.load(try args.require("in"))
        FormatReport.lines(doc.files.map(\.baseName), formats: .preset).forEach { print($0) }

    case "bench":
        let doc = try ScanDocument.load(try args.require("in"))
        try await bench(doc, proposer: try makeProposer(rules))

    case "evaluate":
        // 正解付きのデータ(1 行 1 冊の JSON)で提案を採点する。出すのは集計だけ。
        let labeled = Evaluator.parse(try String(contentsOfFile: try args.require("corpus"), encoding: .utf8))
        let vocabulary = Vocabulary(dictionaries: SystemDictionaries.all)
        print("本 \(labeled.count) 冊")
        let s = Evaluator.score(labeled, rules: rules, vocabulary: vocabulary, examples: Int(args.options["examples"] ?? "") ?? 0)
        // --examples N: 誤りの例を出す。**公開データの分析専用**(蔵書から作ったデータには使わない)。
        if args.options["examples"] != nil {
            print("--- 誤って同じ組にした例")
            for (a, b) in s.falsePairs { print("[\(a.author)] \(a.title)〔\(a.series)〕 / \(b.title)〔\(b.series)〕") }
            print("--- 取りこぼした例")
            for (a, b) in s.missedPairs { print("[\(a.author)] \(a.title)〔\(a.series)〕 / \(b.title)〔\(b.series)〕") }
        }
        print(String(format: "適合率 %.3f 再現率 %.3f(正解の組 %d、候補の組 %d)名前一致 %d/%d",
                     s.precision, s.recall, s.truePairs, s.predictedPairs, s.nameMatches, s.namedBooks))

    case "rules":
        switch args.positional.first {
        case "test":
            try testExamples(paths: Array(args.positional.dropFirst()), only: args.options["only"],
                             verbose: args.flags.contains("verbose"), rules: rules)
        case "validate":
            guard let path = args.positional.dropFirst().first else { throw CLIError("確かめる規則ファイルを指定してください") }
            try validateRules(Data(contentsOf: URL(fileURLWithPath: path)))
        case "show":
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

/// 規則と、利用者の設定の語彙(本の種別)・システムの辞書で、提案の道具を作る。
func makeProposer(_ rules: CompiledRules) throws -> Proposer {
    // 本の種別の語彙は利用者の設定から(リポジトリに置けない語なので)。
    let config = try Config.load()
    if config.mediaTypes?.isEmpty ?? true {
        FileHandle.standardError.write(Data("注意: 本の種別の語彙が設定に無いので、先頭の丸括弧はイベントとして読みます(\(Config.url.path) の mediaTypes)\n".utf8))
    }
    return Proposer(rules: rules, vocabulary: Vocabulary(genres: config.mediaTypes ?? [], dictionaries: SystemDictionaries.all))
}

/// 一括の提案と、1 冊の追加・変更にかかる時間(docs/api.md「性能」の目安を確かめる)。
func bench(_ doc: ScanDocument, proposer: Proposer) async throws {
    let inputs = doc.inputs(useAI: false)
    func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }
    var set: ProposalSet?
    let sync = seconds { set = proposeSync(inputs, rules: proposer.rules, vocabulary: proposer.vocabulary) }
    let start = Date()
    _ = try await propose(inputs, rules: proposer.rules, vocabulary: proposer.vocabulary)
    let parallel = Date().timeIntervalSince(start)
    let index = ProposalIndex(rules: proposer.rules, vocabulary: proposer.vocabulary)
    let fill = Date()
    try await index.apply(inputs.map { .upsert($0) })
    let filled = Date().timeIntervalSince(fill)
    // 1 冊の変更: 既にある本を、同じ名前のまま入れ直す(単位 1 つの計算し直し)。
    var single: [Double] = []
    for input in inputs.prefix(200) {
        let t = Date()
        try await index.apply([.upsert(input)])
        single.append(Date().timeIntervalSince(t))
    }
    let same = await index.snapshot().proposals == set?.proposals
    single.sort()
    print(String(format: "本 %d 冊: 一括(同期)%.2f 秒、一括(並列)%.2f 秒、索引への投入 %.2f 秒", inputs.count, sync, parallel, filled))
    print(String(format: "1 冊の変更(%d 回): 中央値 %.1f ミリ秒、最大 %.1f ミリ秒", single.count,
                 (single.isEmpty ? 0 : single[single.count / 2]) * 1000, (single.last ?? 0) * 1000))
    print("索引と一括の結果が同じ: \(same ? "はい" : "いいえ")")
}

/// 渡せる辞書(規則は辞書を名前で指す。ここでは macOS の英単語の一覧だけ)。
func availableDictionaries() -> Set<String> { Set(SystemDictionaries.all.keys) }

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
func testExamples(paths: [String], only: String?, verbose: Bool, rules: CompiledRules) throws {
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
        for outcome in ExampleRunner.run(file, rules: rules, dictionaries: SystemDictionaries.all) {
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
