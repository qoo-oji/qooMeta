import Foundation
import Testing
@testable import QooMetaKit

// qooMeta の欄(BookMetadata)。値はすべて架空のもの。

@Suite struct BookMetadataTests {
    static let sample = BookMetadata(
        title: "星降る夜の喫茶店 3", authors: ["架空工房", "月見そば太郎", "原案の人"], genres: ["架空ジャンル"],
        relations: ["架空の原作"], keywordsA: ["甲"], keywordsB: ["乙", "丙"], keywordsC: [], type: "厚い本",
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
        #expect(m.values(.genres) == ["架空ジャンル"])
        #expect(m.values(.relations) == ["架空の原作"])
        #expect(m.values(.keywordsB) == ["乙", "丙"])
        #expect(m.values(.keywordsC).isEmpty)
        #expect(m.values(.type) == ["厚い本"])
        #expect(m.values(.series) == ["星降る夜の喫茶店"])
        #expect(m.values(.volume) == ["3"])
    }

    @Test func listFields() {
        let lists = BookMetadata.Field.allCases.filter(\.isList)
        #expect(lists == [.authors, .genres, .relations, .keywordsA, .keywordsB, .keywordsC])
    }

    @Test func setDropsEmptyValues() {
        var m = Self.sample
        m.set(.genres, to: ["別の架空ジャンル", ""])
        #expect(m.genres == ["別の架空ジャンル"])
        m.set(.relations, to: [])
        #expect(m.relations.isEmpty)
        m.set(.memo, to: [""])
        #expect(m.memo.isEmpty)
        // 書き換えた欄のほかは変わらない。
        #expect(m.authors == Self.sample.authors)
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
