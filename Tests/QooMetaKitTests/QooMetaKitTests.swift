import Foundation
import Testing
@testable import QooMetaKit
@testable import QooMetaExport
import QooMetaRules

// テストの名前はすべて合成したもの(実在の本・サークルの名前は使わない。CLAUDE.md)。
//
// ファイル名からシリーズ・巻までを通して確かめる形は、例のファイル(Sources/QooMetaRules/Resources/examples.json)に
// 書く(ExamplesTests が走らせる)。ここに置くのは、例では書けない途中の値(組の性質、端末内モデルの判定の反映、
// 書き出しの形)と、部品ごとの確認。

/// 同梱の既定値と、macOS の英単語の一覧で作った道具。
let builtinEngine = RuleEngine(rules: .builtin, vocabulary: Vocabulary(dictionaries: SystemDictionaries.all))

@Suite struct NameParserTests {
    @Test func fullPattern() {
        let p = NameParser.parse(baseName: "(分類A) [架空工房 (山田太郎、佐藤花子)] 星降る夜の喫茶店 2 (オリジナル)")
        #expect(p.leading == "分類A")
        #expect(p.circle == "架空工房")
        #expect(p.authors == ["山田太郎", "佐藤花子"])
        #expect(p.title == "星降る夜の喫茶店 2")
        #expect(p.trailing == "オリジナル")
        #expect(p.matchedPattern)
    }

    @Test func withoutAuthorsOrTrailing() {
        let p = NameParser.parse(baseName: "(分類B) [架空工房] 月の裏側")
        #expect(p.circle == "架空工房")
        #expect(p.authors.isEmpty)
        #expect(p.title == "月の裏側")
        #expect(p.trailing.isEmpty)
    }

    @Test func fullWidthBracketsKeepOriginalWidth() {
        let p = NameParser.parse(baseName: "［架空工房］ ＡＢＣの冒険！（オリジナル）")
        #expect(p.circle == "架空工房")
        #expect(p.title == "ＡＢＣの冒険！")
        #expect(p.trailing == "オリジナル")
    }

    @Test func plainNameIsWholeTitle() {
        let p = NameParser.parse(baseName: "ただのファイル名")
        #expect(p.title == "ただのファイル名")
        #expect(!p.matchedPattern)
    }
}

@Suite struct SeriesGrouperTests {
    static func books(_ items: [(circle: String, title: String)]) -> [WorkingBook] {
        let inputs = items.enumerated().map { i, item in
            BookInput(id: "\(i)", name: "[\(item.circle)] \(item.title)", folders: [item.circle])
        }
        return builtinEngine.prepare(inputs, limits: .default).books.enumerated().map { i, b in
            WorkingBook(id: i + 1, inputID: b.input.id, parsed: b.parts, circleKey: b.circleKey)
        }
    }

    @Test func unnumberedSeriesWithinOneCircle() {
        let b = Self.books([
            ("架空工房", "星降る夜の喫茶店"),
            ("架空工房", "星降る夜の喫茶店 冬の章"),
            ("架空工房", "星降る夜の喫茶店~おかわり~"),
            ("架空工房", "月の裏側"),
        ])
        let groups = SeriesGrouper(engine: builtinEngine).group(b)
        #expect(groups.count == 1)
        #expect(groups[0].memberIDs.count == 3)
        #expect(groups[0].ruleName == "星降る夜の喫茶店")
        #expect(groups[0].cleanBoundary)
    }

    @Test func commonWordsAreCountedAcrossCircles() {
        let b = Self.books([
            ("架空工房", "魔法少女リナ 休日"), ("架空工房", "魔法少女リナ 夏休み"),
            ("幻想舎", "魔法少女リナは眠らない"), ("白紙堂", "魔法少女リナと猫"),
        ])
        let groups = SeriesGrouper(engine: builtinEngine).group(b)
        #expect(groups.count == 1)
        #expect(groups[0].circlesSharingPrefix == 3)
    }
}

@Suite struct VolumeTests {
    @Test(arguments: [
        (" 2", "2", 2.0), ("Vol.3", "3", 3.0), ("第5話", "5", 5.0), ("その二", "二", 2.0),
        ("#4 おまけ", "4", 4.0), ("第十二巻", "十二", 12.0), (" ver2", "2", 2.0), (" Ver.3", "3", 3.0),
        ("第1幕", "1", 1.0), ("第弐巻", "弐", 2.0), ("第百二十巻", "百二十", 120.0), (" β", "β", 2.0), (" (12)", "12", 12.0), ("第三部 完結", "三", 3.0), (" II", "II", 2.0), (" Ⅳ", "IV", 4.0), (" IX 完結編", "IX", 9.0), (" 2つめ", "2", 2.0), ("第3弾", "3", 3.0), (" 4冊目", "4", 4.0),
    ])
    func numbers(remainder: String, text: String, number: Double) {
        let v = builtinEngine.volumes.extract(fromRemainder: remainder)
        #expect(v?.text == text)
        #expect(v?.number == number)
    }

