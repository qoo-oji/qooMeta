import Foundation
import Testing
@testable import QooMetaKit
import QooMetaRules

// 公開する API(docs/api.md)の約束。名前はすべて架空のもの。

/// テストの名前は同人誌の命名で書いてあるので、断りがなければ同人誌のプリセットで読む
/// (同梱の既定は商業誌。2026-09-21 に「混ざった蔵書」の並びをやめた)。
func inputs(_ names: [String], preset: String? = "doujinshi") -> [BookInput] {
    names.enumerated().map { BookInput(id: String(format: "%03d", $0.offset), name: $0.element, preset: preset) }
}

func seriesName(_ set: ProposalSet, _ id: String) -> String? {
    set[id]?.seriesID.flatMap { set.series($0)?.name }
}

let allDictionaries = SystemDictionaries.all

@Suite struct ParseNameTests {
    @Test func fieldsAndFormat() {
        let r = parseName("(種別A) [架空工房 (山田太郎)] 月の庭 第3巻 (作品A) [DL版]", rules: .builtin, preset: "doujinshi")
        #expect(r.metadata.genre == "種別A")
        #expect(r.metadata.event.isEmpty)
        #expect(r.metadata.authors == ["架空工房", "山田太郎"])
        #expect(r.metadata.title == "月の庭 第3巻")
        #expect(r.metadata.source == "作品A")
        #expect(r.metadata.info == "DL版")
        #expect(r.formatIndex == 0)
    }

    @Test func unmatchedNameIsAProvisionalTitle() {
        let r = parseName("ただのファイル名", rules: .builtin)
        #expect(r.formatIndex == nil)
        #expect(r.metadata.title == "ただのファイル名")
        #expect(r.metadata.authors.isEmpty)
    }
}

@Suite struct ProposeSyncTests {
    /// 位取りで書いた漢数字を、桁として読む。「二一」は 1 ではなく 21(数え上げの読み方では読めない形)。
    ///
    /// **「〇」は数として扱わない。** 伏せ字(「〇〇さん」)にも使う字で、0 のつもりとは限らないため
    /// (2026-09-20、利用者の判断)。「第二〇巻」のように単位の付く形だけ、漢数字の読み手が読む。
    @Test func kanjiNumeralsAreReadByPlace() {
        #expect(VolumeExtractor.kanjiNumber("二一") == 21)
        #expect(VolumeExtractor.kanjiNumber("二〇二五") == 2025)
        #expect(VolumeExtractor.kanjiNumber("十二") == 12)
        #expect(VolumeExtractor.kanjiNumber("三百二十一") == 321)
        #expect(VolumeExtractor.kanjiNumber("〇") == nil && VolumeExtractor.kanjiNumber("〇〇") == nil)
        // 「〇」は数字の途中とはみなさないので、共通部分はそこで切れる(シリーズ名に「〇」が残る)。
        let books = inputs(["[架空工房] 月の庭〇2 はる", "[架空工房] 月の庭〇3 なつ"])
        let set = proposeSync(books, rules: .builtin, dictionaries: allDictionaries)
        #expect(books.allSatisfy { seriesName(set, $0.id) == "月の庭〇" })
        #expect(set["000"]?.metadata.volume == "2" && set["001"]?.metadata.volume == "3")
    }

    /// 共通部分は**数の途中で切らない**。「月の庭01 はる」「月の庭02 なつ」の共通部分は「月の庭0」だが、
    /// それは 01・02 という 1 つの数の途中。シリーズ名は「月の庭」(2026-09-20、利用者の指摘)。
    @Test func aSharedPrefixDoesNotStopInsideANumber() {
        let books = inputs(["[架空工房] 月の庭01 はる", "[架空工房] 月の庭02 なつ", "[架空工房] 月の庭03 あき"])
        let set = proposeSync(books, rules: .builtin, dictionaries: allDictionaries)
        #expect(books.allSatisfy { seriesName(set, $0.id) == "月の庭" })
        // ゼロ詰めの表記はそのまま残す(「第01巻」「月の庭 01」と同じ扱い)。
        #expect(set["000"]?.metadata.volume == "01" && set["002"]?.metadata.volume == "03")
    }

