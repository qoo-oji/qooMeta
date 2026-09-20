import Foundation
import Testing
@testable import QooMetaKit
import QooMetaRules

// 説明・まとめて編集・規則のカタログと変更・フィードバック。名前はすべて架空のもの。

@Suite struct ExplanationTests {
    static func explained(_ names: [String]) -> ProposalSet {
        proposeSync(inputs(names), rules: .builtin, dictionaries: SystemDictionaries.all,
                    options: ProposalOptions(explanations: true))
    }

    @Test func appliedRules() throws {
        let set = Self.explained(["[架空工房] 月の庭", "[架空工房] 月の庭 2", "[架空工房] 月の庭 3【フルカラー版】"])
        let first = try #require(set.explanation(for: "000"))
        #expect(first.appliedRules.contains("volumeHead"))
        #expect(first.appliedRules.contains("firstVolume"))
        let second = try #require(set.explanation(for: "001"))
        let third = try #require(set.explanation(for: "002"))
        #expect(second.appliedRules.contains("number"))
        #expect(third.appliedRules.contains("edition"))
    }

    @Test(arguments: [
        (["[架空工房] マーメイド戦士の夜", "[架空工房] マーメイド服の少女"], "reject-single-script"),
        (["[架空工房] 森の奥のお姉さんと過ごす夏", "[架空工房] 森の奥の花嫁"], "reject-hiragana-ending"),
        (["[架空工房] 月影の庭", "[架空工房] 月影草紙"], "sharedPrefix"),
        (["[架空工房] NEON 夜の街 (作品A)", "[架空工房] NEON 朝の港 (作品B)"], "splitByRelation"),
        (["[架空工房] 月の庭", "[架空工房] 月の庭【フルカラー版】"], "rejectSameWork"),
    ])
    func nearMisses(names: [String], rule: String) throws {
        let set = Self.explained(names)
        #expect(set.series.isEmpty)
        let miss = try #require(set.explanation(for: "000")?.nearMisses.first)
        #expect(miss.otherID == "001")
        #expect(miss.rejectedBy == rule)
        #expect(miss.sharedPrefixLength >= 2)
    }

    @Test func commonEnglish() throws {
        guard SystemDictionaries.english != nil else { return }
        let set = Self.explained(["[架空工房] Moon Piece", "[架空工房] Moon Works"])
        #expect(set.explanation(for: "000")?.nearMisses.first?.rejectedBy == "reject-common-english")
    }

    @Test func noExplanationsUnlessAsked() {
        let set = proposeSync(inputs(["[架空工房] 月の庭 1", "[架空工房] 月の庭 2"]), rules: .builtin, dictionaries: [:])
        #expect(set.explanation(for: "000") == nil)
    }

    @Test func prefixCommonness() throws {
        let set = proposeSync(inputs([
            "[架空工房] 魔法少女リナ 休日", "[架空工房] 魔法少女リナ 夏休み", "[幻想舎] 魔法少女リナは眠らない", "[白紙堂] 魔法少女リナと猫",
        ]), rules: .builtin, dictionaries: [:])
        let id = try #require(set.series.first?.id)
        #expect(set.prefixCommonness(of: id, rules: .builtin) == 3)
    }
}

@Suite struct BulkEditTests {
    static let set = proposeSync(inputs([
        "[架空工房] 星降る夜の喫茶店 春の章", "[架空工房] 星降る夜の喫茶店 夏の章【フルカラー版】", "[架空工房] 星降る夜の喫茶店 秋",
        "[架空工房] 月の庭 02", "[架空工房] 月の庭 03", "[架空工房] 風の港",
    ]), rules: .builtin, dictionaries: [:])

    @Test func suggestedName() {
        #expect(BulkEdit.suggestedSeriesName(for: ["000", "001", "002"], in: Self.set, rules: .builtin) == "星降る夜の喫茶店")
        #expect(BulkEdit.suggestedSeriesName(for: ["003"], in: Self.set, rules: .builtin) == "月の庭")
        #expect(BulkEdit.suggestedSeriesName(for: ["003", "005"], in: Self.set, rules: .builtin) == nil)
    }

