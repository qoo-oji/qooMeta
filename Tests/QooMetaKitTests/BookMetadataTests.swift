import Foundation
import Testing
@testable import QooMetaKit
import QooMetaRules

// qooMeta の欄(BookMetadata)。値はすべて架空のもの。

@Suite struct BookMetadataTests {
    static let sample = BookMetadata(
        title: "星降る夜の喫茶店 3", authors: ["架空工房", "月見そば太郎", "原案の人"], genre: "架空ジャンル",
        source: "架空の原作",
        info: "付記", series: "星降る夜の喫茶店", volume: "3", volumeSort: 3)

    @Test func emptyByDefault() {
        let m = BookMetadata()
        for field in BookMetadata.Field.allCases {
            #expect(m.values(field).isEmpty, "\(field)")
        }
        #expect(m.volumeSort == nil)
    }

    @Test func valuesOfEachField() {
        let m = Self.sample
        #expect(m.values(.title) == ["星降る夜の喫茶店 3"])
        #expect(m.values(.authors) == ["架空工房", "月見そば太郎", "原案の人"])
        #expect(m.values(.genre) == ["架空ジャンル"])
        #expect(m.values(.source) == ["架空の原作"])
        #expect(m.values(.event).isEmpty)
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
        m.set(.info, to: [""])
        #expect(m.info.isEmpty)
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

    @Test func changingVolumeDropsSortKey() {
        var m = Self.sample
        m.set(.volume, to: ["3"])
        #expect(m.volumeSort == 3)  // 同じ表記なら数は残す
        m.set(.volume, to: ["上"])
        #expect(m.volume == "上")
        #expect(m.volumeSort == nil)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        #expect(try JSONDecoder().decode(BookMetadata.self, from: data) == Self.sample)
    }

    /// シリーズと巻数のほかの欄は、値をいくつでも持てる。先頭が欄、2 つ目からは足した値。
    @Test func fieldsHoldSeveralValues() {
        #expect(BookMetadata.Field.allCases.filter { !$0.holdsSeveral } == [.series, .volume])
        var m = Self.sample
        m.set(.info, to: ["付記", "", "もう 1 つの付記"])
        #expect(m.info == "付記")
        #expect(m.values(.info) == ["付記", "もう 1 つの付記"])
        #expect(m[.info] == "付記")
        // 1 つに戻すと、足した値は消える。
        m.set(.info, to: ["別の付記"])
        #expect(m.values(.info) == ["別の付記"])
        #expect(m.moreValues.isEmpty)
        // シリーズと巻数は先頭だけ(足したシリーズは別に持つ)。
        m.set(.series, to: ["架空の本編", "架空の外伝"])
        #expect(m.values(.series) == ["架空の本編"])
    }

    /// 足した値・足したシリーズは、あるときだけ書く。前の版が書いた JSON(鍵が無い)も読める。
    @Test func extraValuesAreWrittenOnlyWhenPresent() throws {
        let plain = String(decoding: try JSONEncoder().encode(Self.sample), as: UTF8.self)
        #expect(!plain.contains("moreValues") && !plain.contains("alternateSeries"))

        var m = Self.sample
        m.set(.genre, to: ["架空ジャンル", "別の架空ジャンル"])
        m.alternateSeries = [.init(name: "架空の外伝", volume: "2", volumeSort: 2)]
        let data = try JSONEncoder().encode(m)
        #expect(String(decoding: data, as: UTF8.self).contains(#""moreValues":{"genre":["別の架空ジャンル"]}"#))
        #expect(try JSONDecoder().decode(BookMetadata.self, from: data) == m)

        let confirmed = ConfirmedFields([.info: ["一", "二"]], alternateSeries: m.alternateSeries)
        #expect(try JSONDecoder().decode(ConfirmedFields.self, from: JSONEncoder().encode(confirmed)) == confirmed)
        let old = Data(#"{"values":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ConfirmedFields.self, from: old) == ConfirmedFields())
    }

    /// 確定した欄を重ねると、足した値と足したシリーズも入る。足したシリーズの巻数(ソート用)は、確定していなければ表記から読む。
    @Test func confirmedExtrasReachTheProposal() throws {
        let fields = ConfirmedFields([.info: ["付記", "もう 1 つの付記"]],
                                     alternateSeries: [.init(name: "架空の外伝", volume: "第3巻"),
                                                       .init(name: "架空の別編", volume: "上", volumeSort: 1.5)])
        let set = proposeSync([BookInput(id: "a.cbz", name: "[架空工房] 月の庭 2", confirmation: .fields(fields))],
                              rules: .builtin, dictionaries: [:])
        let m = try #require(set["a.cbz"]).metadata
        #expect(m.values(.info) == ["付記", "もう 1 つの付記"])
        #expect(m.alternateSeries.map(\.name) == ["架空の外伝", "架空の別編"])
        #expect(m.alternateSeries[0].volumeSort == 3)
        #expect(m.alternateSeries[1].volumeSort == 1.5)
        // 主のシリーズは中核が導いたまま(足したシリーズは組み分けに使わない)。
        #expect(m.series != "架空の外伝")
    }
}

@Suite struct SeriesDerivationTests {
    static let derivation = SeriesDerivation(rules: .builtin, dictionaries: SystemDictionaries.all)

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