    @Test func rejectedInputs() {
        var limits = InputLimits()
        limits.maxNameLength = 20
        let set = proposeSync([
            BookInput(id: "a", name: "[架空工房] 月の庭 1"),
            BookInput(id: "a", name: "[架空工房] 月の庭 2"),
            BookInput(id: "b", name: "   "),
            BookInput(id: "c", name: String(repeating: "月", count: 21)),
            BookInput(id: "d", name: "月の庭"),
        ], rules: .builtin, dictionaries: [:], options: ProposalOptions(limits: limits))
        #expect(set.proposals.map(\.id) == ["a", "d"])
        #expect(set.rejected.map(\.reason) == [.duplicateID, .emptyName, .nameTooLong])
    }

    /// 見えない文字(書式文字)で組が割れない。
    @Test func formatCharactersAreDropped() {
        let set = proposeSync(inputs(["[架空工房] 月の\u{200B}庭 1", "[架空工房] 月の庭 2"]), rules: .builtin, dictionaries: [:])
        #expect(seriesName(set, "000") == "月の庭")
        #expect(seriesName(set, "001") == "月の庭")
    }

    /// 同じ入力なら同じ結果(ID も)。入力の並びを変えても、シリーズの中身と順は変わらない。
    @Test func deterministicOrderAndIDs() {
        let names = ["[架空工房] 月の庭 2", "[幻想舎] 風の港 1", "[架空工房] 月の庭 1", "[幻想舎] 風の港 2", "[架空工房] 星の歌 1",
                     "[架空工房] 星の歌 2"]
        let a = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        let b = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        #expect(a.series == b.series)
        #expect(a.proposals == b.proposals)
        #expect(a.series.map(\.name) == ["風の港", "星の歌", "月の庭"])  // 書き手(比べる形)→ 名前の順
        let shuffled = inputs(names).reversed()
        let c = proposeSync(Array(shuffled), rules: .builtin, dictionaries: [:])
        #expect(c.series.map(\.name) == a.series.map(\.name))
        #expect(c.series.map(\.memberIDs) == a.series.map(\.memberIDs))
        #expect(a.series.first { $0.name == "月の庭" }?.memberIDs == ["002", "000"])  // 巻の順
    }

    @Test func flagsAndKinds() {
        let set = proposeSync(inputs([
            "[架空工房] 月の庭", "[架空工房] 月の庭 2", "[架空工房] 月の庭 総集編", "[架空工房] 月の庭 3【フルカラー版】",
            "[架空工房] 週刊架空 2025年35号", "[架空工房] 週刊架空 2025年36号",
        ]), rules: .builtin, dictionaries: [:])
        #expect(set["000"]?.flags == [.inferredVolume])
        #expect(set["002"]?.flags == [.compilation])
        #expect(set["003"]?.flags == [.edition])
        #expect(set["004"]?.flags == [.magazineIssue])
        #expect(Set(set.series.map(\.kind)) == [.series, .compilation, .magazineYear])
    }

    @Test func asyncMatchesSyncAndReportsProgress() async throws {
        let names = (1...40).flatMap { i in ["[架空工房\(i % 7)] 月の庭 \(i)", "[幻想舎\(i % 5)] 風の港 \(i) 夜"] }
        let sync = proposeSync(inputs(names), rules: .builtin, dictionaries: [:])
        let progress = ProgressLog()
        let async = try await propose(inputs(names), rules: .builtin, dictionaries: [:]) { progress.add($0) }
        #expect(async.proposals == sync.proposals)
        #expect(async.series == sync.series)
        #expect(progress.last?.completedUnits == progress.last?.totalUnits)
    }