    @Test func setSeriesKeepsVolumesAndFields() {
        let current: [String: QooMetaKit.Confirmation] = ["003": .fields(ConfirmedFields([.authors: ["別名工房"]]))]
        let result = BulkEdit.setSeries("庭シリーズ", for: ["003", "005"], in: Self.set, current: current)
        #expect(result["003"] == .series(name: "庭シリーズ", volume: "02", fields: ConfirmedFields([.authors: ["別名工房"]])))
        #expect(result["005"] == .series(name: "庭シリーズ", volume: nil))
    }

    @Test func numberSequentially() {
        let ordered = BulkEdit.sorted(["002", "000", "001"], by: .title, in: Self.set)
        #expect(ordered == ["001", "000", "002"])  // 夏・春・秋(文字の順)
        let numbered = BulkEdit.numberSequentially(["000", "001", "002"], in: Self.set, numbering: .init(start: 1, padding: .width(2)))
        #expect(numbered["000"] == .series(name: "星降る夜の喫茶店", volume: "01"))
        #expect(numbered["002"] == .series(name: "星降る夜の喫茶店", volume: "03"))
        // 今の表記に合わせる: 「02」「03」のシリーズは 2 桁。
        let matched = BulkEdit.numberSequentially(["004", "003"], in: Self.set, numbering: .init(start: 5))
        #expect(matched["004"] == .series(name: "月の庭", volume: "05"))
        // シリーズの無い本は、名前が渡されなければ何もしない。
        #expect(BulkEdit.numberSequentially(["005"], in: Self.set).isEmpty)
    }

    @Test func otherEdits() {
        #expect(BulkEdit.removeFromSeries(["003"], in: Self.set)["003"] == .notInSeries())
        #expect(BulkEdit.revertToProposal(["003"])["003"] == QooMetaKit.Confirmation.none)
        #expect(BulkEdit.clearVolumes(["003"], in: Self.set)["003"] == .series(name: "月の庭", volume: ""))
        let accepted = BulkEdit.acceptProposals(["003", "005"], in: Self.set)
        guard case .series("月の庭", "02", let fields)? = accepted["003"] else { Issue.record("\(String(describing: accepted["003"]))"); return }
        #expect(fields[.authors] == ["架空工房"])
        guard case .notInSeries? = accepted["005"] else { Issue.record("シリーズの無い本"); return }
    }

    /// まとめて編集の結果を渡すと、確定した内容として効く(巻を消すと、推定もしない)。
    @Test func editsTakeEffect() {
        let names = ["[架空工房] 月の庭", "[架空工房] 月の庭 2"]
        let before = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        #expect(before["000"]?.flags.contains(.inferredVolume) == true)
        let cleared = BulkEdit.clearVolumes(["000"], in: before)
        let after = proposeSync(inputs(names).map { BookInput(id: $0.id, name: $0.name, confirmation: cleared[$0.id] ?? .none) },
                                rules: .builtin, dictionaries: [:])
        #expect(after["000"]?.metadata.volume.isEmpty == true)
        #expect(seriesName(after, "000") == "月の庭")
    }

    /// ジャンルで割れたシリーズを、全選択してジャンルを書き換えるとひとつにできる(段階 7 の終わりの条件)。
    /// 道具の側でジャンルの取り違えを先回りして防がない代わりに、利用者がまとめて直せることを確かめる。
    @Test func editingTheGenreMergesASplitSeries() {
        let names = ["(種別A) [架空工房] 月の庭 1", "(種別B) [架空工房] 月の庭 2"]
        let before = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        #expect(before.series.isEmpty)  // ジャンルが違うと単位が分かれ、1 冊ずつではシリーズにならない。
        let edits = BulkEdit.setFields(ConfirmedFields([.genre: ["種別A"]]), for: ["000", "001"], in: before)
        let after = proposeSync(inputs(names).map {
            BookInput(id: $0.id, name: $0.name, confirmation: edits[$0.id] ?? .none)
        }, rules: .builtin, dictionaries: [:])
        #expect(after.series.count == 1)
        #expect(seriesName(after, "000") == "月の庭")
        #expect(seriesName(after, "001") == "月の庭")
        #expect(after["001"]?.metadata.genre == "種別A")
    }

