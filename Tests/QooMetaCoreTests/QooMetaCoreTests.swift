import Foundation
import Testing
@testable import QooMetaCore

// テストの名前はすべて合成したもの(実在の本・サークルの名前は使わない。CLAUDE.md)。
//
// ファイル名からシリーズ・巻までを通して確かめる形は、例のファイル(Sources/QooMetaCore/Resources/examples.json)に
// 書く(ExamplesTests が走らせる)。ここに置くのは、例では書けない途中の値(組の性質、端末内モデルの判定の反映、
// 書き出しの形)と、部品ごとの確認。

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
    static func books(_ items: [(circle: String, title: String)]) -> [BookProposal] {
        let files = items.enumerated().map { i, item in
            BookFile(path: "/nowhere/\(i).cbz", relativePath: "\(item.circle)/\(i).cbz",
                     baseName: "[\(item.circle)] \(item.title)", fileExtension: "cbz")
        }
        return BookScanner.proposals(from: files)
    }

    @Test func unnumberedSeriesWithinOneCircle() {
        let b = Self.books([
            ("架空工房", "星降る夜の喫茶店"),
            ("架空工房", "星降る夜の喫茶店 冬の章"),
            ("架空工房", "星降る夜の喫茶店~おかわり~"),
            ("架空工房", "月の裏側"),
        ])
        let groups = SeriesGrouper().group(b)
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
        let groups = SeriesGrouper().group(b)
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
        let v = RuleEngine.builtin.volumes.extract(fromRemainder: remainder)
        #expect(v?.text == text)
        #expect(v?.number == number)
    }

    @Test func positionWordsAreReadAsText() {
        // 1 冊だけでは数にしない(数はシリーズの中の文脈で決める)。
        let v = RuleEngine.builtin.volumes.extract(fromRemainder: " 後編")
        #expect(v?.text == "後編")
        #expect(v?.number == nil)
    }

    @Test(arguments: [" 2人の夜", " 冬の章", ""])
    func notVolumes(remainder: String) {
        #expect(RuleEngine.builtin.volumes.extract(fromRemainder: remainder) == nil)
    }
}

@Suite struct FinalizerTests {
    @Test func aiRejectionAndExclusion() {
        let b = SeriesGrouperTests.books([
            ("架空工房", "星降る夜の喫茶店 1"), ("架空工房", "星降る夜の喫茶店 2"), ("架空工房", "星降る夜の喫茶店 3"),
        ])
        var doc = ProposalDocument(rootPath: "/nowhere", minPrefix: 4, books: b, groups: SeriesGrouper().group(b))
        doc.groups[0].aiVerdict = AIVerdict(isSeries: true, seriesName: "星降る夜の喫茶店", excludedIDs: [3],
                                            confidence: .high, seconds: 0)
        ProposalFinalizer.finalize(&doc)
        #expect(doc.books.map(\.series) == ["星降る夜の喫茶店", "星降る夜の喫茶店", ""])
        #expect(doc.books.map(\.volumeNumber) == [1, 2, nil])

        doc.groups[0].aiVerdict?.isSeries = false
        ProposalFinalizer.finalize(&doc)
        #expect(doc.books.allSatisfy { $0.series.isEmpty })

        ProposalFinalizer.finalize(&doc, useAI: false)
        #expect(doc.books.allSatisfy { $0.series == "星降る夜の喫茶店" })
    }
}

@Suite struct EditionAndCompilationTests {
    @Test func editionMarkersAreSplit() {
        let a = RuleEngine.builtin.markers.split("月の庭【フルカラー版】")
        #expect(a.base == "月の庭")
        #expect(a.editions == ["フルカラー版"])
        let b = RuleEngine.builtin.markers.split("月の庭 3 DL版")
        #expect(b.base == "月の庭 3")
        #expect(b.sources == ["DL版"])
        let c = RuleEngine.builtin.markers.split("月の庭 (英語版) [特装版]")
        #expect(c.base == "月の庭")
        #expect(c.editions == ["英語版"])
        #expect(c.sources == ["特装版"])
    }

    @Test func rangeBeforeCompilationIsMovedAfterIt() {
        #expect(RuleEngine.builtin.compilation.normalizedTitle("月の庭1~4総集編") == "月の庭 総集編 1~4")
        #expect(RuleEngine.builtin.compilation.normalizedTitle("月の庭 9~11+α総集篇") == "月の庭 総集篇 9~11+α")
    }
}

@Suite struct ExporterTests {
    static func document() -> ProposalDocument {
        var files = [
            BookFile(path: "/nowhere/a.cbz", relativePath: "a.cbz",
                     baseName: "(分類A) [架空工房 (山田太郎)] 星降る夜の喫茶店 1 (オリジナル)", fileExtension: "cbz",
                     created: Date(timeIntervalSince1970: 1_700_000_000), inodeNumber: 11, volumeDeviceNumber: 1,
                     volumeUUID: "00000000-0000-0000-0000-000000000000"),
            BookFile(path: "/nowhere/b.cbr", relativePath: "b.cbr",
                     baseName: "(分類A) [架空工房 (山田太郎)] 星降る夜の喫茶店 上 (オリジナル)", fileExtension: "cbr"),
        ]
        files[1].inodeNumber = 12
        let books = BookScanner.proposals(from: files)
        var doc = ProposalDocument(rootPath: "/nowhere", minPrefix: 4, books: books, groups: SeriesGrouper().group(books))
        ProposalFinalizer.finalize(&doc)
        return doc
    }

    @Test func stackroomPlistRoundTrip() throws {
        let doc = Self.document()
        let data = try PropertyListSerialization.data(
            fromPropertyList: StackroomExporter.makeDocument(doc), format: .xml, options: 0)
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

    @Test func seriesListExcludesNamesFromAPreviousList() {
        let doc = Self.document()
        let first = SeriesListExporter.csv(doc)
        let names = SeriesListExporter.fileNames(inList: first)
        #expect(names == ["a.cbz", "b.cbr"])
        let second = SeriesListExporter.csv(doc, excludingFileNames: ["a.cbz"])
        #expect(second.split(whereSeparator: \.isNewline).count == 2)  // 見出し + 1 冊
    }

    @Test func qooViewerJSONShape() throws {
        let data = try QooViewerExporter.makeData(Self.document())
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == 4)
        let entries = try #require(root["metadata"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["author"] as? String == "架空工房")
        #expect(entries[0]["seriesIndex"] as? String == "1")
        #expect(entries[1]["seriesIndex"] as? String == "上")
        #expect(entries[0]["inodeNumber"] as? Int == 11)
    }
}
