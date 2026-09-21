import Foundation
import QooMetaExport
@testable import QooMetaKit
import QooMetaRules
import QooMetaScan
import Testing

/// 名前は外から来るもので、長さも中身も選べない。**どんな名前でも落ちない・固まらない**ことを確かめる
/// (2026-09-21 の監査で見つけた所)。名前は合成したものだけ。
@Suite struct RobustnessTests {
    /// 20 桁の数字の並びも巻として読める。その数は Int に収まらないので、文字にするときに `Int` へ直さない。
    @Test func aVolumeNumberBeyondIntDoesNotCrash() throws {
        #expect(BookMetadata.volumeSortText(3) == "3")
        #expect(BookMetadata.volumeSortText(4.5) == "4.5")
        #expect(BookMetadata.volumeSortText(1.2345678901234567e19) == "1.2345678901234567e+19")
        #expect(BookMetadata.volumeSortText(.infinity) == "inf")

        let books = inputs(["[架空工房] 月の庭 (12345678901234567890)", "[架空工房] 星の海 (2)"], preset: "commercial")
        let set = proposeSync(books, rules: .builtin, dictionaries: allDictionaries)
        #expect(set["000"]?.metadata.volumeSort == 1.2345678901234567e19)
        let files = Dictionary(uniqueKeysWithValues: books.map { ($0.id, Exporter.FileFacts(path: "/合成/" + $0.id, fileExtension: "cbz")) })
        // 書き出しの対応表は、巻数(ソート用)を文字にして数える。ここで落ちていた。
        _ = Exporter.preview(set, mapping: .standard(for: .stackNest))
        #expect(try !Exporter.stackroomXML(set, files: files).isEmpty)
    }

    /// 位取りの漢数字が Int に収まらないほど続いても、あふれて落ちない(数として読まないだけ)。
    @Test func aLongRunOfKanjiDigitsDoesNotOverflow() {
        #expect(VolumeExtractor.kanjiNumber(String(repeating: "九", count: 18)) == 999_999_999_999_999_999)
        #expect(VolumeExtractor.kanjiNumber(String(repeating: "九", count: 19)) == nil)
        #expect(VolumeExtractor.kanjiNumber(String(repeating: "一", count: 200)) == nil)
        let long = String(repeating: "九", count: 20)
        let set = proposeSync(inputs(["[架空工房] 月の庭 第\(long)巻", "[架空工房] 月の庭 第2巻"]),
                              rules: .builtin, dictionaries: allDictionaries)
        #expect(set.proposals.count == 2)
    }

    /// 前半部分で始まる鍵があるか(並べた鍵を二分探索で探す)。総当たりと同じ答えになる。
    @Test func prefixSearchAgreesWithTheExhaustiveOne() {
        let keys = ["つきのにわ", "つきのにわ2", "ほしのうみ", "ほしのうみ3", "よるのもり", "a", "ab", "b"].sorted()
        for prefix in ["つき", "つきのにわ2", "つきのにわ3", "ほしのうみ", "よ", "よるのもりの", "a", "ab", "abc", "c", "あ", "ん"] {
            #expect(SeriesGrouper.anyHasPrefix(prefix, inSorted: keys) == keys.contains { $0.hasPrefix(prefix) })
        }
        #expect(!SeriesGrouper.anyHasPrefix("a", inSorted: []))
    }

