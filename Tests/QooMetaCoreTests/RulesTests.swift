import Foundation
import Testing
@testable import QooMetaCore

// 規則ファイル(第 2 版)の読み込み・検証・差分の重ね方。語はすべて一般的な語か架空のもの。

@Suite struct RulesTests {
    static let builtIn = try! BuiltInRules.bundled()

    static func compile(_ diff: String?, builtIn: BuiltInRules = builtIn,
                        dictionaries: Set<String> = ["english"]) -> RulesCompilation {
        CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: diff.map { Data($0.utf8) }),
                              dictionaries: dictionaries)
    }

    static func diff(_ body: String, kind: String = "qoometa.series-rules") -> String {
        #"{ "kind": "\#(kind)", "schemaVersion": 2, "base": "builtin", "# + body + " }"
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
        #expect(rules.formats.profiles.map(\.id) == ["doujinshi"])
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

    @Test func policiesNotYetImplementedAreRejected() {
        let c = Self.compile(Self.diff(#""policies": { "compilations": "inMainSeries" }"#))
        #expect(c.errors.map(\.code) == [.notYetSupported])
        #expect(c.errors.first?.path == "policies.compilations")
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
            "profiles": { "doujinshi": { "formats": { "$add": ["[@circle] @title {@keywordA}"], "at": "end" } } },
            "reservedWords": { "@author": { "split": { "$add": ["・"] } } }
          } }
        """)
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(rules.series.grouping.minPrefix == 5)
        #expect(rules.formats.profiles[0].formats.last == "[@circle] @title {@keywordA}")
        #expect(rules.formats.authorSeparators.contains("・"))
    }

    @Test func badFormatsAreReportedByProfile() {
        let c = Self.compile(Self.diff(#""profiles": { "doujinshi": { "formats": { "$add": ["[@circle] @titl"] } } }"#,
                                       kind: "qoometa.filename-formats"))
        #expect(c.errors.map(\.path) == ["profiles.doujinshi.formats[0]"])
    }

    @Test func contentHashFollowsTheContentOnly() throws {
        let a = try #require(Self.compile(nil).rules)
        let b = try #require(Self.compile(Self.diff(#""revision": "x""#)).rules)
        let c = try #require(Self.compile(Self.diff(#""grouping": { "sharedPrefix": { "minPrefix": 5 } }"#)).rules)
        #expect(a.contentHash == b.contentHash)
        #expect(a.contentHash != c.contentHash)
    }
}
