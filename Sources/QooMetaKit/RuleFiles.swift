import CryptoKit
import Foundation

/// 既定値の規則のデータ(同梱の 2 つの JSON。読み込むのは QooMetaRules)。
///
/// - `filename-formats.json`: 型の並び(名前のどこが何の欄か)と、著者の区切り。
/// - `series-rules.json`: タイトルからシリーズ名と巻を取り出す規則。
///
/// どちらも**蔵書の名前を含まない**(一般的な語と記号だけ)。公開リポジトリに置く。形式は docs/rules-format-design.md。
public struct BuiltInRules: Sendable {
    public var seriesRules: Data
    public var filenameFormats: Data

    public init(seriesRules: Data, filenameFormats: Data) {
        self.seriesRules = seriesRules
        self.filenameFormats = filenameFormats
    }
}

/// 規則のデータ: 同梱の既定値と、利用者の変更(差分。シリーズの規則・フォーマット・rules-bundle のどれか)。
public struct RuleSources: Sendable {
    public var builtIn: BuiltInRules
    public var userChanges: Data?

    public init(builtIn: BuiltInRules, userChanges: Data? = nil) {
        self.builtIn = builtIn
        self.userChanges = userChanges
    }
}

public struct RulesCompilation: Sendable {
    /// 誤りが 1 件でもあれば nil。
    public let rules: CompiledRules?
    public let errors: [RulesIssue]
    /// 新しい版の規則を飛ばした、廃止された ID への参照、辞書が無い、など。
    public let warnings: [RulesIssue]
}

/// 組み立て済みの規則。
public struct CompiledRules: Sendable {
    /// 本体が知っている規則の水準。規則・パラメータ・一覧を足したら上げ、足したものの `since` にこの番号を書く。
    public static let engineLevel = 1

    let series: SeriesRules
    /// 名前を付けた型の並び。本ごとに、どのプリセットで読むかを選べる(フォルダごとに分けたい利用者のため)。
    public let formats: FormatPresets
    /// 重ねた結果(`rules show` 用)。
    public let mergedSeriesRules: JSONValue
    public let mergedFilenameFormats: JSONValue
    /// 利用者の変更が効いている値の道筋。
    public let changedPaths: [String]
    /// 内容から計算したハッシュ(キャッシュの判定用。`revision` には依らない)。
    public let contentHash: String
    /// 既定値(利用者の変更を重ねる前。規則のカタログで、変えたかどうかを見るのに使う)。
    public let defaultSeriesRules: JSONValue
    public let defaultFilenameFormats: JSONValue