    /// 書き手の読めない名前は、蔵書の全体が 1 つの単位になる。冊数の 2 乗の時間がかかると、1 万冊で操作のたびに
    /// 数秒待つことになる。**時間では確かめず**(機械で変わる)、頭の組を鍵で引く道と総当たりの道で、結果が同じことを確かめる。
    @Test func aUnitOfManyBooksGroupsTheSameAsSmallUnits() {
        // 同じ本を、書き手あり(小さな単位に分かれる)と書き手なし(1 つの単位)で読む。題は書き手ごとに違うので、
        // シリーズの組は同じになるはず。
        var withWriter: [String] = [], withoutWriter: [String] = []
        for writer in 0..<40 {
            let title = "合成の題\(String(UnicodeScalar(0x30A2 + writer * 2)!))\(String(UnicodeScalar(0x30A2 + writer)!))ノ話"
            for tail in ["", " 2", " 第3巻", " 番外編", " リベンジ"] {
                withWriter.append("[架空の書き手\(writer)] \(title)\(tail)")
                withoutWriter.append("\(title)\(tail)")
            }
        }
        let a = proposeSync(inputs(withWriter), rules: .builtin, dictionaries: allDictionaries)
        let b = proposeSync(inputs(withoutWriter), rules: .builtin, dictionaries: allDictionaries)
        #expect(a.series.count == 40 && b.series.count == 40)
        #expect(a.series.map(\.memberIDs).sorted { $0.lexicographicallyPrecedes($1) }
            == b.series.map(\.memberIDs).sorted { $0.lexicographicallyPrecedes($1) })
    }

    /// フォルダと、その中のファイルを一緒に選んでも、同じ本は 1 冊(本の ID が重ならない)。
    @Test func pickingAFolderAndAFileInsideItFindsTheBookOnce() throws {
        let root = try FolderScannerTests.tree(["棚/[架空工房] 月の庭 1.zip", "棚/[架空工房] 月の庭 2.zip", "別の棚/[架空工房] 星の海.zip"])
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = root.appendingPathComponent("棚")
        let found = try FolderScanner.scan(items: [shelf, shelf.appendingPathComponent("[架空工房] 月の庭 1.zip"),
                                                   root.appendingPathComponent("別の棚/[架空工房] 星の海.zip")])
        #expect(found.files.map(\.relativePath) == ["別の棚/[架空工房] 星の海.zip", "棚/[架空工房] 月の庭 1.zip", "棚/[架空工房] 月の庭 2.zip"])
    }

    /// 取り消された走査は、途中までの結果を返さずに投げる(呼び出し側が、古い結果で新しい一覧を押しのけないように)。
    @Test func aCancelledScanThrows() async throws {
        let root = try FolderScannerTests.tree(["棚/[架空工房] 月の庭 1.zip"])
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task.detached { () throws -> Int in
            // 取り消しが届いてから走査を始める。
            while !Task.isCancelled { await Task.yield() }
            return try FolderScanner.scan(root: root).count
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// 語の集合(詰めて持つ形)は、文字列の集合と同じ答えを返す。
@Suite struct WordSetTests {
    @Test func packedWordsAnswerLikeASet() {
        let words = ["Moon", "garden", "GARDEN", "a", "zebra", "naïve", "月", "moons", ""]
        let packed = WordSet(words), reference = Set(words.map { $0.lowercased() })
        #expect(packed.count == reference.count)
        for probe in reference.union(["moo", "moonx", "gardens", "z", "zebr", "月の", "naive", "b"]) {
            #expect(packed.contains(probe) == reference.contains(probe), "\(probe)")
        }
        // 1 行 1 語のテキストから作っても同じ(改行の形が混ざっていても)。
        let lines = WordSet(lines: Data("Moon\ngarden\r\nGARDEN\n\na\nzebra\nnaïve\n月\nmoons".utf8))
        #expect(lines == WordSet(words.filter { !$0.isEmpty }))
        #expect(WordSet([]).count == 0 && !WordSet([]).contains("a"))
    }

    /// macOS の英単語の一覧(あれば)。読んだ語は、どれも引ける。
    @Test func theSystemWordListIsFullySearchable() throws {
        guard let english = SystemDictionaries.english,
              let text = try? String(contentsOfFile: SystemDictionaries.englishPath, encoding: .utf8) else { return }
        let reference = Set(text.split(separator: "\n").map { $0.lowercased() })
        #expect(english.count == reference.count)
        for word in reference where word.count % 7 == 0 { #expect(english.contains(word), "\(word)") }
        for probe in ["qwzx", "theee", "zzzzzz"] { #expect(english.contains(probe) == reference.contains(probe)) }
    }
}

/// 冊数が増えても、計算の時間が冊数の 2 乗で伸びない。
///
/// **秒数では確かめない**(機械で変わる)。冊数を 4 倍にしたときの時間の比を見る: 冊数に比例するなら 4 倍前後、
/// 2 乗なら 16 倍。書き手の読めない名前(全冊が 1 つの単位)が、いちばん伸びやすい形(2026-09-21 の監査で 2 乗だった所)。
@Suite(.serialized) struct ScalingTests {
    static func names(_ count: Int) -> [BookInput] {
        let kana = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワ")
        var state: UInt64 = 42
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let tails = ["", " 2", " 3", " 第4巻", " 上", " 番外編", " 総集編"]
        return (0..<count).map { i in
            BookInput(id: "\(i)", name: String((0..<(3 + next(6))).map { _ in kana[next(kana.count)] }) + tails[next(tails.count)],
                      preset: "doujinshi")
        }
    }

    static func seconds(_ body: () -> Void) -> Double {
        // 3 回のうち、いちばん速い回(ほかのテストと並んで走るので、遅いほうへはぶれる)。
        (0..<3).map { _ in let start = Date(); body(); return Date().timeIntervalSince(start) }.min()!
    }

    @Test func oneHugeUnitDoesNotGrowQuadratically() {
        let small = Self.names(2_000), large = Self.names(8_000)
        _ = proposeSync(small, rules: .builtin, dictionaries: [:])  // 最初の 1 回は、規則の組み立てなどが乗る
        let a = Self.seconds { _ = proposeSync(small, rules: .builtin, dictionaries: [:]) }
        let b = Self.seconds { _ = proposeSync(large, rules: .builtin, dictionaries: [:]) }
        #expect(b / a < 9, "4 倍の冊数で \(b / a) 倍の時間(2 乗なら 16 倍)")
    }

    /// 1 冊の変更は、蔵書の大きさに比例しない(索引の状態を丸ごと写していた頃は、比例していた)。
    @Test func oneChangeDoesNotScaleWithTheLibrary() async throws {
        func median(_ count: Int) async throws -> Double {
            let books = (0..<count).map { BookInput(id: "\($0)", name: "[架空の書き手\($0 / 3)] 合成の題\($0 / 3) 第\($0 % 3 + 1)巻", preset: "doujinshi") }
            let index = ProposalIndex(rules: .builtin, dictionaries: [:])
            try await index.load(books)
            var times: [Double] = []
            for book in books.prefix(60) {
                let start = Date()
                try await index.apply([.upsert(book)])
                times.append(Date().timeIntervalSince(start))
            }
            return times.sorted()[times.count / 2]
        }
        let a = try await median(2_000), b = try await median(20_000)
        #expect(b / a < 4, "10 倍の冊数で \(b / a) 倍の時間")
    }
}