    @Test func cancellation() async {
        let names = (1...200).map { "[架空工房\($0)] 月の庭 \($0)" }
        let task = Task { try await propose(inputs(names), rules: .builtin, dictionaries: [:]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProposalProgress] = []
    func add(_ p: ProposalProgress) { lock.withLock { items.append(p) } }
    var last: ProposalProgress? { lock.withLock { items.last } }
}

@Suite struct ConfirmationTests {
    static func propose(_ items: [(String, QooMetaKit.Confirmation)]) -> ProposalSet {
        proposeSync(items.enumerated().map { BookInput(id: String(format: "%03d", $0.offset), name: $0.element.0,
                                                        confirmation: $0.element.1) },
                    rules: .builtin, dictionaries: SystemDictionaries.all)
    }

    /// 確定した名前は錨になり、規則が同じ組にした未確定の本もその名前に入る。
    @Test func anchorNamesTheWholeGroup() {
        let set = Self.propose([("[架空工房] 月の庭 1", .series(name: "月の庭シリーズ", volume: nil)),
                                ("[架空工房] 月の庭 2", .none), ("[架空工房] 月の庭 3", .none)])
        #expect(["000", "001", "002"].map { seriesName(set, $0) } == Array(repeating: "月の庭シリーズ", count: 3))
        #expect(set.series.first?.evidence == .confirmed)
        #expect(set["000"]?.flags == [.confirmed])
    }

    /// 1 つの組に確定した名前が 2 つあれば割る。未確定の本は、タイトルの先頭がいちばん長く一致する名前へ。
    @Test func twoAnchorsSplitTheGroup() {
        let set = Self.propose([("[架空工房] 星の庭 春の章", .series(name: "星の庭 春", volume: nil)),
                                ("[架空工房] 星の庭 夏の章", .series(name: "星の庭 夏", volume: nil)),
                                ("[架空工房] 星の庭 春の章 続", .none), ("[架空工房] 星の庭 夏の章 続", .none)])
        #expect(["000", "001", "002", "003"].map { seriesName(set, $0) } == ["星の庭 春", "星の庭 夏", "星の庭 春", "星の庭 夏"])
    }

    /// シリーズではないと確定した本は入れない。残りが 2 冊に満たなければシリーズにしない。
    @Test func notInSeries() {
        let three = Self.propose([("[架空工房] 月の庭 1", .notInSeries()), ("[架空工房] 月の庭 2", .none),
                                  ("[架空工房] 月の庭 3", .none)])
        #expect(["000", "001", "002"].map { seriesName(three, $0) } == [nil, "月の庭", "月の庭"])
        let two = Self.propose([("[架空工房] 月の庭 1", .notInSeries()), ("[架空工房] 月の庭 2", .none)])
        #expect(two.series.isEmpty)
    }

    /// 同じ名前に確定した本は、規則が別の組にしていても(組にしていなくても)同じシリーズ。
    @Test func sameConfirmedNameJoins() {
        let set = Self.propose([("[架空工房] 月の庭", .series(name: "庭の本", volume: "1")),
                                ("[架空工房] 風の港", .series(name: "庭の本", volume: "2"))])
        #expect(seriesName(set, "000") == "庭の本")
        #expect(set.series.count == 1)
        #expect(set.series[0].memberIDs == ["000", "001"])
        #expect(set["001"]?.metadata.volume == "2")
        #expect(set["001"]?.metadata.volumeSort == 2)
    }

    /// 確定した巻はそのまま使い、推定は確定した巻を読めた巻として扱う。
    @Test func confirmedVolumes() {
        let set = Self.propose([("[架空工房] 月の庭", .none), ("[架空工房] 月の庭 おまけ", .series(name: "月の庭", volume: "上")),
                                ("[架空工房] 月の庭 2", .none)])
        #expect(set["001"]?.metadata.volume == "上")
        #expect(set["001"]?.metadata.volumeSort == 1)
        #expect(set["000"]?.metadata.volume.isEmpty == true)  // 確定した「上」が 1 巻に当たるので、番号の無い本を 1 巻とは推定しない
    }

    /// 確定した欄は解析の結果より優先し、比べる単位も確定した値で決まる。
    @Test func confirmedFieldsDecideTheUnit() {
        let set = Self.propose([("(種別A) [架空工房] 月の庭 1", .none), ("(種別A) [架空工房] 月の庭 2", .none),
                                ("(種別A) [架空工房] 月の庭 3", .fields(ConfirmedFields([.genre: ["種別B"]])))])
        #expect(["000", "001", "002"].map { seriesName(set, $0) } == ["月の庭", "月の庭", nil])
        #expect(set["002"]?.metadata.genre == "種別B")
    }
}

@Suite struct ProposalIndexTests {
    /// まとめて入れる道(並列)は、1 冊ずつ入れる道・一括の提案と同じ結果になる。重なった ID や断られる名前があっても同じ。
    @Test func loadingInParallelMatchesApplyingOneByOne() async throws {
        var books = inputs(Self.names + (0..<300).map { "[架空の書き手\($0 % 23)] 合成の題\($0 / 3) 第\($0 % 3 + 1)巻" })
        books.append(BookInput(id: "空の名前", name: "   "))
        let batch = proposeSync(books, rules: .builtin, dictionaries: [:])
        let loaded = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await loaded.load(books)
        let applied = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await applied.apply(books.map { .upsert($0) })
        let a = await loaded.snapshot(), b = await applied.snapshot()
        #expect(a.proposals == batch.proposals && a.series == batch.series && a.rejected == batch.rejected)
        #expect(a.proposals == b.proposals && a.series == b.series && a.rejected == b.rejected)
        // 入れたあとの 1 冊の変更も、同じ差分になる。
        let change = BookChange.upsert(BookInput(id: "新しい本", name: "[架空の書き手1] 合成の題0 第9巻", preset: "doujinshi"))
        let x = try await loaded.apply([change]), y = try await applied.apply([change])
        #expect(x.changed == y.changed && x.changedSeries == y.changedSeries)

        // 同じ ID が重なる入力は、後のものが勝つ(1 冊ずつ入れたときと同じ)。
        let doubled = books + [BookInput(id: books[0].id, name: "[架空工房] 別の題", preset: "doujinshi")]
        let c = ProposalIndex(rules: .builtin, dictionaries: [:]), d = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await c.load(doubled)
        try await d.apply(doubled.map { .upsert($0) })
        #expect(await c.snapshot().proposals == d.snapshot().proposals)
    }

    /// 規則を替えて読み直す道(並列。名前の読みを使い回すことがある)は、新しい規則で最初から入れた結果と同じ。
    @Test func reloadingMatchesAFreshIndex() async throws {
        let books = inputs(Self.names + (0..<120).map { "[架空の書き手\($0 % 11)] 合成の題\($0 / 3) 第\($0 % 3 + 1)巻 (合成の原作)" })
        // シリーズの規則だけを変える(名前の読みは使い回される)・巻の読み方を変える(読み直される)の両方。
        let candidates: [(String, CompiledRules?)] = [
            ("grouping", RulesTests.compile(RulesTests.diff(#""grouping": { "sharedPrefix": { "minPrefix": 2 } }"#)).rules),
            ("unnumberedVolume", CompiledRules.builtin.applying(policies: ["unnumberedVolume": "leaveEmpty"]).rules),
            ("magazines", CompiledRules.builtin.applying(policies: ["magazines": "whole"]).rules),
        ]
        for (policies, compiled) in candidates {
            let changed = try #require(compiled)
            let index = ProposalIndex(rules: .builtin, dictionaries: [:])
            try await index.load(books)
            try await index.reload(rules: changed, dictionaries: [:])
            let fresh = proposeSync(books, rules: changed, dictionaries: [:])
            let now = await index.snapshot()
            #expect(now.proposals == fresh.proposals && now.series == fresh.series, "\(policies)")
            #expect(now.rulesHash == changed.contentHash)
        }
    }

    /// 試しただけ(`preview`)と、取り消された変更は、状態を 1 つも変えない(変えた所だけを控えて戻す)。
    @Test func previewAndCancellationLeaveTheStateAlone() async throws {
        let books = inputs(Self.names)
        let index = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await index.load(books)
        let before = await index.snapshot()
        let changes: [BookChange] = [.remove(id: books[0].id), .upsert(BookInput(id: "x", name: "[架空工房] 月の庭 9", preset: "doujinshi")),
                                     .upsert(BookInput(id: books[1].id, name: "[別の書き手] まったく別の題", preset: "doujinshi"))]
        _ = try await index.preview(changes)
        #expect(await index.snapshot().proposals == before.proposals)
        #expect(await index.snapshot().series == before.series)
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await index.apply(changes); return false } catch { return true }
        }
        #expect(await cancelled.value)
        #expect(await index.snapshot().proposals == before.proposals)
        #expect(await index.proposal(for: "x") == nil)
        // そのあとの変更は、ふつうに効く。
        _ = try await index.apply(changes)
        let after = proposeSync([books[1]].map { _ in BookInput(id: books[1].id, name: "[別の書き手] まったく別の題", preset: "doujinshi") }
                                + books.dropFirst(2) + [BookInput(id: "x", name: "[架空工房] 月の庭 9", preset: "doujinshi")],
                                rules: .builtin, dictionaries: [:])
        #expect(Set(await index.snapshot().proposals) == Set(after.proposals))
    }

    static let names = [
        "[架空工房] 月の庭 1", "[架空工房] 月の庭 2", "[架空工房] 月の庭 3", "[架空工房] 風の港", "[架空工房] 風の港 2",
        "[幻想舎] 星の歌 上", "[幻想舎] 星の歌 下", "[幻想舎] 星の歌 総集編", "[白紙堂] 雨の窓 春の章", "[白紙堂] 雨の窓 夏の章",
        "[白紙堂] 雨の窓", "[白紙堂] 雪の町 1", "[白紙堂] 雪の町 2",
    ]

    /// 足す・変える・消すを繰り返しても、索引の結果は同じ一覧を一括で計算した結果と同じ。
    @Test func indexMatchesBatch() async throws {
        let index = ProposalIndex(rules: .builtin, dictionaries: [:])
        var current: [BookInput] = []
        var generator = SplitMix(seed: 7)
        for step in 0..<120 {
            let pick = Self.names[Int(generator.next() % UInt64(Self.names.count))]
            let id = "b\(generator.next() % 20)"
            let change: BookChange
            if generator.next() % 4 == 0 {
                change = .remove(id: id)
                current.removeAll { $0.id == id }
            } else {
                let confirmation: QooMetaKit.Confirmation = generator.next() % 6 == 0 ? .notInSeries() : .none
                let input = BookInput(id: id, name: pick, confirmation: confirmation)
                change = .upsert(input)
                if let i = current.firstIndex(where: { $0.id == id }) { current[i] = input } else { current.append(input) }
            }
            try await index.apply([change])
            if step % 10 == 9 {
                let batch = proposeSync(current, rules: .builtin, dictionaries: [:])
                let snapshot = await index.snapshot()
                #expect(snapshot.proposals == batch.proposals, "step \(step)")
                #expect(snapshot.series == batch.series, "step \(step)")
            }
        }
    }

    @Test func previewDoesNotChangeTheState() async throws {
        let index = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await index.apply(inputs(["[架空工房] 月の庭 1", "[架空工房] 月の庭 2"]).map { .upsert($0) })
        let before = await index.snapshot()
        let delta = try await index.preview([.upsert(BookInput(id: "x", name: "[架空工房] 月の庭 3"))])
        #expect(delta.changed.map(\.id) == ["x"])
        #expect(delta.changedSeries.first?.memberIDs == ["000", "001", "x"])
        #expect(await index.snapshot().proposals == before.proposals)
        #expect(await index.proposal(for: "x") == nil)
    }

    @Test func deltaReportsRemovedSeries() async throws {
        let index = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await index.apply(inputs(["[架空工房] 月の庭 1", "[架空工房] 月の庭 2"]).map { .upsert($0) })
        let seriesID = try #require(await index.proposal(for: "000")?.seriesID)
        let delta = try await index.apply([.remove(id: "001")])
        #expect(delta.removedBooks == ["001"])
        #expect(delta.removedSeries == [seriesID])
        #expect(delta.changed.map(\.id) == ["000"])
    }

    @Test func updateRulesMatchesBatch() async throws {
        let index = ProposalIndex(rules: .builtin, dictionaries: [:])
        try await index.apply(inputs(Self.names).map { .upsert($0) })
        let leaveEmpty = try #require(CompiledRules.builtin.applying(policies: ["unnumberedFirst": "leaveEmpty"]).rules)
        let delta = try await index.update(rules: leaveEmpty, dictionaries: [:])
        let batch = proposeSync(inputs(Self.names), rules: leaveEmpty, dictionaries: [:])
        #expect(await index.snapshot().proposals == batch.proposals)
        #expect(!delta.changed.isEmpty)
    }
}

/// 再現できる擬似乱数(テストの操作の列を毎回同じにする)。
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