    @Test func positionWordsAreReadAsText() {
        // 1 冊だけでは数にしない(数はシリーズの中の文脈で決める)。
        let v = builtinEngine.volumes.extract(fromRemainder: " 後編")
        #expect(v?.text == "後編")
        #expect(v?.number == nil)
    }

    @Test(arguments: [" 2人の夜", " 冬の章", ""])
    func notVolumes(remainder: String) {
        #expect(builtinEngine.volumes.extract(fromRemainder: remainder) == nil)
    }
}

@Suite struct EditionAndCompilationTests {
    @Test func editionMarkersAreSplit() {
        let a = builtinEngine.markers.split("月の庭【フルカラー版】")
        #expect(a.base == "月の庭")
        #expect(a.editions == ["フルカラー版"])
        let b = builtinEngine.markers.split("月の庭 3 DL版")
        #expect(b.base == "月の庭 3")
        #expect(b.sources == ["DL版"])
        let c = builtinEngine.markers.split("月の庭 (英語版) [特装版]")
        #expect(c.base == "月の庭")
        #expect(c.editions == ["英語版"])
        #expect(c.sources == ["特装版"])
    }

    @Test func rangeBeforeCompilationIsMovedAfterIt() {
        #expect(builtinEngine.compilation.normalizedTitle("月の庭1~4総集編") == "月の庭 総集編 1~4")
        #expect(builtinEngine.compilation.normalizedTitle("月の庭 9~11+α総集篇") == "月の庭 総集篇 9~11+α")
    }
}

@Suite struct ExporterTests {
    static func proposals() -> ProposalSet {
        proposeSync([
            BookInput(id: "a.cbz", name: "(分類A) [架空工房 (山田太郎)] 星降る夜の喫茶店 1 (オリジナル)"),
            BookInput(id: "b.cbr", name: "(分類A) [架空工房 (山田太郎)] 星降る夜の喫茶店 上 (オリジナル) <&>"),
        ], rules: .builtin, vocabulary: Vocabulary())
    }

    @Test func stackroomPlistRoundTrip() throws {
        let data = try Exporter.stackroomXML(Self.proposals(), files: [
            "a.cbz": .init(path: "/nowhere/a.cbz", fileExtension: "cbz", dateAdded: Date(timeIntervalSince1970: 1_700_000_000)),
            "b.cbr": .init(path: "/nowhere/b.cbr", fileExtension: "cbr"),
        ])
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let books = try #require(root["Books"] as? [String: [String: Any]])
        let first = try #require(books["1"])
        #expect(first["Title"] as? String == "星降る夜の喫茶店 1")
        #expect(first["Author"] as? String == "架空工房, 山田太郎")
        #expect(first["Genre"] as? String == "分類A")
        #expect(first["Neta"] as? String == "オリジナル")
        #expect(first["Series"] as? String == "星降る夜の喫茶店")
        #expect(first["Volume"] as? Double == 1)
        #expect(first["File Type"] as? Int == 2)
        #expect(first["Date Added"] as? Date == Date(timeIntervalSince1970: 1_700_000_000))
        let second = try #require(books["2"])
        #expect(second["File Type"] as? Int == 3)
        #expect(second["Volume"] as? Double == 1)  // 「上」はシリーズの文脈で数にする(中が無いので 1)
    }

    @Test func qooViewerJSONShape() throws {
        let data = try Exporter.qooViewerJSON(Self.proposals(), identities: [
            "a.cbz": .init(path: "/nowhere/a.cbz", inodeNumber: 11), "b.cbr": .init(path: "/nowhere/b.cbr", inodeNumber: 12),
        ])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == 4)
        let entries = try #require(root["metadata"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["author"] as? String == "架空工房")
        #expect(entries[0]["seriesIndex"] as? String == "1")
        #expect(entries[1]["seriesIndex"] as? String == "上")
        #expect(entries[0]["inodeNumber"] as? Int == 11)
    }

    @Test func comicInfoIsEscaped() throws {
        let set = Self.proposals()
        let book = try #require(set["b.cbr"])
        let xml = String(decoding: Exporter.comicInfoXML(book, series: book.seriesID.flatMap { set.series($0) }), as: UTF8.self)
        #expect(xml.contains("<Series>星降る夜の喫茶店</Series>"))
        #expect(xml.contains("<Number>上</Number>"))
        #expect(!xml.contains("<&>"))
        #expect(xml.contains("&lt;&amp;&gt;"))
        #expect(Exporter.xmlEscape("a\u{1}b") == "ab")
    }
}
