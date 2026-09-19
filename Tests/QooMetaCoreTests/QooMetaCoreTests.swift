import Foundation
import Testing
@testable import QooMetaCore

// テストの名前はすべて合成したもの(実在の本・サークルの名前は使わない。CLAUDE.md)。

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

    @Test func sameWordsInDifferentCirclesAreNotGrouped() {
        let b = Self.books([
            ("架空工房", "魔法少女の休日"),
            ("幻想舎", "魔法少女の休日明け"),
        ])
        #expect(SeriesGrouper().group(b).isEmpty)
    }

    @Test func shrinkingOnlyAtWordBoundary() {
        // 「ABCD 1」「ABCD 2」に「ABCZ」が来ても、共通部分を「ABC」へ縮めない。
        let b = Self.books([
            ("架空工房", "ABCD 1"),
            ("架空工房", "ABCD 2"),
            ("架空工房", "ABCZ"),
        ])
        let groups = SeriesGrouper().group(b)
        #expect(groups.count == 1)
        #expect(groups[0].ruleName == "ABCD")
        #expect(groups[0].memberIDs.count == 2)
    }

    @Test func shortWholeTitleIsPrefixOfAnother() {
        let b = Self.books([("架空工房", "XY"), ("架空工房", "XY2")])
        let groups = SeriesGrouper().group(b)
        #expect(groups.count == 1)
        #expect(groups[0].ruleName == "XY")
    }

    @Test func shortTitleWithVolumes() {
        // 3 文字のタイトルは minPrefix(4)に届かないが、後ろが巻なら同じ組。
        let b = Self.books([("架空工房", "月下美 21"), ("架空工房", "月下美 第3巻"), ("架空工房", "月下美人の夜")])
        let groups = SeriesGrouper().group(b)
        #expect(groups.count == 1)
        #expect(groups[0].memberIDs.count == 2)
        #expect(groups[0].ruleName == "月下美")
    }

    @Test(arguments: [["咲 18", "咲 21"], ["亜人 1", "亜人 3"], ["月影 春の編", "月影 冬の編"]])
    func shortTitlesCutAtWordBoundary(titles: [String]) {
        let b = Self.books(titles.map { ("架空工房", $0) } + [("架空工房", "咲き誇る庭")])
        let groups = SeriesGrouper().group(b)
        #expect(groups.count == 1)
        #expect(groups.first?.memberIDs.count == 2)
    }

    @Test func singleWordPrefixIsNotASeries() {
        #expect(SeriesGrouper().group(Self.books([("架空工房", "マーメイド戦士の夜"), ("架空工房", "マーメイド服の少女")])).isEmpty)
        #expect(SeriesGrouper().group(Self.books([("架空工房", "スピカVS教師"), ("架空工房", "スピカが見た夢")])).isEmpty)
        // 文字種が切り替わる長い共通部分は、これまでどおり組になる。
        #expect(SeriesGrouper().group(Self.books([("架空工房", "星降る夜の喫茶店冬の章"), ("架空工房", "星降る夜の喫茶店春の章")])).count == 1)
    }

    @Test func commonEnglishTitlesAreNotASeries() {
        #expect(SeriesGrouper().group(Self.books([("架空工房", "Moon Piece"), ("架空工房", "Moon Works")])).isEmpty)
        // 一般語でない語(作り語)や日本語を含めば組になる。
        #expect(SeriesGrouper().group(Self.books([("架空工房", "Zorblax Piece"), ("架空工房", "Zorblax Works")])).count == 1)
        #expect(SeriesGrouper().group(Self.books([("架空工房", "Moon 夜の街"), ("架空工房", "Moon 朝の港")])).count == 1)
        // 巻があれば組になる(「Moon 2」「Moon 3」)。
        #expect(SeriesGrouper().group(Self.books([("架空工房", "Moon 2"), ("架空工房", "Moon 3")])).count == 1)
        #expect(SeriesGrouper().group(Self.books([("架空工房", "Moon 1 -Rise-"), ("架空工房", "Moon 2 -Set-")])).count == 1)

    }

    @Test func phraseEndingInParticleIsNotASeries() {
        let b = Self.books([("架空工房", "森の奥のお姉さんと過ごす夏"), ("架空工房", "森の奥の花嫁 DL版")])
        #expect(SeriesGrouper().group(b).isEmpty)
    }

    @Test func midWordPrefixStillNeedsMinLength() {
        // 語の途中で切れる 3 文字の一致(「月影の庭」「月影草紙」)は、n=4 では組にしない。
        let b = Self.books([("架空工房", "月影の庭"), ("架空工房", "月影草紙")])
        #expect(SeriesGrouper().group(b).isEmpty)
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
        ("第1幕", "1", 1.0), ("第三部 完結", "三", 3.0), (" II", "II", 2.0), (" Ⅳ", "IV", 4.0), (" IX 完結編", "IX", 9.0), (" 2つめ", "2", 2.0), ("第3弾", "3", 3.0), (" 4冊目", "4", 4.0),
    ])
    func numbers(remainder: String, text: String, number: Double) {
        let v = VolumeExtractor.extract(fromRemainder: remainder)
        #expect(v?.text == text)
        #expect(v?.number == number)
    }

    @Test func positionWordsHaveNoNumber() {
        let v = VolumeExtractor.extract(fromRemainder: " 後編")
        #expect(v?.text == "後編")
        #expect(v?.number == nil)
    }

    @Test(arguments: [" 2人の夜", " 冬の章", ""])
    func notVolumes(remainder: String) {
        #expect(VolumeExtractor.extract(fromRemainder: remainder) == nil)
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

@Suite struct FirstVolumeInferenceTests {
    static func finalized(_ titles: [String]) -> [BookProposal] {
        let b = SeriesGrouperTests.books(titles.map { ("架空工房", $0) })
        var doc = ProposalDocument(rootPath: "/nowhere", minPrefix: 4, books: b, groups: SeriesGrouper().group(b))
        ProposalFinalizer.finalize(&doc)
        return doc.books
    }

    @Test func unnumberedFirstBookBecomesVolumeOne() {
        let books = Self.finalized(["星降る夜の喫茶店", "星降る夜の喫茶店 2", "星降る夜の喫茶店 3"])
        #expect(books.map(\.volumeNumber) == [1, 2, 3])
        #expect(books[0].volumeInferred == true)
        #expect(books[1].volumeInferred == nil)
    }

    @Test func subtitledUnnumberedBookAlsoCounts() {
        let books = Self.finalized(["月影 はじまりの章", "月影 2"])
        #expect(books.map(\.volumeNumber) == [1, 2])
    }

    @Test func verIsAVolumePrefixNotPartOfTheName() {
        let b = SeriesGrouperTests.books([("架空工房", "架空の写真 ver2"), ("架空工房", "架空の写真 ver3")])
        let groups = SeriesGrouper().group(b)
        #expect(groups.map(\.ruleName) == ["架空の写真"])
        let books = Self.finalized(["架空の写真 ver2", "架空の写真 ver3"])
        #expect(books.map(\.series) == ["架空の写真", "架空の写真"])
        #expect(books.map(\.volumeNumber) == [2, 3])
    }

    @Test(arguments: [["架空録! ver1", "架空録! ver2"], ["架空録ver.48", "架空録ver.特別"]])
    func verWithoutPrecedingSpace(titles: [String]) {
        let books = Self.finalized(titles)
        #expect(books.allSatisfy { ComparableText($0.series).key == ComparableText("架空録").key })
    }

    @Test func variantKanjiAreTheSameSeries() {
        // 1 冊目だけ異体字(凜)で、2 冊目以降が凛。比較では同じ字、書き出す名前は元の表記のまま。
        let books = Self.finalized(["架空の凜", "架空の凛2", "架空の凛3"])
        #expect(books.map(\.volumeNumber) == [1, 2, 3])
        #expect(books[0].volumeInferred == true)
    }

    @Test func booksWithTrailingNumbersAndLatinSuffixJoinTheSeries() {
        let books = Self.finalized(["雪鍋～小ネタ集～", "雪鍋2～続き(仮)話 +おまけ1～", "雪鍋3", "雪鍋4", "雪鍋exとっておき"])
        #expect(books.allSatisfy { $0.series == "雪鍋" })
        #expect(books.map(\.volumeNumber) == [1, 2, 3, 4, nil])
    }

    @Test func differentMediaTypesAreNotTheSameSeries() {
        // 本の種別(@mediatype)が違う本は同じシリーズにしない。種別の名前は合成したもの。
        let names = [("種別A", "月の庭"), ("種別A", "月の庭 2つめ"), ("種別C", "月の庭 ～作品集～")]
        let files = names.enumerated().map {
            BookFile(path: "/nowhere/\($0.offset)", relativePath: "\($0.offset)",
                     baseName: "[架空工房] \($0.element.1)", fileExtension: "cbz")
        }
        var books = BookScanner.proposals(from: files)
        for i in books.indices { books[i].parsed.mediaType = names[i].0 }
        var doc = ProposalDocument(rootPath: "/nowhere", minPrefix: 4, books: books, groups: SeriesGrouper().group(books))
        ProposalFinalizer.finalize(&doc)
        #expect(doc.books.map(\.series) == ["月の庭", "月の庭", ""])
        #expect(doc.books.map(\.volumeNumber) == [1, 2, nil])
    }

    @Test func differentGenresAreNotTheSameSeries() {
        func books(_ items: [(String, String)]) -> [BookProposal] {
            BookScanner.proposals(from: items.enumerated().map {
                BookFile(path: "/nowhere/\($0.offset)", relativePath: "\($0.offset)",
                         baseName: "[架空工房] \($0.element.0) (\($0.element.1))", fileExtension: "cbz")
            })
        }
        #expect(SeriesGrouper().group(books([("NEON 夜の街", "作品A"), ("NEON 朝の港", "作品B")])).isEmpty)
        // 同じネタなら組になる。ネタの無い本は大きい方の組へ入る。
        let b = BookScanner.proposals(from: [
            "[架空工房] 月の庭 2 (作品A)", "[架空工房] 月の庭 3 (作品A)", "[架空工房] 月の庭 番外", "[架空工房] 月の庭 4 (作品B)",
        ].enumerated().map { BookFile(path: "/nowhere/\($0.offset)", relativePath: "\($0.offset)", baseName: $0.element,
                                      fileExtension: "cbz") })
        let groups = SeriesGrouper().group(b)
        #expect(groups.map(\.memberIDs) == [[1, 2, 3]])
    }

    @Test func leadingKanjiNumeralsReadOnlyWhenSeveralSiblingsUseThem() {
        let books = Self.finalized(["月の庭", "月の庭 三つ星", "月の庭 二つ灯"])
        #expect(books.map(\.volumeNumber) == [1, 3, 2])
        #expect(books.map(\.volumeText) == ["1", "三", "二"])
        // 1 冊だけなら漢数字としては読まない(「三人の夜」のような普通の言葉かもしれない)。
        // (番号の無い 1 冊として 1 巻の推定は働く)
        let single = Self.finalized(["月の庭 2", "月の庭 三人の夜"])
        #expect(single.map(\.volumeText) == ["2", "1"])
    }

    @Test func ordinalWithAnyCounter() {
        let books = Self.finalized(["月の庭 第1幕", "月の庭 第2幕", "月の庭 第3幕"])
        #expect(books.map(\.series) == ["月の庭", "月の庭", "月の庭"])
        #expect(books.map(\.volumeNumber) == [1, 2, 3])
    }

    @Test func labelIntroducerIsNotPartOfTheName() {
        let books = Self.finalized(["月の庭 side NIGHT", "月の庭 side MOON"])
        #expect(books.map(\.series) == ["月の庭", "月の庭"])
    }

    @Test func romanNumeralVolumes() {
        let books = Self.finalized(["月の庭 I", "月の庭 II", "月の庭 Ⅲ"])
        #expect(books.map(\.series) == ["月の庭", "月の庭", "月の庭"])
        #expect(books.map(\.volumeNumber) == [1, 2, 3])
        let inferred = Self.finalized(["月の庭", "月の庭 II", "月の庭 III"])
        #expect(inferred.map(\.volumeText) == ["I", "II", "III"])
    }

    @Test func closingBracketOfTheSeriesNameIsKept() {
        let books = Self.finalized(["【架空の夏】月の庭の話", "【架空の夏】雨の日の話"])
        #expect(books.map(\.series) == ["【架空の夏】", "【架空の夏】"])
        let numbered = Self.finalized(["【架空の夏】 2", "【架空の夏】 3"])
        #expect(numbered.map(\.series) == ["【架空の夏】", "【架空の夏】"])
        #expect(numbered.map(\.volumeNumber) == [2, 3])
    }

    @Test func exclamationAfterTheNameIsKept() {
        let books = Self.finalized(["月がきれいでしかたない！", "月がきれいでしかたない！2 真夏の夜"])
        #expect(books.map(\.series) == ["月がきれいでしかたない！", "月がきれいでしかたない！"])
        #expect(books.map(\.volumeNumber) == [1, 2])
    }

    @Test func leadingBracketIsKept() {
        let books = Self.finalized(["【架空の夏】月の庭 2巻", "【架空の夏】月の庭 3巻"])
        #expect(books.map(\.series) == ["【架空の夏】月の庭", "【架空の夏】月の庭"])
        #expect(books.map(\.volumeNumber) == [2, 3])
    }

    @Test func markerInsideSeriesNameDoesNotBlock() {
        // シリーズ名そのものに「総集編」が入っている場合。番号はゼロ埋めにそろえる。
        let books = Self.finalized(["架空録 総集編 02", "架空録 総集編 03", "架空録 総集編"])
        #expect(books.map(\.volumeText) == ["02", "03", "01"])
        #expect(books[2].volumeNumber == 1)
    }

    @Test func titleEqualToSeriesWinsAmongSeveralUnnumbered() {
        let books = Self.finalized(["星降る夜の喫茶店", "星降る夜の喫茶店 冬の章", "星降る夜の喫茶店 2"])
        #expect(books.map(\.volumeNumber) == [1, nil, 2])
    }

    @Test(arguments: [
        ["星降る夜の喫茶店 春の章", "星降る夜の喫茶店 冬の章", "星降る夜の喫茶店 2"],  // 番号の無い本が 2 冊、どちらも副題付き
        ["星降る夜の喫茶店", "星降る夜の喫茶店 1", "星降る夜の喫茶店 2"],      // 1 巻がすでにある
        ["星降る夜の喫茶店 総集編", "星降る夜の喫茶店 2"],                      // 1 冊目ではない語
    ])
    func notInferred(titles: [String]) {
        #expect(!Self.finalized(titles).contains { $0.volumeInferred == true })
    }
}

@Suite struct QooLibraryNameParserTests {
    // 本の種別の名前は合成したもの(実在の種別の名前は蔵書のフォルダ名と同じことが多く、書けない)。
    @Test func readsMediaTypeFromTheVocabulary() throws {
        let parser = try QooLibraryNameParser(mediaTypes: ["種別A", "種別B"])
        let p = try #require(parser.parse(baseName: "(種別A) [架空工房 (山田太郎)] 月の庭 2 (オリジナル)"))
        #expect(p.mediaType == "種別A")
        #expect(p.circle == "架空工房")
        #expect(p.authors == ["山田太郎"])
        #expect(p.title == "月の庭 2")
        #expect(p.trailing == "オリジナル")
    }

    @Test func leadingParenOutsideTheVocabularyIsAnEvent() throws {
        let parser = try QooLibraryNameParser(mediaTypes: ["種別A"])
        let p = try #require(parser.parse(baseName: "(架空祭7) [架空工房] 月の庭"))
        #expect(p.event == "架空祭7")
        #expect((p.mediaType ?? "").isEmpty)
        #expect(p.title == "月の庭")
    }

    @Test func protectedYearIsNotTakenAsGenre() throws {
        let parser = try QooLibraryNameParser(mediaTypes: ["種別A"])
        let p = try #require(parser.parse(baseName: "(種別A) [架空工房] 月の庭 (2019)"))
        #expect(p.title == "月の庭 (2019)")
        #expect(p.trailing.isEmpty)
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
        #expect(second["Volume"] == nil)  // 「上」は数値にしない
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