    /// 方針 differentGenre を keep にすると、ジャンルが違っても 1 つのシリーズになる(段階 7 の終わりの条件)。
    /// 画面の設定は規則の差分として持つので、効き方はここで確かめる。
    @Test func keepingDifferentGenresMakesOneSeries() throws {
        let names = ["(種別A) [架空工房] 月の庭 1", "(種別B) [架空工房] 月の庭 2"]
        let kept = try #require(CompiledRules.builtin.applying(policies: ["differentGenre": "keep"]).rules)
        let set = proposeSync(inputs(names), rules: kept, dictionaries: [:])
        #expect(set.series.count == 1)
        #expect(seriesName(set, "000") == "月の庭")
        #expect(seriesName(set, "001") == "月の庭")
    }

    @Test func sortOrders() {
        let dates = ["003": Date(timeIntervalSince1970: 2), "004": Date(timeIntervalSince1970: 1)]
        #expect(BulkEdit.sorted(["003", "004", "005"], by: .date, in: Self.set, dates: dates) == ["004", "003", "005"])
        #expect(BulkEdit.sorted(["004", "005", "003"], by: .currentVolume, in: Self.set) == ["003", "004", "005"])
        #expect(BulkEdit.sorted(["004", "003"], by: .name, in: Self.set) == ["003", "004"])
    }
}

@Suite struct RuleCatalogTests {
    @Test func defaultsAreUnmodified() {
        let catalog = CompiledRules.builtin.catalog
        #expect(catalog.policies.count == RuleSchema.policies.count)
        #expect(!catalog.policies.contains { $0.isModified })
        #expect(!catalog.entries.contains { $0.isModified })
        #expect(catalog.entries.map(\.id).contains("reject-common-english"))
        #expect(catalog.entries.filter { $0.stage == "volume.readers" }.map(\.id) == ["ordinal", "number", "kanji", "greek", "roman", "position"])
        #expect(catalog.lists.first { $0.id == "labelIntroducers" }?.added.isEmpty == true)
    }

    @Test func changesRoundTripAndShowInTheCatalog() throws {
        var changes = RuleChanges.none
        changes.setPolicy("separate", for: "subtitled")
        let known = [changes.setEnabled(false, rule: "roman"),
                     changes.setValue(.number(3), rule: "sharedPrefix", parameter: "minPrefix"),
                     changes.setEnabled(false, rule: "reject-hiragana-ending")]
        #expect(known == [true, true, true])
        changes.add(["arc"], to: "labelIntroducers")
        changes.remove(["episode"], from: "labelIntroducers")
        changes.setReaderOrder(["position"])
        let unknown = changes.setEnabled(false, rule: "no-such-rule")
        #expect(!unknown)

        let reread = try RuleChanges(data: changes.data())
        #expect(reread == changes)
        let compilation = CompiledRules.compile(RuleSources(builtIn: try .bundled(), userChanges: changes.data()))
        let rules = try #require(compilation.rules, "\(compilation.errors)")
        let catalog = rules.catalog
        #expect(catalog.policies.first { $0.id == "subtitled" }?.current == "separate")
        #expect(catalog.entries.first { $0.id == "roman" }?.isEnabled == false)
        #expect(catalog.entries.first { $0.id == "sharedPrefix" }?.parameters.first { $0.name == "minPrefix" }?.current == .number(3))
        #expect(catalog.entries.first { $0.id == "reject-hiragana-ending" }?.isModified == true)
        let labels = try #require(catalog.lists.first { $0.id == "labelIntroducers" })
        #expect(labels.added == ["arc"])
        #expect(labels.removed == ["episode"])
        #expect(catalog.entries.filter { $0.stage == "volume.readers" }.first?.id == "position")
    }

    @Test func resetAndLastOperationWins() throws {
        var changes = RuleChanges.none
        changes.setEnabled(false, rule: "roman")
        changes.reset(rule: "roman")
        #expect(changes.isEmpty)
        changes.add(["arc"], to: "labelIntroducers")
        changes.remove(["arc"], from: "labelIntroducers")
        changes.resetList("labelIntroducers")
        #expect(changes.isEmpty)
        changes.add(["arc"], to: "labelIntroducers")
        changes.remove(["arc"], from: "labelIntroducers")
        let text = String(decoding: changes.data(), as: UTF8.self)
        #expect(text.contains("$remove") && !text.contains("$add"))
    }

