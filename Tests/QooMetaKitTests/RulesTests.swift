import Foundation
import Testing
@testable import QooMetaKit
import QooMetaExport
import QooMetaRules

// 規則ファイル(第 2 版)の読み込み・検証・差分の重ね方。語はすべて一般的な語か架空のもの。

@Suite struct RulesTests {
    static let builtIn = try! BuiltInRules.bundled()

    static func compile(_ diff: String?, builtIn: BuiltInRules = builtIn,
                        dictionaries: Set<String> = ["english"]) -> RulesCompilation {
        CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: diff.map { Data($0.utf8) }),
                              dictionaries: dictionaries)
    }

    static func diff(_ body: String, kind: String = "qoometa.series-rules") -> String {
        // 形式の版はファイルごと(filename-formats は第 3 版)。
        let version = kind == "qoometa.filename-formats" ? 3 : 2
        return #"{ "kind": "\#(kind)", "schemaVersion": \#(version), "base": "builtin", "# + body + " }"
    }

    /// 同梱の既定値を JSON のまま書き換えたもの(廃止した ID・別名のような、今の既定値に無い形を試すため)。
    static func builtIn(editingSeries edit: (inout [String: JSONValue]) -> Void) throws -> BuiltInRules {
        guard case .object(var o) = try JSONValue.parse(builtIn.seriesRules, source: "builtin") else { throw RulesIssues([]) }
        edit(&o)
        return BuiltInRules(seriesRules: Data(JSONValue.object(o).rendered().utf8), filenameFormats: builtIn.filenameFormats)
    }

    @Test func bundledDefaultsCompileCleanly() throws {
        let c = Self.compile(nil)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.warnings.isEmpty)
        let rules = try #require(c.rules)
        #expect(rules.series.volume.readers == [.ordinal, .number, .kanji, .greek, .roman, .position])
        #expect(rules.series.grouping.minPrefix == 4)
        #expect(rules.formats[nil].formats.count == 24)
        #expect(rules.formats.names == ["commercial", "doujinshi", "mixed"])
        #expect(rules.changedPaths.isEmpty)
    }

    @Test func everyMistakeIsReportedWithItsPathAndASuggestion() {
        let c = Self.compile(Self.diff("""
        "lists": { "editionWord": { "$remove": ["旧版"] }, "sourceWords": ["x"], "keepFollowing": { "$add": ["ab"] } },
        "grouping": { "sharedPrefix": { "minPrefx": 3, "minWholeTitle": 99 } },
        "volume": { "readers": { "$order": ["numbr"] } },
        "markers": { "edition": { "patterns": { "$add": ["(a+)+b"] } } },
        "policies": { "subtitled": "separat" }
        """))
        #expect(c.rules == nil)
        let byPath = Dictionary(c.errors.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byPath["lists.editionWord"]?.suggestion == "editionWords")
        #expect(byPath["lists.sourceWords"]?.code == .invalidValue)  // 差分で配列をそのまま書いた
        #expect(byPath["lists.keepFollowing.$add[0]"]?.code == .invalidValue)  // 1 文字ではない
        #expect(byPath["grouping.sharedPrefix.minPrefx"]?.suggestion == "minPrefix")
        #expect(byPath["grouping.sharedPrefix.minWholeTitle"]?.code == .invalidValue)
        #expect(byPath["volume.readers.$order[0]"]?.suggestion == "number")
        #expect(byPath["markers.edition.patterns.$add[0]"]?.code == .unsafePattern)
        #expect(byPath["policies.subtitled"]?.suggestion == "separate")
        #expect(c.errors.count == 8)
    }

    @Test func malformedJSONAndWrongEnvelope() {
        #expect(Self.compile("{ \"kind\": ").errors.map(\.code) == [.malformedJSON])
        #expect(Self.compile(#"{ "kind": "qoometa.series-rules", "schemaVersion": 3, "base": "builtin" }"#).errors.map(\.code)
                == [.unsupportedSchemaVersion])
        #expect(Self.compile(#"{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "/etc/passwd" }"#).errors.map(\.path)
                == ["base"])
        #expect(Self.compile(#"{ "kind": "qoometa.examples", "schemaVersion": 2, "base": "builtin" }"#).errors.map(\.code)
                == [.wrongKind])
    }

    @Test func listOperations() throws {
        let c = Self.compile(Self.diff("""
        "lists": {
          "labelIntroducers": { "$add": ["arc", "side"], "$remove": ["episode"] },
          "variantKanji": { "$set": { "舊": "旧" }, "$unset": ["嶋"] },
          "compilationWords": { "$replace": ["総集編"] }
        }
        """))
        let rules = try #require(c.rules, "\(c.errors)")
        let lists = try #require(rules.mergedSeriesRules["lists"])
        let labels = lists["labelIntroducers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(labels.first == "arc")  // 足した語は先頭に、すでにある語は増えない
        #expect(labels.filter { $0 == "side" }.count == 1)
        #expect(!labels.contains("episode"))
        #expect(rules.series.naming.labelIntroducers.contains("arc"))
        #expect(rules.series.compare.variantKanji["舊"] == "旧")
        #expect(rules.series.compare.variantKanji["嶋"] == nil)
        #expect(rules.series.compilation.keywords == ["総集編"])
        #expect(rules.changedPaths == ["lists.compilationWords", "lists.labelIntroducers", "lists.variantKanji"])
    }

    @Test func readersCanBeDisabledAndReordered() throws {
        let c = Self.compile(Self.diff(#""volume": { "readers": { "roman": { "enabled": false }, "$order": ["position", "number"] } }"#))
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(rules.series.volume.readers == [.position, .number, .ordinal, .kanji, .greek])
    }

    @Test func rulesAndParametersCanBeChanged() throws {
        let c = Self.compile(Self.diff("""
        "grouping": { "sharedPrefix": { "minPrefix": 3, "conditions": { "reject-common-english": { "enabled": false } } } },
        "naming": { "dropLastWord": { "enabled": false } },
        "policies": { "subtitled": "separate", "unnumberedFirst": "leaveEmpty" }
        """))
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(rules.series.grouping.minPrefix == 3)
        #expect(!rules.series.grouping.rejectCommonEnglishTitles)
        #expect(rules.series.naming.labelIntroducers.isEmpty)
        #expect(!rules.series.grouping.attachSubtitled)
        #expect(!rules.series.volume.inferFirstVolume)
    }

    @Test func everyPolicyChoiceCompiles() throws {
        for (name, choices) in RuleSchema.policies {
            for choice in choices {
                let c = Self.compile(Self.diff(#""policies": { "\#(name)": "\#(choice)" }"#))
                #expect(c.rules != nil, "\(name) = \(choice): \(c.errors)")
            }
        }
        let rules = try #require(Self.compile(Self.diff("""
        "policies": { "editions": "separateBooks", "sources": "ignore", "compilations": "inMainSeries",
                      "compilationVolume": "afterRange", "magazines": "whole" }
        """)).rules)
        #expect(!rules.series.editions.stripsEditions)
        #expect(rules.series.editions.source.isEmpty && rules.series.editions.sourcePatterns.isEmpty)
        #expect(rules.series.compilation.placement == .inMainSeries)
        #expect(rules.series.compilation.volumeMode == .afterRange)
        #expect(rules.series.volume.magazinesWhole)
    }

    /// 総集編をシリーズに含める切り替えと、そのときのオフセットは、どちらも規則で決まる(画面の設定は規則の差分として持つ。
    /// concept.md の原則 8)。番外編も同じオフセットで扱う。
    @Test func compilationsJoinTheMainSeriesWithAnOffset() throws {
        let names = ["[架空工房] 月の庭 1", "[架空工房] 月の庭 2", "[架空工房] 月の庭 総集編2", "[架空工房] 月の庭 番外編"]
        let included = try #require(CompiledRules.builtin.applying(policies: ["compilations": "inMainSeries"]).rules)
        let set = proposeSync(inputs(names), rules: included, dictionaries: [:])
        #expect(seriesName(set, "002") == "月の庭")
        #expect(set["002"]?.metadata.volume == "総集編2")
        #expect(set["002"]?.metadata.volumeSort == 102)      // 既定のオフセット 100 + 2。
        #expect(set["003"]?.metadata.volumeSort == 101)      // 番号の無い番外編は オフセット + 1。
        let shifted = try #require(Self.compile(Self.diff("""
        "grouping": { "compilation": { "volumeOffset": 500 } },
        "policies": { "compilations": "inMainSeries" }
        """)).rules)
        let moved = proposeSync(inputs(names), rules: shifted, dictionaries: [:])
        #expect(moved["002"]?.metadata.volumeSort == 502)
        #expect(moved["003"]?.metadata.volumeSort == 501)
        // 含めない(既定)ときは、これまでどおり別のシリーズ。
        let apart = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        #expect(seriesName(apart, "002") == "月の庭 総集編")
        #expect(seriesName(apart, "003") == "月の庭 番外編")
    }

    /// 規則はグローバルな状態ではなく値なので、1 つのプロセスで別々の規則を並べて使える。
    @Test func twoRuleSetsSideBySide() throws {
        let separate = try #require(CompiledRules.builtin.applying(policies: ["subtitled": "separate"]).rules)
        let inputs = ["[架空工房] 月影 はじまりの章", "[架空工房] 月影 2", "[架空工房] 月影 3"].enumerated().map {
            BookInput(id: "\($0.offset)", name: $0.element)
        }
        let firstBookSeries = [CompiledRules.builtin, separate].map { rules -> String in
            let set = proposeSync(inputs, rules: rules, dictionaries: [:])
            return set["0"]?.seriesID.flatMap { set.series($0)?.name } ?? ""
        }
        #expect(firstBookSeries == ["月影", ""])
    }

    @Test func newerRulesAreSkippedWithAWarning() throws {
        let c = Self.compile(Self.diff(#""grouping": { "yearGap": { "since": 2, "years": 10 } }, "lists": { "arcWords": { "since": 2, "$add": ["x"] } }"#))
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(c.warnings.map(\.code) == [.newerRuleSkipped, .newerRuleSkipped])
        #expect(rules.changedPaths.isEmpty)
    }

    @Test func aRequiredNewerRuleKeepsTheWholeFileFromApplying() throws {
        let c = Self.compile(Self.diff(#""grouping": { "sharedPrefix": { "minPrefix": 3 }, "yearGap": { "since": 2, "required": true } }"#))
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(c.warnings.map(\.code).contains(.requiredRuleUnknown))
        #expect(rules.series.grouping.minPrefix == 4)  // 既定値だけで動く
        #expect(rules.changedPaths.isEmpty)
    }

    @Test func retiredIDsWarnAndAliasesResolve() throws {
        let builtIn = try Self.builtIn { o in
            o["retiredIDs"] = .array([.string("reject-old-rule")])
            o["aliases"] = .object(["reject-english": .string("reject-common-english")])
        }
        let c = Self.compile(Self.diff("""
        "grouping": { "sharedPrefix": { "conditions": { "reject-old-rule": { "enabled": false }, "reject-english": { "enabled": false } } } }
        """), builtIn: builtIn)
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(c.warnings.map(\.code) == [.retiredID])
        #expect(!rules.series.grouping.rejectCommonEnglishTitles)
    }

    @Test func defaultsMustBeComplete() throws {
        let builtIn = try Self.builtIn { o in
            guard case .object(var lists) = o["lists"] else { return }
            lists["kanjiCounters"] = nil
            o["lists"] = .object(lists)
        }
        let c = Self.compile(nil, builtIn: builtIn)
        #expect(c.errors.contains { $0.code == .missingKey && $0.path == "lists.kanjiCounters" })
        // 一覧が無いので、それを指す読み手の参照も解けない。
        #expect(c.errors.allSatisfy { $0.source == "builtin" })
    }

    @Test func missingDictionaryTurnsTheConditionOffWithAWarning() throws {
        let c = Self.compile(nil, dictionaries: [])
        let rules = try #require(c.rules)
        #expect(c.warnings.map(\.code) == [.missingDictionary])
        #expect(!rules.series.grouping.rejectCommonEnglishTitles)
    }

    @Test func bundleChangesBothFiles() throws {
        let c = Self.compile("""
        { "kind": "qoometa.rules-bundle", "schemaVersion": 2, "base": "builtin",
          "seriesRules": { "grouping": { "sharedPrefix": { "minPrefix": 5 } } },
          "filenameFormats": {
            "presets": { "mixed": { "$add": ["@title - @author"], "at": "end" } },
            "separators": { "$add": ["・"] }
          } }
        """)
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(rules.series.grouping.minPrefix == 5)
        #expect(rules.formats[nil].formats.last?.text == "@title - @author")
        #expect(rules.formats[nil].separators.contains("・"))
    }

    @Test func badFormatsAreReportedByIndex() {
        // 予約語ではない `@titl` は、型の番号付きで誤りになる。
        let c = Self.compile(Self.diff(#""presets": { "mixed": { "$add": ["[@author] @titl"] } }"#,
                                       kind: "qoometa.filename-formats"))
        #expect(c.errors.map(\.path) == ["presets.mixed[0]"])
    }

    @Test func contentHashFollowsTheContentOnly() throws {
        let a = try #require(Self.compile(nil).rules)
        let b = try #require(Self.compile(Self.diff(#""revision": "x""#)).rules)
        let c = try #require(Self.compile(Self.diff(#""grouping": { "sharedPrefix": { "minPrefix": 5 } }"#)).rules)
        #expect(a.contentHash == b.contentHash)
        #expect(a.contentHash != c.contentHash)
    }
}
