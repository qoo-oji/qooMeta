import Foundation
import QooMetaKit

// 同梱の既定値と、システムの資源の読み込み口。本体(QooMetaKit)はファイルを読まないので、読むのはこのモジュール。

extension BuiltInRules {
    /// パッケージに同梱した 2 つの JSON(Resources/series-rules.json・filename-formats.json)。
    public static func bundled() throws -> BuiltInRules {
        BuiltInRules(seriesRules: try resource("series-rules"), filenameFormats: try resource("filename-formats"))
    }
}

func resource(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
        ?? Bundle.module.url(forResource: name, withExtension: "json") else {
        throw RulesIssue(.missingKey, source: "builtin", at: "", "\(name).json")
    }
    return try Data(contentsOf: url)
}

extension CompiledRules {
    /// 同梱の既定値だけを組み立てたもの。同梱の規則は検証済みなので、組み立てられなければ作りの誤り。
    public static let builtin: CompiledRules = {
        let compilation = CompiledRules.compile(RuleSources(builtIn: try! BuiltInRules.bundled()),
                                                dictionaries: SystemDictionaries.english == nil ? [] : ["english"])
        guard let rules = compilation.rules else {
            fatalError("同梱の規則を組み立てられない:\n" + compilation.errors.map(\.description).joined(separator: "\n"))
        }
        return rules
    }()
}

/// システムの辞書。規則は辞書を名前(`"english"`)で指すだけで、パスを持たない(規則ファイルから利用側のファイルを
/// 読ませないため)。実体の置き場所はここで決める。
public enum SystemDictionaries {
    public static let englishPath = "/usr/share/dict/words"

    /// macOS の単語の一覧(`/usr/share/dict/words`、Webster 第 2 版。無ければ nil)。大きい(約 24 万語)ので 1 度だけ読む。
    public static let english: WordSet? = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: englishPath)) else { return nil }
        return WordSet(lines: data)
    }()

    /// 読めた辞書を、規則が指す名前で(Vocabulary.dictionaries に渡す形)。
    public static var all: [String: WordSet] {
        english.map { ["english": $0] } ?? [:]
    }
}

extension ExampleFile {
    /// 同梱の例(Resources/examples.json)。
    public static func bundled() throws -> ExampleFile {
        try load(resource("examples")).get()
    }
}