    @Test func singleKindDiffIsRead() throws {
        let changes = try RuleChanges(data: Data(#"{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin", "policies": { "subtitled": "separate" } }"#.utf8))
        #expect(!changes.isEmpty)
        #expect(throws: RulesIssue.self) { try RuleChanges(data: Data(#"{ "kind": "x", "base": "builtin" }"#.utf8)) }
    }

    @Test func appliedPoliciesShowAsModified() throws {
        let rules = try #require(CompiledRules.builtin.applying(policies: ["magazines": "whole"]).rules)
        #expect(rules.catalog.policies.first { $0.id == "magazines" }?.isModified == true)
    }
}

@Suite struct FeedbackTests {
    static let dictionaries = SystemDictionaries.all

    @Test func everyWordIsReplacedAndTheShapeIsKept() throws {
        let books = [
            BookInput(id: "1", name: "(本の種別Z) [夕凪工房 (水野葵)] 蒼穹のアルカディア 2 (原作X) [DL版]"),
            BookInput(id: "2", name: "(本の種別Z) [夕凪工房 (水野葵)] 蒼穹のアルカディア 3"),
            BookInput(id: "3", name: "(本の種別Z) [夕凪工房 (水野葵)] 蒼穹のアルカディア 総集編"),
            BookInput(id: "4", name: "[夕凪工房] Silver Moon Garden 上"),
        ]
        let feedback = makeFeedbackExample(books, corrected: ["2": .series(name: "蒼穹のアルカディア", volume: "3"),
                                                              "4": .notInSeries()],
                                           rules: .builtin, dictionaries: SystemDictionaries.all)
        let text = String(decoding: feedback.data, as: UTF8.self)
        // 元の語は残らない(規則の語・数字・記号・本の種別の置き換えは残る)。
        for word in ["夕凪", "工房", "水野", "蒼穹", "アルカディア", "原作", "Silver", "Moon", "Garden"] {
            #expect(!text.contains(word), "\(word) が残っている")
        }
        for kept in ["DL版", "総集編", " 2 ", "上"] { #expect(text.contains(kept), "\(kept) が消えた") }
        #expect(feedback.isFaithful)

        // 置き換えた例は、例のファイルとしてそのまま読めて、直した結果の期待値を持つ。
        let file = try ExampleFile.load(feedback.data).get()
        #expect(file.examples.count == 1)
        let outcome = try #require(ExampleRunner.run(file, rules: .builtin, dictionaries: SystemDictionaries.all).first)
        #expect(outcome.passed, "\(outcome.mismatches)")
    }

    /// 同じ語は同じ語へ、先頭が共通する語は同じ長さだけ共通させる。
    @Test func sharedPrefixesStayShared() {
        var a = Anonymizer(rules: .builtin, dictionaries: SystemDictionaries.all)
        let x = a.text("蒼穹のアルカディア 春"), y = a.text("蒼穹のアルカディア 秋"), z = a.text("蒼穹のアルカディア")
        #expect(x.count == "蒼穹のアルカディア 春".count)
        #expect(x.hasPrefix(z) && y.hasPrefix(z))
        #expect(x != y)
        #expect(a.text("蒼穹のアルカディア") == z)
    }

    @Test func correctionMetByAPolicy() {
        let books = inputs(["[架空工房] 月影 はじまりの章", "[架空工房] 月影 2", "[架空工房] 月影 3"])
        let feedback = makeFeedbackExample(books, corrected: ["000": .notInSeries()], rules: .builtin, dictionaries: SystemDictionaries.all)
        #expect(feedback.satisfiedByPolicy == .init(policy: "subtitled", choice: "separate"))
    }
}

@Suite struct RegexBudgetTests {
    /// 時間のかかる正規表現は、上限で打ち切る(印が無いものとして扱う)。
    @Test func catastrophicPatternIsAbandoned() throws {
        let regex = try NSRegularExpression(pattern: "(a+)+b")
        let text = String(repeating: "a", count: 40)
        let start = Date()
        #expect(BudgetedRegex.matches(regex, in: text, budget: 0.02) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(BudgetedRegex.matches(regex, in: "aab", budget: 0.02)?.count == 1)
    }
}