    /// - Parameter dictionaries: 利用側が渡せる辞書の名前。規則が指す辞書が無ければ、その条件は働かず警告になる。
    public static func compile(_ sources: RuleSources, dictionaries: Set<String> = ["english"]) -> RulesCompilation {
        var issues: [RulesIssue] = []
        var builtin = RuleLoader(source: "builtin", engineLevel: engineLevel)

        func parse(_ data: Data, _ loader: inout RuleLoader) -> JSONValue? {
            guard data.count <= RuleLoader.Limits.bytes else {
                loader.report(.tooLarge, "", "\(data.count) バイト")
                return nil
            }
            do { return try JSONValue.parse(data, source: loader.source) } catch {
                loader.issues.append(error)
                return nil
            }
        }

        var seriesRoot = parse(sources.builtIn.seriesRules, &builtin)
        if let root = seriesRoot, builtin.envelope(root, expected: [.seriesRules], isDiff: false) != nil {
            builtin.checkSeriesDefaults(root)
        }
        let seriesRetired = (builtin.retiredIDs, builtin.aliases)
        var formatsRoot = parse(sources.builtIn.filenameFormats, &builtin)
        if let root = formatsRoot, builtin.envelope(root, expected: [.filenameFormats], isDiff: false) != nil {
            builtin.checkFormatDefaults(root)
        }
        builtin.retiredIDs.formUnion(seriesRetired.0)
        builtin.aliases.merge(seriesRetired.1) { a, _ in a }
        issues += builtin.issues
        guard !builtin.hasErrors, seriesRoot != nil, formatsRoot != nil else {
            return RulesCompilation(rules: nil, errors: issues.filter { !$0.isWarning }, warnings: issues.filter(\.isWarning))
        }

        let defaults = (series: seriesRoot!, formats: formatsRoot!)
        var changed: [String] = []
        if let data = sources.userChanges {
            var user = RuleLoader(source: "user", engineLevel: engineLevel)
            user.retiredIDs = builtin.retiredIDs
            user.aliases = builtin.aliases
            if let root = parse(data, &user), let kind = user.envelope(root, expected: [.seriesRules, .filenameFormats, .bundle], isDiff: true),
               let o = root.objectValue {
                var series = seriesRoot!, formats = formatsRoot!
                switch kind {
                case .seriesRules:
                    series = user.applySeries(o, to: series)
                case .filenameFormats:
                    formats = user.applyFormats(o, to: formats)
                case .bundle:
                    let allowed = RuleLoader.envelopeKeys + ["seriesRules", "filenameFormats"]
                    user.unknownKeys(o, "", allowed: allowed)
                    if let s = o["seriesRules"] {
                        if let so = s.objectValue { series = user.applySeries(so.filter { $0.key != "kind" && $0.key != "schemaVersion" }, to: series) }
                        else { user.report(.invalidValue, "seriesRules", "オブジェクトであるべきところが\(s.kindName)") }
                    }
                    if let f = o["filenameFormats"] {
                        if let fo = f.objectValue { formats = user.applyFormats(fo.filter { $0.key != "kind" && $0.key != "schemaVersion" }, to: formats) }
                        else { user.report(.invalidValue, "filenameFormats", "オブジェクトであるべきところが\(f.kindName)") }
                    }
                }
                // 本体の知らない必須の規則があれば、そのファイルは適用しない(既定値だけで動く)。
                if user.sawRequiredUnknown {
                    user.issues.removeAll { !$0.isWarning }
                } else if !user.hasErrors {
                    seriesRoot = series
                    formatsRoot = formats
                    changed = user.changedPaths
                }
            }
            issues += user.issues
        }
        guard !issues.contains(where: { !$0.isWarning }) else {
            return RulesCompilation(rules: nil, errors: issues.filter { !$0.isWarning }, warnings: issues.filter(\.isWarning))
        }

        var compiler = RuleCompiler(source: sources.userChanges == nil ? "builtin" : "user", dictionaries: dictionaries)
        let series = compiler.series(seriesRoot!)
        let formats = compiler.formats(formatsRoot!)
        issues += compiler.issues
        let errors = issues.filter { !$0.isWarning }
        guard errors.isEmpty, let series, let formats else {
            return RulesCompilation(rules: nil, errors: errors, warnings: issues.filter(\.isWarning))
        }
        let hashed = Data((stripped(seriesRoot!).rendered() + "\n" + stripped(formatsRoot!).rendered()).utf8)
        let hash = SHA256.hash(data: hashed).prefix(12).map { String(format: "%02x", $0) }.joined()
        let rules = CompiledRules(series: series, formats: formats, mergedSeriesRules: seriesRoot!,
                                  mergedFilenameFormats: formatsRoot!, changedPaths: changed.sorted(), contentHash: hash,
                                  defaultSeriesRules: defaults.series, defaultFilenameFormats: defaults.formats)
        return RulesCompilation(rules: rules, errors: [], warnings: issues.filter(\.isWarning))
    }

