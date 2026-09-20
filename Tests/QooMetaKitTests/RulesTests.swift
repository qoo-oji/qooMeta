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
        // 形式の版はファイルごと(filename-formats は第 5 版)。
        let version = kind == "qoometa.filename-formats" ? 5 : 2
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
        #expect(rules.formats[nil].formats.count == 26)
        // 同梱の JSON と、規則ファイルを読む前に使うコードの側の並びは同じ。
        for name in rules.formats.names {
            #expect(rules.formats[name].formats.map(\.text) == FormatPresets.bundled[name].formats.map(\.text))
        }
        // 同梱のプリセットは見出しを持たない(画面が訳して出す。2026-09-21)。
        #expect(rules.formats["commercial"].label == nil)
        #expect(rules.formats.names == ["commercial", "doujinshi", "doujinshi-event", "mixed"])
        // 催しの型のプリセットだけが、名前に書かれないジャンルの既定を持つ。
        #expect(rules.formats["doujinshi-event"].defaults[.genre] == ["同人誌"])
        #expect(rules.formats["doujinshi"].defaults.isEmpty)
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
        #expect(rules.series.editions.wordRules.first { $0.treat == .compilation }?.words == ["総集編"])
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
        #expect(!rules.series.editions.wordRules.contains { $0.treat == .source })
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

    /// そのまま読む語(markers.plain)は、語に反応する規則のどれにも同じように効く。総集編だけの例外ではない。
    @Test func plainWordsSilenceEveryWordRule() throws {
        func series(_ names: [String], _ rules: CompiledRules) -> [String] {
            let set = proposeSync(names.enumerated().map { BookInput(id: "\($0.offset)", name: $0.element) },
                                  rules: rules, dictionaries: [:])
            return names.indices.map { i in set["\(i)"]?.seriesID.flatMap { set.series($0)?.name } ?? "" }
        }
        // 既定では「完全版ガイド」の「完全版」は版の印として外れ、「月の庭 ガイド」になる。一覧に足せば、タイトルの一部として読む。
        let names = ["[架空工房] 月の庭 完全版ガイド"]
        let before = proposeSync([BookInput(id: "0", name: names[0])], rules: .builtin, dictionaries: [:])
        #expect(before["0"]?.flags.contains(.edition) == true)
        let added = try #require(Self.compile(Self.diff(#""lists": { "plainWords": { "$add": ["完全版ガイド"] } }"#)).rules)
        let after = proposeSync([BookInput(id: "0", name: names[0])], rules: added, dictionaries: [:])
        #expect(after["0"]?.flags.contains(.edition) == false)
        // 同梱の一覧の語: 「フルカラー総集編」は総集編のシリーズ(「月の庭 総集編」)に入らない。規則を止めれば総集編として組まれる。
        // 同梱の一覧の語: 「フルカラー総集編」は総集編のシリーズ(「月の庭 総集編」)に入らない。規則を止めれば総集編として組まれる。
        let books = ["[架空工房] 月の庭 総集編 1", "[架空工房] 月の庭 総集編 2", "[架空工房] 月の庭 フルカラー総集編"]
        func isCompilation(_ rules: CompiledRules) -> Bool {
            proposeSync(books.enumerated().map { BookInput(id: "\($0.offset)", name: $0.element) }, rules: rules,
                        dictionaries: [:])["2"]?.flags.contains(.compilation) == true
        }
        #expect(!isCompilation(.builtin))
        let off = try #require(Self.compile(Self.diff(#""markers": { "plain": { "enabled": false } }"#)).rules)
        #expect(isCompilation(off))
        // 例外は「上に置いた、何もしない規則」。利用者は新しい ID で足せる(並びの先頭に入る)。位置は $order で決められる。
        let mine = try #require(Self.compile(Self.diff(#"""
        "markers": { "my-guides": { "treat": "keep", "words": ["完全版ガイド"] }, "$order": ["plain", "my-guides"] }
        """#)).rules)
        #expect(proposeSync([BookInput(id: "0", name: names[0])], rules: mine, dictionaries: [:])["0"]?.flags.contains(.edition) == false)
        #expect(mine.catalog.entries.filter { $0.stage == "markers" }.map(\.id) == ["plain", "my-guides", "edition", "source", "compilationMark", "standalone"])
        // 版の規則より下に置いた「何もしない規則」は、版の印を止めない(順番が意味を持つ)。
        let below = try #require(Self.compile(Self.diff(#"""
        "markers": { "my-guides": { "treat": "keep", "words": ["完全版ガイド"] }, "$order": ["edition", "my-guides"] }
        """#)).rules)
        #expect(proposeSync([BookInput(id: "0", name: names[0])], rules: below, dictionaries: [:])["0"]?.flags.contains(.edition) == true)
        // 同梱の ID の書き間違いは、新しい規則として黙って受け取らない。
        #expect(Self.compile(Self.diff(#""markers": { "editon": { "enabled": false } }"#)).errors.first?.suggestion == "edition")
        // 巻の読み手にも効く(語の規則より後ろの段階なので、取られた語には反応しない)。題名が「No.5」の本。
        let numbered = ["[架空工房] 星の海 No.5", "[架空工房] 星の海 No.9"].enumerated().map { BookInput(id: "\($0.offset)", name: $0.element) }
        #expect(proposeSync(numbered, rules: .builtin, dictionaries: [:])["0"]?.metadata.volume == "5")
        let kept = try #require(Self.compile(Self.diff(#""lists": { "plainWords": { "$add": ["No.5"] } }"#)).rules)
        let shielded = proposeSync(numbered, rules: kept, dictionaries: [:])
        #expect(shielded["0"]?.metadata.volume != "5")
        #expect(shielded["1"]?.metadata.volume == "9" || shielded["1"]?.seriesID == nil)

        // 前の形の条件と一覧は廃止した ID(差分に残っていても、警告で読み飛ばす)。
        let old = Self.compile(Self.diff(#""lists": { "editionPrefixWords": { "$add": ["x"] } }"#))
        #expect(old.rules != nil)
        #expect(old.warnings.map(\.code) == [.retiredID])
    }

    /// 「この本はシリーズに入れない」を規則で書く: 語の規則の `treat: standalone`。同梱の一覧は空(道具の側で偏りをかけない)。
    @Test func standaloneWordsKeepBooksOutOfSeries() throws {
        let names = ["[架空工房] 月の庭 1", "[架空工房] 月の庭 2", "[架空工房] 月の庭 設定資料集", "[架空工房] 月の庭 3 設定資料集つき"]
        func propose(_ rules: CompiledRules, confirming: [Int: QooMetaKit.Confirmation] = [:]) -> ProposalSet {
            proposeSync(names.enumerated().map { BookInput(id: "\($0.offset)", name: $0.element, confirmation: confirming[$0.offset] ?? .none) },
                        rules: rules, dictionaries: [:])
        }
        // 既定では、共通部分で「月の庭」に入る。
        #expect(propose(.builtin)["2"]?.metadata.series == "月の庭")
        let rules = try #require(Self.compile(Self.diff(#""lists": { "standaloneWords": { "$add": ["設定資料集"] } }"#)).rules)
        let set = propose(rules)
        #expect(set["2"]?.metadata.series == "")
        #expect(set["2"]?.flags.contains(.standalone) == true)
        #expect(set["2"]?.flags.contains(.confirmed) == false)
        #expect(set["0"]?.metadata.series == "月の庭" && set["1"]?.metadata.series == "月の庭")
        // 例外は、上に置いた「そのまま読む語」(同じ決まり)。「設定資料集つき」の本はシリーズに残る。
        let kept = try #require(Self.compile(Self.diff(#"""
        "lists": { "standaloneWords": { "$add": ["設定資料集"] }, "plainWords": { "$add": ["設定資料集つき"] } }
        """#)).rules)
        #expect(propose(kept)["3"]?.metadata.series == "月の庭")
        #expect(propose(rules)["3"]?.metadata.series == "")
        // 利用者がシリーズを決めた本には効かない。
        #expect(propose(rules, confirming: [2: .series(name: "月の庭", volume: nil, fields: .init())])["2"]?.metadata.series == "月の庭")
    }

    @Test func newerRulesAreSkippedWithAWarning() throws {
        let c = Self.compile(Self.diff(#""grouping": { "yearGap": { "since": 99, "years": 10 } }, "lists": { "arcWords": { "since": 99, "$add": ["x"] } }"#))
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(c.warnings.map(\.code) == [.newerRuleSkipped, .newerRuleSkipped])
        #expect(rules.changedPaths.isEmpty)
    }

    @Test func aRequiredNewerRuleKeepsTheWholeFileFromApplying() throws {
        let c = Self.compile(Self.diff(#""grouping": { "sharedPrefix": { "minPrefix": 3 }, "yearGap": { "since": 99, "required": true } }"#))
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
            "presets": { "mixed": { "formats": { "$add": ["@title - @author"], "at": "end" } } },
            "separators": { "$add": ["・"] }
          } }
        """)
        let rules = try #require(c.rules, "\(c.errors)")
        #expect(rules.series.grouping.minPrefix == 5)
        #expect(rules.formats[nil].formats.last?.text == "@title - @author")
        #expect(rules.formats[nil].separators.contains("・"))
    }

    /// 区切りと既定の欄は ファイル全体 → プリセット → 型 の順に、内側に書いたものが勝つ。
    @Test func innerSeparatorsAndDefaultsWin() throws {
        let c = Self.compile(Self.diff(#"""
        "separators": { "$add": ["/"] },
        "defaults": { "info": "架空の付記" },
        "presets": {
          "commercial": { "separators": { "$add": ["×"] }, "defaults": { "genre": "架空の分類甲" } },
          "my-shelf": {
            "label": "自分の棚",
            "separators": ["&"],
            "formats": [
              { "format": "@title (@volume) - @author", "separators": ["×"], "defaults": { "genre": "架空の分類乙" } },
              "[@author] @title"
            ]
          }
        }
        """#, kind: "qoometa.filename-formats"))
        let rules = try #require(c.rules, "\(c.errors)")
        // ファイル全体の区切りは、区切りを書いていないプリセットに効く。
        #expect(Set(rules.formats["doujinshi"].separators) == [",", "，", "、", "/"])
        // プリセットに初めて書く `$add` は、ファイル全体の区切りに足したものになる。
        #expect(Set(rules.formats["commercial"].separators) == [",", "，", "、", "/", "×"])
        #expect(rules.formats["commercial"].defaults == [.info: ["架空の付記"], .genre: ["架空の分類甲"]])
        // 同梱に無い名前は、利用者の新しいプリセット。区切りは書いた所で丸ごと置き換わる。
        let mine = rules.formats["my-shelf"]
        #expect(mine.label == "自分の棚")
        #expect(mine.read("[甲&乙, 丙] 月の庭").metadata.authors == ["甲", "乙, 丙"])
        let trailing = mine.read("月の庭 (3) - 甲×乙&丙")
        #expect(trailing.metadata.authors == ["甲", "乙&丙"])
        #expect(trailing.metadata.genre == "架空の分類乙")
        #expect(trailing.metadata.info == "架空の付記")
        #expect(rules.changedPaths.contains("presets.my-shelf"))
    }

    /// `plain`(型として読まない文字列)は ファイル全体 → プリセット → 型 と足し合わさる。同梱は、丸括弧の中の西暦。
    @Test func plainTextAddsUpAcrossTheLevels() throws {
        let builtin = try #require(Self.compile(nil).rules)
        #expect(builtin.formats["doujinshi"].read("[架空工房] 月の庭 (2026)").metadata.title == "月の庭 (2026)")
        #expect(builtin.formats["commercial"].read("[架空工房] 月の庭 (2026)").metadata.volume.isEmpty)
        let c = Self.compile(Self.diff(#"""
        "plain": { "words": { "$add": ["(仮)"] } },
        "presets": { "doujinshi": { "plain": { "patterns": { "$add": ["[(（]第\\d+版[)）]"] } } } }
        """#, kind: "qoometa.filename-formats"))
        let rules = try #require(c.rules, "\(c.errors)")
        let doujinshi = rules.formats["doujinshi"]
        #expect(doujinshi.read("[架空工房] 月の庭 (第2版)").metadata.title == "月の庭 (第2版)")
        #expect(doujinshi.read("[架空工房] 月の庭 (仮)").metadata.title == "月の庭 (仮)")
        #expect(doujinshi.read("[架空工房] 月の庭 (2026)").metadata.title == "月の庭 (2026)")
        // プリセットに足した分は、ほかのプリセットには効かない。
        #expect(rules.formats["mixed"].read("[架空工房] 月の庭 (第2版)").metadata.source == "第2版")
        // 危ない正規表現は、ほかの規則と同じく誤り。
        let bad = Self.compile(Self.diff(#""plain": { "patterns": { "$add": ["(a+)+"] } }"#, kind: "qoometa.filename-formats"))
        #expect(bad.errors.map(\.code) == [.unsafePattern])
    }

    @Test func defaultPresetCanBeChangedButMustExist() throws {
        let ok = Self.compile(Self.diff(#""defaultPreset": "commercial""#, kind: "qoometa.filename-formats"))
        #expect(try #require(ok.rules).formats.defaultName == "commercial")
        let bad = Self.compile(Self.diff(#""defaultPreset": "nowhere""#, kind: "qoometa.filename-formats"))
        #expect(bad.errors.map(\.path) == ["defaultPreset"])
    }

    @Test func formatsAreIdentifiedByTheirText() throws {
        // 区切りを添えた型で足し直しても、同じ型は 2 つにならない。文字列だけを書けば外せる。
        let c = Self.compile(Self.diff(#"""
        "presets": { "commercial": { "formats": {
          "$remove": ["@series (@volume) - @author"],
          "$add": [{ "format": "[@author] @title", "separators": ["×"] }, { "format": "@title - @author", "separators": ["×"] }],
          "at": "end" } } }
        """#, kind: "qoometa.filename-formats"))
        let texts = try #require(c.rules, "\(c.errors)").formats["commercial"].formats.map(\.text)
        #expect(!texts.contains("@series (@volume) - @author"))
        #expect(texts.filter { $0 == "[@author] @title" }.count == 1)
        #expect(texts.last == "@title - @author")
    }

    @Test func newPresetsMustBeWrittenInFull() {
        // 同梱の名前の書き間違いは、新しいプリセットとして黙って受け取らない。
        let c = Self.compile(Self.diff(#""presets": { "comercial": { "formats": { "$add": ["@title - @author"] } } }"#,
                                       kind: "qoometa.filename-formats"))
        #expect(c.errors.map(\.path) == ["presets.comercial"])
        #expect(c.errors.first?.suggestion == "commercial")
        let old = Self.compile(Self.diff(#""retiredIDs": []"#, kind: "qoometa.filename-formats"))
        #expect(!old.errors.isEmpty)
    }

    @Test func badFormatsAreReportedByIndex() {
        // 予約語ではない `@titl` は、型の番号付きで誤りになる。
        let c = Self.compile(Self.diff(#""presets": { "mixed": { "formats": { "$add": ["[@author] @titl"] } } }"#,
                                       kind: "qoometa.filename-formats"))
        #expect(c.errors.map(\.path) == ["presets.mixed.formats[0]"])
    }

    @Test func contentHashFollowsTheContentOnly() throws {
        let a = try #require(Self.compile(nil).rules)
        let b = try #require(Self.compile(Self.diff(#""revision": "x""#)).rules)
        let c = try #require(Self.compile(Self.diff(#""grouping": { "sharedPrefix": { "minPrefix": 5 } }"#)).rules)
        #expect(a.contentHash == b.contentHash)
        #expect(a.contentHash != c.contentHash)
    }
}
