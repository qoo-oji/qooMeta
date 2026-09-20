import Foundation
import Testing
@testable import QooMetaKit

// ファイル名フォーマット(docs/filename-format.md の 1・2・5)。名前はすべて架空のもの。

@Suite struct FilenameFormatTests {
    static func read(_ name: String, _ formats: [String]? = nil) -> FormatReading {
        let set = formats.map { FilenameFormats(formats: $0.map { try! FilenameFormat($0) }) } ?? .preset
        return set.read(name)
    }

    @Test func authorsInNestedBrackets() {
        let r = Self.read("[架空工房 (月見そば太郎、原案の人)] 星降る夜の喫茶店", ["[@author (@author)] @title"])
        #expect(r.formatIndex == 0)
        #expect(r.metadata.authors == ["架空工房", "月見そば太郎", "原案の人"])
        #expect(r.metadata.title == "星降る夜の喫茶店")
    }

    @Test func splitsAtTheLastSeparator() {
        let r = Self.read("月の庭 - 第二部 - 架空作家", ["@title - @author"])
        #expect(r.metadata.title == "月の庭 - 第二部")
        #expect(r.metadata.authors == ["架空作家"])
    }

    @Test func fullWidthBracketsAreTheSame() {
        let r = Self.read("（架空ジャンル）［架空工房（月見そば太郎）］星降る夜の喫茶店（架空の原作）")
        #expect(r.formatIndex == FilenameFormats.presetTexts.firstIndex(of: "(@genre) [@author (@author)] @title (@source)"))
        #expect(r.metadata.genre == "架空ジャンル")
        #expect(r.metadata.authors == ["架空工房", "月見そば太郎"])
        #expect(r.metadata.title == "星降る夜の喫茶店")
        #expect(r.metadata.source == "架空の原作")
    }

    @Test func spacesAreOptional() {
        let r = Self.read("(架空ジャンル)[架空工房]月の庭 2")
        #expect(r.metadata.genre == "架空ジャンル")
        #expect(r.metadata.authors == ["架空工房"])
        #expect(r.metadata.title == "月の庭 2")
    }

    @Test func presetFillsEachPosition() {
        let r = Self.read("(架空ジャンル) [架空工房 (月見そば太郎)] 月の庭 3 (架空の原作) [付記]")
        #expect(r.formatIndex == 2)
        #expect(r.metadata.title == "月の庭 3")
        #expect(r.metadata.source == "架空の原作")
        // 末尾の角括弧は捨てずに情報へ(@info)。
        #expect(r.metadata.info == "付記")
        #expect(r.metadata.event.isEmpty)
        #expect(r.spans.map(\.word) == [.genre, .author, .author, .title, .source, .info])
    }

    @Test func trailingSquareBracketIsInfo() {
        let r = Self.read("[架空工房] 月の庭 [付記]")
        #expect(r.formatIndex == FilenameFormats.presetTexts.firstIndex(of: "[@author] @title [@info]"))
        #expect(r.metadata.info == "付記")
        #expect(r.metadata.title == "月の庭")
    }

    @Test func eventInLeadingParentheses() {
        // 同梱の型は先頭の丸括弧をジャンルとして読む。頒布会の名前を書く利用者は、型で @event にする。
        let r = Self.read("(架空の催し12) [架空工房] 月の庭", ["(@event) [@author] @title"])
        #expect(r.metadata.event == "架空の催し12")
        #expect(r.metadata.genre.isEmpty)
        #expect(Self.read("(架空の催し12) [架空工房] 月の庭").metadata.event.isEmpty)
    }

    @Test func authorsAreSplitBySeparators() {
        let r = Self.read("[架空工房 (甲, 乙、丙)] 月の庭 (原作一、原作二)")
        #expect(r.metadata.authors == ["架空工房", "甲", "乙", "丙"])
        // 並びは著者だけ。原作は 1 つの値(区切りで分けない)。
        #expect(r.metadata.source == "原作一、原作二")
    }

    @Test func separatorsCanBeAdded() {
        var set = FilenameFormats.preset
        #expect(set.read("[作画×原作] 月の庭").metadata.authors == ["作画×原作"])
        set.separators.append("×")
        #expect(set.read("[作画×原作] 月の庭").metadata.authors == ["作画", "原作"])
    }

