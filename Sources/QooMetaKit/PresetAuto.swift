import Foundation

/// ルールセットを本ごとに選ぶ条件(filename-formats.json のプリセットの `auto`)。
///
/// 1 つの蔵書に商業誌と同人誌が混ざっていると、どれか 1 つのルールセットで全冊を読むことになり、合わない側の名前が
/// まとめて読めなくなる(2026-09-21、利用者の指摘)。フォルダの名前や本の名前に、どの種類の本かが書いてあることが多い
/// ので、それを手がかりに本ごとに選ぶ。
///
/// 条件は 2 段: ① フォルダのパスか名前に含む語 と、② ファイル名の先頭の語句(必須か例外)。② を「丸括弧で始まるか」の
/// ような形の条件にしていた版は、利用者から見て何を決めているのか読めなかった(2026-09-21、利用者の指摘)。
/// 利用者が考えるのは「この語句が先頭にあることを必須にしたいのか、例外にしたいのか」なので、その形で持つ。
///
/// **語はコードに書かない**(concept.md の原則 8)。① の語は利用者の蔵書の分け方そのものなので、同梱の JSON か、
/// 利用者がルールセットの窓で書いたものを使う。
public struct PresetAutoRule: Sendable, Hashable {
    /// ① フォルダのパスか名前に、どれか 1 つを含む本に当てる。空なら、どの本にも当てない(自動では選ばれない)。
    public var words: [String]
    /// ② 必須: ファイル名がこのどれかで始まる本だけに当てる(空なら問わない)。
    public var headRequired: [String]
    /// ② 例外: ファイル名がこのどれかで始まる本には当てない。
    public var headExcluded: [String]

    public static let none = PresetAutoRule()

    public init(words: [String] = [], headRequired: [String] = [], headExcluded: [String] = []) {
        self.words = words
        self.headRequired = headRequired
        self.headExcluded = headExcluded
    }

    /// 自動で選ばれることがあるか。
    public var isActive: Bool { words.contains { !$0.isEmpty } }

    /// 先頭の語句を必須にしているか。**必須にしたルールセットは、① だけで当たるルールセットより先に選ばれる**
    /// (`PresetAutoChoice`)。「先頭が ( ならイベント、そうでなければジャンル」を、ジャンルの側に「( で始まらない」と
    /// 書き直さずに言えるように。
    public var requiresHead: Bool { headRequired.contains { !$0.isEmpty } }

    /// 判定の途中経過(設定の画面で、どの条件でどう決まったかを見せるため)。
    public struct Explanation: Sendable, Hashable {
        /// ① 当たった語(当たらなければ nil)。
        public var word: String?
        /// ② 必須の語句で、名前の先頭にあったもの(必須が無ければ、いつも nil)。
        public var required: String?
        /// ② 例外の語句で、名前の先頭にあったもの。
        public var excluded: String?
        /// 必須の語句があるか。
        public var hasRequired: Bool

        /// ② を満たすか。
        public var headOK: Bool { (!hasRequired || required != nil) && excluded == nil }
        public var fits: Bool { word != nil && headOK }
    }

    /// その本に当たるか。`path` はフォルダを含めた本の場所(起点のフォルダの名前も手がかりになるので、起点からの相対パスではなく全体)。
    public func fits(path: String, name: String) -> Bool { explain(path: path, name: name).fits }

    public func explain(path: String, name: String) -> Explanation {
        Explanation(word: words.first { Self.contains(path, $0) || Self.contains(name, $0) },
                    required: headRequired.first { Self.starts(name, with: $0) },
                    excluded: headExcluded.first { Self.starts(name, with: $0) },
                    hasRequired: requiresHead)
    }

    /// 大文字と小文字、全角と半角を同じとみなす(フォルダの名前は、打った人の癖でどちらにもなる。「(」は「（」にも当たる)。
    /// 合成済みか分解形かの違いも、`range(of:)` が同じとみなす(`.literal` を付けていないため)。
    static func contains(_ text: String, _ word: String) -> Bool {
        !word.isEmpty && text.range(of: word, options: [.caseInsensitive, .widthInsensitive]) != nil
    }

    /// 名前がその語句で始まるか(頭の空白は飛ばす)。
    static func starts(_ name: String, with phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let head = String(name.drop(while: \.isWhitespace))
        return head.range(of: phrase, options: [.anchored, .caseInsensitive, .widthInsensitive]) != nil
    }
}

/// 本ごとに、条件に当たるルールセットを選ぶ。
///
/// 当たるものが 2 つ以上なら、**先頭の語句を必須にしたもの**を採る(必須は ① より狭い条件なので、狭いほうが勝つ)。
/// それでも 1 つに絞れない本と、どれにも当たらない本は決めずに残す ―― それ以上の順を道具の側で決めると、
/// 取り違えが見えないまま一覧に入る(道具の側で偏りをかけない)。
public enum PresetAutoChoice {
    public struct Book: Sendable, Hashable {
        public var id: String
        public var path: String
        public var name: String

        public init(id: String, path: String, name: String) {
            self.id = id
            self.path = path
            self.name = name
        }
    }

    /// 1 冊の決まり方。
    public enum Decision: Sendable, Hashable {
        case none
        case one(String)
        /// 絞れなかった(当たったルールセットの名前)。
        case many([String])
    }

    public struct Result: Sendable, Hashable {
        /// 本の ID → ルールセットの名前(決まった本だけ)。
        public var assigned: [String: String] = [:]
        /// どのルールセットにも当たらなかった冊数。
        public var unmatched = 0
        /// 2 つ以上のルールセットに当たり、絞れなかった冊数。
        public var ambiguous = 0

        /// すべての本が決まったか。
        public var isComplete: Bool { unmatched == 0 && ambiguous == 0 }
    }

    public static func decide(path: String, name: String, rules: [(name: String, rule: PresetAutoRule)]) -> Decision {
        let matched = rules.filter { $0.rule.isActive && $0.rule.fits(path: path, name: name) }
        guard matched.count > 1 else { return matched.first.map { .one($0.name) } ?? .none }
        let narrow = matched.filter(\.rule.requiresHead)
        return narrow.count == 1 ? .one(narrow[0].name) : .many(matched.map(\.name))
    }

    public static func choose(_ books: [Book], rules: [(name: String, rule: PresetAutoRule)]) -> Result {
        let active = rules.filter(\.rule.isActive)
        var result = Result()
        for book in books {
            switch decide(path: book.path, name: book.name, rules: active) {
            case .none: result.unmatched += 1
            case .one(let name): result.assigned[book.id] = name
            case .many: result.ambiguous += 1
            }
        }
        return result
    }
}