    /// 方針だけを置き換えた規則(例ごとの方針、GUI の「好み」の切り替え)。今の規則(利用者の変更を重ねたもの)を土台にする。
    public func applying(policies: [String: String], dictionaries: Set<String> = ["english"]) -> RulesCompilation {
        guard !policies.isEmpty, case .object(var series) = mergedSeriesRules else {
            return RulesCompilation(rules: self, errors: [], warnings: [])
        }
        var current = series["policies"]?.objectValue ?? [:]
        for (name, choice) in policies { current[name] = .string(choice) }
        series["policies"] = .object(current)
        let builtIn = BuiltInRules(seriesRules: Data(JSONValue.object(series).rendered().utf8),
                                   filenameFormats: Data(mergedFilenameFormats.rendered().utf8))
        let compilation = CompiledRules.compile(RuleSources(builtIn: builtIn), dictionaries: dictionaries)
        // 既定値は元のまま(方針を変えたことが、規則のカタログで「変えた」と見えるように)。
        guard let rules = compilation.rules else { return compilation }
        return RulesCompilation(rules: CompiledRules(
            series: rules.series, formats: rules.formats, mergedSeriesRules: rules.mergedSeriesRules,
            mergedFilenameFormats: rules.mergedFilenameFormats,
            changedPaths: Set(changedPaths + policies.keys.map { "policies.\($0)" }).sorted(), contentHash: rules.contentHash,
            defaultSeriesRules: defaultSeriesRules, defaultFilenameFormats: defaultFilenameFormats),
            errors: compilation.errors, warnings: compilation.warnings)
    }

    /// 型の並びだけを差し替えたもの(公開データの採点のように、別のプリセットで読みたいとき)。規則の中身は変えない。
    public func replacingFormats(_ formats: FilenameFormats) -> CompiledRules {
        replacingFormats(FormatPresets(presets: [formats == .doujinshiPreset ? "doujinshi" : "commercial": formats],
                                       defaultName: formats == .doujinshiPreset ? "doujinshi" : "commercial"))
    }

    /// プリセットの組ごと差し替えたもの。
    public func replacingFormats(_ formats: FormatPresets) -> CompiledRules {
        CompiledRules(series: series, formats: formats, mergedSeriesRules: mergedSeriesRules,
                      mergedFilenameFormats: mergedFilenameFormats, changedPaths: changedPaths,
                      contentHash: contentHash, defaultSeriesRules: defaultSeriesRules,
                      defaultFilenameFormats: defaultFilenameFormats)
    }

    /// 処理に関係しない包みのキー(`$schema`・`revision`)を除く。内容のハッシュがそれらに左右されないように。
    static func stripped(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        o["$schema"] = nil
        o["revision"] = nil
        return .object(o)
    }
}

/// 重ねた規則を、エンジンが使う形に組み立てる。一覧の参照(`@list:`)を解き、方針を今の扱いへ写す。
struct RuleCompiler {
    let source: String
    let dictionaries: Set<String>
    var issues: [RulesIssue] = []

    mutating func report(_ code: RulesIssue.Code, _ path: String, _ detail: String? = nil) {
        issues.append(RulesIssue(code, source: source, at: path, detail))
    }