    /// 「シリーズ名 (巻数) - 著者」の形(商業誌用と既定の並び)。数字だけの丸括弧のすぐ後ろの ` - ` でだけ分ける。
    /// 丸括弧の前はシリーズ名として読み、`@title` の無い型なのでタイトルは型のその部分(`@series (@volume)`)に値をはめる。
    @Test func trailingAuthorAfterTheVolume() {
        let r = FilenameFormats.commercialPreset.read("月の庭（３） - 架空作家")
        #expect(r.metadata.series == "月の庭")
        #expect(r.metadata.title == "月の庭 (3)")
        // じかに付いた文字までがタイトルに入る。巻数の無い型ならシリーズ名だけ。
        #expect(try! FilenameFormats(formats: [FilenameFormat("[@author] @series 第@volume巻 [@info]")])
            .read("[架空工房] 月の庭 第０３巻 [DL版]").metadata.title == "月の庭 第03巻")
        #expect(try! FilenameFormats(formats: [FilenameFormat("@series - @author")]).read("月の庭 - 架空作家").metadata.title == "月の庭")
        #expect(r.metadata.volume == "3")
        #expect(r.spans.map(\.word) == [.series, .volume, .author])
        #expect(r.metadata.authors == ["架空作家"])
        // 末尾の角括弧は著者に入れない(情報の欄へ)。
        let withInfo = FilenameFormats.commercialPreset.read("月の庭 (3) - 架空作家 [DL版]")
        #expect(withInfo.metadata.authors == ["架空作家"])
        #expect(withInfo.metadata.info == "DL版")
        // タイトルの中の ` - ` では分けない。巻数の無い「題名 - 副題」は、どの型にも合わないまま。
        #expect(FilenameFormats.commercialPreset.read("月の庭 - 第二部 (3) - 架空作家").metadata.series == "月の庭 - 第二部")
        #expect(FilenameFormats.commercialPreset.read("月の庭 - 第二部").formatIndex == nil)
        // 角括弧で始まる名前は、これまでどおり角括弧の形で読む。
        #expect(FilenameFormats.commercialPreset.read("[架空工房] 月の庭 (3)").metadata.authors == ["架空工房"])
    }

    /// 区切りは型ごとに決められる。書いた型では、プリセットの区切りを丸ごと置き換える(足し合わせない)。
    @Test func separatorsPerFormat() throws {
        let set = FilenameFormats(formats: [
            try FilenameFormat("[@author] @title"),
            try FilenameFormat("@title (@volume) - @author", separators: ["×"]),
        ])
        // 角括弧の形では「×」は名義の一部。
        #expect(set.read("[作画×原作, 協力] 月の庭").metadata.authors == ["作画×原作", "協力"])
        // 末尾の著者の形では「×」で分け、プリセットの「,」では分けない。
        #expect(set.read("月の庭 (3) - 作画×原作, 協力").metadata.authors == ["作画", "原作, 協力"])
    }

    /// 既定の欄も型ごとに書ける。欄ごとに、型の既定がプリセットの既定より勝つ。名前から読めた値がいちばん強い。
    @Test func defaultsPerFormat() throws {
        let set = FilenameFormats(formats: [
            try FilenameFormat("(@genre) [@author] @title"),
            try FilenameFormat("[@author] @title", defaults: [.genre: ["架空の分類乙"]]),
        ], defaults: [.genre: ["架空の分類甲"], .info: ["架空の付記"]])
        let inner = set.read("[架空工房] 月の庭")
        #expect(inner.metadata.genre == "架空の分類乙")
        #expect(inner.metadata.info == "架空の付記")
        #expect(set.read("(架空の分類丙) [架空工房] 月の庭").metadata.genre == "架空の分類丙")
        #expect(set.read("括弧の無い名前").metadata.genre == "架空の分類甲")
    }

    @Test func spansPointAtTheValues() {
        let name = "[架空工房] 月の庭"
        let r = Self.read(name)
        let chars = Array(name)
        #expect(r.spans.map { String(chars[$0.range]) } == ["架空工房", "月の庭"])
    }

    @Test func unmatchedNameBecomesProvisionalTitle() {
        // 同梱の並びに @title だけの型は無い(直すべき名前を埋もれさせない)。
        let r = Self.read("月の庭 第3号")
        #expect(r.formatIndex == nil)
        #expect(r.metadata.title == "月の庭 第3号")
        #expect(r.metadata.authors.isEmpty)
        // どの型も頭から外れるので、近い型は無い。
        #expect(r.nearest == nil)
    }

    @Test func nearestFormatShowsWhereItBroke() {
        // 角括弧が閉じていない。先頭の丸括弧と著者までは合うので、(@genre) の型が最も近い。
        let formats = ["[@author] @title", "(@genre) [@author] @title"]
        let r = Self.read("(架空ジャンル) [架空工房 月の庭", formats)
        #expect(r.formatIndex == nil)
        #expect(r.nearest?.formatIndex == 1)
        #expect((r.nearest?.matchedCharacters ?? 0) >= "(架空ジャンル) [".count)
    }

    @Test func compileErrors() {
        func error(_ text: String) -> FormatError? {
            do { _ = try FilenameFormat(text); return nil } catch { return error }
        }
        #expect(error("") == .empty)
        #expect(error("[@circle] @title") == .unknownWord("@circle"))
        #expect(error("(@genre) (@genre) @title") == .repeated(.genre))
        #expect(error("[@author]") == .missingTitle)
        // `@series` を書いた型は `@title` を省ける。
        #expect(error("@series (@volume) - @author") == nil)
        #expect(error("[@author] @title (") == .unbalanced("("))
        #expect(error("[@author] @title]") == .unbalanced("]"))
        #expect(error("@title @author") == .adjacent(.title, .author))
        #expect(error("[@author] [@author] @title (@ignore) [@ignore]") == nil)
    }

    @Test func bundledPresets() {
        // 既定の並びは、形ごとに「数字だけの丸括弧 = 巻数」を先に試し、そうでなければ原作として読む。
        #expect(FilenameFormats.presetTexts.count == 26)
        #expect(FilenameFormats.presetTexts.first == "(@genre) [@author (@author)] @title (@volume) [@info]")
        // 著者を末尾に付ける形は、角括弧の形より後ろ(両方に当たる名前は、これまでどおり角括弧の形で読む)。
        #expect(FilenameFormats.presetTexts.suffix(3) == ["[@author] @title", "@series (@volume) - @author [@info]", "@series (@volume) - @author"])
        // 同人誌用は末尾の丸括弧が原作、商業誌用は巻数(著者の中の丸括弧も使わない)。
        #expect(FilenameFormats.doujinshiPresetTexts.count == 16)
        #expect(FilenameFormats.doujinshiPresetTexts.allSatisfy { !$0.contains("@volume") })
        #expect(FilenameFormats.commercialPresetTexts.count == 10)
        #expect(FilenameFormats.commercialPresetTexts.last == "@series (@volume) - @author")
        #expect(!FilenameFormats.doujinshiPresetTexts.contains("@series (@volume) - @author"))
        #expect(FilenameFormats.commercialPresetTexts.first == "(@genre) [@author] @title (@volume) [@info]")
        #expect(FilenameFormats.commercialPresetTexts.allSatisfy { !$0.contains("@source") })
    }

    /// 先頭の丸括弧を催しの名前にしている蔵書のための、もう 1 つの同人誌用プリセット。
    /// ジャンルの型と同居できない(同じ位置を奪い合う)ので並びを分けてある。
    @Test func eventPresetReadsTheLeadingParenthesisAsTheEvent() {
        let formats = FilenameFormats.doujinshiEventPreset
        #expect(formats.formats.count == 16)
        #expect(formats.formats.first?.text == "(@event) [@author (@author)] @title (@source) [@info]")
        let r = formats.read("(架空の催し12) [架空工房] 月の庭 1 (架空の原作)")
        #expect(r.metadata.event == "架空の催し12")
        #expect(r.metadata.title == "月の庭 1")
        #expect(r.metadata.source == "架空の原作")
        // 名前にジャンルは書かれないので、プリセットの既定が入る(値は規則の JSON が持つ)。
        #expect(r.metadata.genre == "同人誌")
        // 同じ名前を、ジャンルの型のプリセットで読むと催しではなくジャンルになる。
        #expect(FilenameFormats.doujinshiPreset.read("(架空の催し12) [架空工房] 月の庭 1 (架空の原作)").metadata.genre == "架空の催し12")
        // どの型にも合わない名前にも、既定は入る。
        let unmatched = formats.read("括弧の無い名前")
        #expect(unmatched.formatIndex == nil)
        #expect(unmatched.metadata.genre == "同人誌")
        // 名前から読めた欄は、既定で上書きしない。
        var withGenre = FilenameFormats.doujinshiEventPreset
        withGenre.defaults = [.source: ["オリジナル"]]
        #expect(withGenre.read("[架空工房] 月の庭 (架空の原作)").metadata.source == "架空の原作")
    }

    @Test func numericTrailingParenIsTheVolume() {
        let r = Self.read("[架空工房] 月の庭（１２）")
        #expect(r.metadata.volume == "12")  // 全角の数字は半角に畳む
        #expect(r.metadata.title == "月の庭")
        #expect(Self.read("[架空工房] 月の庭 (架空の原作)").metadata.source == "架空の原作")
    }

    @Test func longNamesFinishQuickly() {
        // 後戻りが爆発しない(失敗した位置を覚える)。
        let name = String(repeating: "(あ) [い] う ", count: 40)
        let start = Date()
        _ = Self.read(name)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
