import Foundation
import Testing
@testable import QooMetaCore

// 例のファイルの読み込みと、同梱の例の実行。名前はすべて架空のもの。

@Suite struct ExamplesTests {
    /// 同梱の例がすべて通ること。通らない例は、食い違いの説明をそのまま出す。
    @Test func bundledExamplesPass() throws {
        let file = try ExampleFile.bundled()
        #expect(file.examples.count > 0)
        for outcome in try ExampleRunner.run(file) {
            #expect(outcome.passed, "\(outcome.id): \(outcome.mismatches.joined(separator: " / "))")
        }
    }

    static func load(_ json: String) -> Result<ExampleFile, RulesIssues> {
        ExampleFile.load(Data(json.utf8))
    }

    @Test func allMistakesAreCollectedWithSuggestions() throws {
        let result = Self.load("""
        { "kind": "qoometa.examples", "schemaVersion": 2, "examples": [
          { "id": "a", "files": ["[架空工房] 月の庭"], "expect": [{ "seires": "月の庭" }], "covers": ["firstVolum"] },
          { "id": "a", "files": ["[架空工房] 月の庭", "[架空工房] 月の庭 2"], "expect": [{}] },
          { "id": "b", "files": ["x"], "expect": [{ "inferred": "yes", "volumeSort": "1" }], "cover": [] }
        ] }
        """)
        guard case .failure(let failure) = result else { Issue.record("誤りを見落とした"); return }
        let byPath = Dictionary(failure.issues.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byPath["examples[0].expect[0].seires"]?.suggestion == "series")
        #expect(byPath["examples[0].covers[0]"]?.suggestion == "firstVolume")
        #expect(byPath["examples[1].id"] != nil)  // 同じ ID
        #expect(byPath["examples[1].expect"] != nil)  // 期待値の数が files と合わない
        #expect(byPath["examples[2].expect[0].inferred"] != nil)
        #expect(byPath["examples[2].expect[0].volumeSort"] != nil)
        #expect(byPath["examples[2].cover"]?.suggestion == "covers")
        #expect(failure.issues.count == 7)
    }

    @Test func brokenJSONIsReported() {
        guard case .failure(let failure) = Self.load("{ \"kind\": ") else { Issue.record("壊れた JSON を読めてしまった"); return }
        #expect(failure.issues.count == 1)
        #expect(failure.issues[0].code == .malformedJSON)
    }

    @Test func otherKindsAndNewerVersionsAreRejected() {
        guard case .failure(let a) = Self.load(#"{ "kind": "qoometa.series-rules", "schemaVersion": 2, "examples": [] }"#),
              case .failure(let b) = Self.load(#"{ "kind": "qoometa.examples", "schemaVersion": 3, "examples": [] }"#)
        else { Issue.record("読めてはいけないファイルを読めた"); return }
        #expect(a.issues.map(\.path) == ["kind"])
        #expect(b.issues.map(\.path) == ["schemaVersion"])
    }

    @Test func examplePoliciesAreChecked() {
        guard case .failure(let failure) = Self.load("""
        { "kind": "qoometa.examples", "schemaVersion": 2, "examples": [
          { "id": "a", "files": ["x"], "expect": [{}], "policies": { "subtitle": "separate", "editions": "separat" } }
        ] }
        """) else { Issue.record("誤りを見落とした"); return }
        #expect(Set(failure.issues.map(\.path)) == ["examples[0].policies.subtitle", "examples[0].policies.editions"])
        #expect(failure.issues.contains { $0.path == "examples[0].policies.subtitle" && $0.suggestion == "subtitled" })
    }

    /// `"series": null` は「シリーズに入ってはいけない」。シリーズに入れば食い違いになる。
    @Test func nullSeriesMeansNotInASeries() throws {
        let file = try Self.load("""
        { "kind": "qoometa.examples", "schemaVersion": 2, "examples": [
          { "id": "wrongly-expects-no-series", "files": ["[架空工房] 月の庭 2", "[架空工房] 月の庭 3"],
            "expect": [{ "series": null }, {}] },
          { "id": "unchecked-series", "files": ["[架空工房] 月の庭 2", "[架空工房] 月の庭 3"], "expect": [{}, {}] }
        ] }
        """).get()
        let outcomes = try ExampleRunner.run(file)
        #expect(outcomes.map(\.passed) == [false, true])
        #expect(outcomes[0].mismatches.count == 1)
    }
}