    /// 一覧の値(`@list:` を解いたもの)。
    func words(_ v: JSONValue?, _ lists: [String: JSONValue]) -> [String] {
        guard let v else { return [] }
        if let ref = v.stringValue, ref.hasPrefix("@list:") {
            return words(lists[String(ref.dropFirst("@list:".count))], lists)
        }
        return v.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func pairs(_ v: JSONValue?, _ lists: [String: JSONValue]) -> [String: String] {
        guard let v else { return [:] }
        if let ref = v.stringValue, ref.hasPrefix("@list:") {
            return pairs(lists[String(ref.dropFirst("@list:".count))], lists)
        }
        return v.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }

    mutating func series(_ root: JSONValue) -> SeriesRules? {
        let lists = root["lists"]?.objectValue ?? [:]
        let policies = root["policies"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        func enabled(_ v: JSONValue?) -> Bool { v?["enabled"]?.boolValue ?? true }


        let compare = root["compare"], markers = root["markers"], grouping = root["grouping"]
        let naming = root["naming"], volume = root["volume"]
        let shared = grouping?["sharedPrefix"], conditions = shared?["conditions"]
        let english = conditions?["reject-common-english"]
        var englishEnabled = enabled(english)
        if englishEnabled, let name = english?["dictionary"]?.stringValue, !dictionaries.contains(name) {
            issues.append(RulesIssue(.missingDictionary, source: source,
                                     at: "grouping.sharedPrefix.conditions.reject-common-english", name))
            englishEnabled = false
        }

        // 印は、規則を止めたときも、方針で見分けないこと(`ignore`)を選んだときも探さない。
        let editionsOn = enabled(markers?["edition"]) && policies["editions"] != "ignore"
        let sourcesOn = enabled(markers?["source"]) && policies["sources"] != "ignore"

        let readersJSON = volume?["readers"]?.arrayValue ?? []
        func reader(_ id: String) -> JSONValue? { readersJSON.first { $0["id"]?.stringValue == id } }
        let readers = readersJSON.compactMap { r -> SeriesRules.Reader? in
            guard enabled(r), let id = r["id"]?.stringValue else { return nil }
            return SeriesRules.Reader(rawValue: id)
        }
        let number = reader("number"), kanji = reader("kanji"), position = reader("position")
        let inference = volume?["inference"]
        let leadingKanji = inference?["sharedLeadingKanji"], firstVolume = inference?["firstVolume"]

        return SeriesRules(
            compare: .init(
                ignoredCharacters: words(compare?["ignored"], lists).joined(),
                variantKanji: pairs(compare?["variants"], lists),
                boundaryCharacters: words(compare?["boundaries"], lists).joined()),
            grouping: .init(
                minPrefix: shared?["minPrefix"]?.intValue ?? 4,
                minWholeTitle: shared?["minWholeTitle"]?.intValue ?? 2,
                attachSubtitled: policies["subtitled"] != "separate",
                splitByRelation: policies["differentRelation"] != "keep",
                splitByGenre: policies["differentGenre"] != "keep",
                volumeHeadEnabled: enabled(grouping?["volumeHead"]),
                sharedPrefixEnabled: enabled(shared),
                rejectHiraganaEndings: enabled(conditions?["reject-hiragana-ending"]),
                rejectSingleWordPrefixes: enabled(conditions?["reject-single-script"]),
                rejectCommonEnglishTitles: englishEnabled,
                commonEnglishUnlessVolume: english?["unlessVolume"]?.boolValue ?? true,
                compilationSingleWhenMainExists: grouping?["compilation"]?["singleWhenMainExists"]?.boolValue ?? true),
            naming: .init(
                trimTrailing: words(naming?["trimTrailing"]?["characters"], lists).joined(),
                trimTrailingEnabled: enabled(naming?["trimTrailing"]),
                keepFollowing: enabled(naming?["includeFollowing"])
                    ? words(naming?["includeFollowing"]?["characters"], lists).joined() : "",
                brackets: enabled(naming?["includeClosingBrackets"])
                    ? pairs(naming?["includeClosingBrackets"]?["pairs"], lists) : [:],
                labelIntroducers: enabled(naming?["dropLastWord"]) ? words(naming?["dropLastWord"]?["words"], lists) : []),
            editions: .init(
                edition: editionsOn ? words(markers?["edition"]?["words"], lists) : [],
                editionPatterns: editionsOn ? words(markers?["edition"]?["patterns"], lists) : [],
                source: sourcesOn ? words(markers?["source"]?["words"], lists) : [],
                sourcePatterns: sourcesOn ? words(markers?["source"]?["patterns"], lists) : [],
                stripsEditions: policies["editions"] != "separateBooks",
                stripsSources: policies["sources"] != "separateBooks"),
            compilation: .init(
                keywords: words(grouping?["compilation"]?["words"], lists),
                placement: SeriesRules.Compilation.Placement(rawValue: policies["compilations"] ?? "") ?? .ownSeries,
                volumeAfterRange: policies["compilationVolume"] == "afterRange"),
            volume: .init(
                readers: readers,
                prefixes: words(number?["prefixes"], lists),
                counters: words(number?["counters"], lists),
                wholeOnlyCounters: words(number?["wholeOnlyCounters"], lists),
                kanjiPrefixes: words(kanji?["prefixes"], lists),
                kanjiCounters: words(kanji?["counters"], lists),
                positionWords: .init(first: words(position?["first"], lists), middle: words(position?["middle"], lists),
                                     last: words(position?["last"], lists)),
                mergedIssueMaxSpan: number?["mergedSpan"]?.intValue ?? 3,
                sharedLeadingKanjiEnabled: enabled(leadingKanji),
                sharedLeadingKanjiMinBooks: leadingKanji?["minBooks"]?.intValue ?? 2,
                inferFirstVolume: policies["unnumberedFirst"] != "leaveEmpty",
                magazinesWhole: policies["magazines"] == "whole",
                notFirstMarkers: words(firstVolume?["excludeMarkers"], lists),
                notFirstPrefixes: words(firstVolume?["excludePrefixes"], lists)))
    }

    /// filename-formats.json → 名前を付けた型の並び(プリセット)と区切り。型の書き間違いは、番号付きで誤りにする。
    mutating func formats(_ root: JSONValue) -> FormatPresets? {
        let separators = words(root["separators"], [:])
        var presets: [String: FilenameFormats] = [:]
        for (name, list) in root["presets"]?.objectValue ?? [:] {
            var compiled: [FilenameFormat] = []
            for (i, text) in words(list, [:]).enumerated() {
                do { compiled.append(try FilenameFormat(text)) } catch {
                    report(.invalidValue, "presets.\(name)[\(i)]", error.description)
                }
            }
            presets[name] = FilenameFormats(formats: compiled,
                                            separators: separators.isEmpty ? FilenameFormats.defaultSeparators : separators)
        }
        let defaultName = root["defaultPreset"]?.stringValue ?? "mixed"
        if presets[defaultName] == nil { report(.invalidValue, "defaultPreset", "そのプリセットが無い: \(defaultName)") }
        return FormatPresets(presets: presets, defaultName: defaultName)
    }
}

/// エンジンが使う形のシリーズの規則。方針(`policies`)は、ここでは今の扱いのフラグに写してある。
struct SeriesRules: Sendable {
    struct Compare: Sendable {
        /// 比べるときに無視する文字(空白と、タイトルの飾りによく使われる記号)。
        var ignoredCharacters: String
        /// 比べるときに同じ字とみなす異体字(左 → 右)。
        var variantKanji: [String: String]
        /// 語の切れ目とみなす文字(この直前で切れた共通部分は「きれいな切れ目」)。
        var boundaryCharacters: String
    }

    struct Grouping: Sendable {
        /// 語の途中で切れる共通部分は、この文字数以上のときだけ組にする。
        var minPrefix: Int
        /// 片方のタイトル全体がもう片方の前半と一致する場合の下限。
        var minWholeTitle: Int
        /// 方針 `subtitled`。
        var attachSubtitled: Bool
        /// 方針 `differentRelation`(ネタが違う本を分ける)。
        var splitByRelation: Bool
        /// 方針 `differentGenre`(本の種別が違う本を分ける)。
        var splitByGenre: Bool
        var volumeHeadEnabled: Bool
        var sharedPrefixEnabled: Bool
        var rejectHiraganaEndings: Bool
        var rejectSingleWordPrefixes: Bool
        var rejectCommonEnglishTitles: Bool
        /// 一般的な英語だけのタイトルでも、後ろに巻があれば組にする。
        var commonEnglishUnlessVolume: Bool
        /// 本編のシリーズがあれば、総集編が 1 冊でもシリーズにする。
        var compilationSingleWhenMainExists: Bool
    }

    struct Naming: Sendable {
        /// シリーズ名の末尾から落とす文字(巻の前の区切りとしても使う)。
        var trimTrailing: String
        var trimTrailingEnabled: Bool
        /// 共通部分の直後にあれば、名前に含める文字(止めていれば空)。
        var keepFollowing: String
        /// 閉じ括弧 → 開き括弧。開いたままの括弧があれば、直後の閉じ括弧まで名前に含める(止めていれば空)。
        var brackets: [String: String]
        /// 名前の末尾に残ったら外す語(止めていれば空)。
        var labelIntroducers: [String]
    }

    struct Editions: Sendable {
        /// 印の語と正規表現(規則を止めたとき、方針 `ignore` のときは空)。
        var edition: [String]
        var editionPatterns: [String]
        var source: [String]
        var sourcePatterns: [String]
        /// 比べるタイトルから印を除くか(方針 `sameWork`)。`separateBooks` なら印を見分けて付けるが、除かずに比べる。
        var stripsEditions: Bool
        var stripsSources: Bool
    }

    struct Compilation: Sendable {
        enum Placement: String, Sendable { case ownSeries, inMainSeries, notInSeries }
        var keywords: [String]
        /// 方針 `compilations`。
        var placement: Placement
        /// 方針 `compilationVolume` が `afterRange`(本編の中での巻を、収録範囲の最後の巻の直後にする)。
        var volumeAfterRange: Bool
    }

    /// 巻の読み手(docs/rules-format-design.md の `volume.readers`)。
    enum Reader: String, Sendable {
        case ordinal, number, kanji, greek, roman, position
    }

    struct Volume: Sendable {
        struct PositionWords: Sendable {
            var first: [String]
            var middle: [String]
            var last: [String]
        }

        /// 働いている読み手(優先の順)。
        var readers: [Reader]
        /// 巻の番号の前に付く語(`vol` `第` `その` …)。英字の語は後ろの「.」も受け付ける。
        var prefixes: [String]
        /// 巻の番号の後ろに付く単位。
        var counters: [String]
        /// 巻だけでできているかを見るときにだけ使う単位。
        var wholeOnlyCounters: [String]
        /// 漢数字の前に付く語(英字・記号の語は使わない)。
        var kanjiPrefixes: [String]
        /// 漢数字の後ろに付く単位。
        var kanjiCounters: [String]
        var positionWords: PositionWords
        /// 「36-37」を合併号とみなす、前後の差の上限。
        var mergedIssueMaxSpan: Int
        var sharedLeadingKanjiEnabled: Bool
        var sharedLeadingKanjiMinBooks: Int
        /// 方針 `unnumberedFirst`。
        var inferFirstVolume: Bool
        /// 方針 `magazines` が `whole`(雑誌全体で 1 つのシリーズにし、年と号を巻として読む)。
        var magazinesWhole: Bool
        /// シリーズ名より後ろにこの語があれば、1 巻の推定の候補にしない。
        var notFirstMarkers: [String]
        /// シリーズ名の直後にこの語が付けば、1 巻の推定の候補にしない。
        var notFirstPrefixes: [String]

        func reads(_ reader: Reader) -> Bool { readers.contains(reader) }
    }

    var compare: Compare
    var grouping: Grouping
    var naming: Naming
    var editions: Editions
    var compilation: Compilation
    var volume: Volume
}

extension SeriesRules.Volume {
    /// 正規表現の選択肢(長い語を先に)。英字の語には「.」の省略を許す。
    func alternation(_ words: [String], allowDot: Bool = false) -> String {
        words.sorted { $0.count > $1.count }.map { w in
            let escaped = NSRegularExpression.escapedPattern(for: w)
            return allowDot && w.allSatisfy({ $0.isASCII && $0.isLetter }) ? escaped + #"\.?"# : escaped
        }.joined(separator: "|")
    }

    var prefixPattern: String { alternation(prefixes, allowDot: true) }
    /// 漢数字の前に付く語(英字・記号でないもの)。
    var kanjiPrefixPattern: String { alternation(kanjiPrefixes.filter { !$0.allSatisfy(\.isASCII) }) }
    var positionPattern: String { alternation(positionWords.first + positionWords.middle + positionWords.last) }
}
