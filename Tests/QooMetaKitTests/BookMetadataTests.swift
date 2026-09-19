import Foundation
import Testing
@testable import QooMetaKit
import QooMetaRules

// qooMeta の欄(BookMetadata)。値はすべて架空のもの。

@Suite struct BookMetadataTests {
    static let sample = BookMetadata(
        title: "星降る夜の喫茶店 3", authors: ["架空工房", "月見そば太郎", "原案の人"], genre: "架空ジャンル",
        source: "架空の原作", keywordA: "甲", keywordB: "乙", keywordC: "",
        memo: "手元のメモ", series: "星降る夜の喫茶店", volume: "3", volumeNumber: 3)

    @Test func emptyByDefault() {
        let m = BookMetadata()
        for field in BookMetadata.Field.allCases {
            #expect(m.values(field).isEmpty, "\(field)")
        }
        #expect(m.volumeNumber == nil)
    }

    @Test func valuesOfEachField() {
        let m = Self.sample
        #expect(m.values(.title) == ["星降る夜の喫茶店 3"])
        #expect(m.values(.authors) == ["架空工房", "月見そば太郎", "原案の人"])
        #expect(m.values(.genre) == ["架空ジャンル"])
        #expect(m.values(.source) == ["架空の原作"])
        #expect(m.values(.keywordB) == ["乙"])
        #expect(m.values(.keywordC).isEmpty)
        #expect(m.values(.series) == ["星降る夜の喫茶店"])
        #expect(m.values(.volume) == ["3"])
    }

    @Test func listFields() {
        // 並びは著者だけ。
        #expect(BookMetadata.Field.allCases.filter(\.isList) == [.authors])
    }

    @Test func setDropsEmptyValues() {
        var m = Self.sample
        m.set(.authors, to: ["別の架空工房", ""])
        #expect(m.authors == ["別の架空工房"])
        m.set(.source, to: [])
        #expect(m.source.isEmpty)
        m.set(.memo, to: [""])
        #expect(m.memo.isEmpty)
        // 書き換えた欄のほかは変わらない。
        #expect(m.genre == Self.sample.genre)
        #expect(m.title == Self.sample.title)
    }

    @Test func settingEveryFieldRoundTrips() {
        var m = BookMetadata()
        for field in BookMetadata.Field.allCases {
            m.set(field, to: field.isList ? ["一", "二"] : ["一"])
        }
        for field in BookMetadata.Field.allCases {
            #expect(m.values(field) == (field.isList ? ["一", "二"] : ["一"]), "\(field)")
        }
    }

    @Test func changingVolumeTextDropsNumber() {
        var m = Self.sample
        m.set(.volume, to: ["3"])
        #expect(m.volumeNumber == 3)  // 同じ表記なら数は残す
        m.set(.volume, to: ["上"])
        #expect(m.volume == "上")
        #expect(m.volumeNumber == nil)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        #expect(try JSONDecoder().decode(BookMetadata.self, from: data) == Self.sample)
    }
}

@Suite struct SeriesDerivationTests {
    static let derivation = SeriesDerivation(rules: .builtin, vocabulary: Vocabulary(dictionaries: SystemDictionaries.all))

    static func books(_ items: [(author: String, genre: String, title: String)]) -> [SeriesDerivation.Book] {
        items.enumerated().map { i, item in
            SeriesDerivation.Book(id: String(format: "%03d", i), metadata: BookMetadata(
                title: item.title, authors: item.author.isEmpty ? [] : [item.author],
                genre: item.genre))
        }
    }

    @Test func seriesAndVolumeFromFields() {
        let r = Self.derivation.derive(Self.books([("架空工房", "", "月の庭 1"), ("架空工房", "", "月の庭 2"), ("架空工房", "", "星の坂")]))
        #expect(r["000"]?.series == "月の庭")
        #expect(r["001"]?.volume?.text == "2")
        #expect(r["000"]?.seriesID == r["001"]?.seriesID)
        #expect(r["002"]?.series == nil)
    }

    @Test func differentGenresSplitUntilRewritten() {
        var books = Self.books([("架空工房", "架空の催し", "月の庭 1"), ("架空工房", "架空ジャンル", "月の庭 2")])
        #expect(Self.derivation.derive(books)["000"]?.series == nil)
        // 全冊のジャンルを書き換えると、1 つのシリーズになる。
        for i in books.indices { books[i].metadata.set(.genre, to: ["架空ジャンル"]) }
        let r = Self.derivation.derive(books)
        #expect(r["000"]?.series == "月の庭")
        #expect(r["000"]?.seriesID == r["001"]?.seriesID)
    }

    @Test func booksWithoutAuthorsFormOneUnit() {
        let r = Self.derivation.derive(Self.books([("", "", "架空月報 2031年5月号"), ("", "", "架空月報 2031年6月号")]))
        #expect(r["000"]?.seriesID != nil)
        #expect(r["000"]?.seriesID == r["001"]?.seriesID)
    }
}
