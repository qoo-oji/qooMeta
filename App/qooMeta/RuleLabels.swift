import Foundation

/// 規則の窓に出す言葉。規則の一覧(`RuleCatalog`)は ID と値だけを持ち、表示の言葉は画面の側が持つ。
/// ここに無い ID(新しい版で足された規則、利用者が足した規則)は、ID をそのまま出す。
enum RuleLabels {
    struct Text {
        var title: String
        var help: String = ""
    }

    // MARK: - 方針

    static let policies: [String: Text] = [
        "editions": Text(title: "版違い(フルカラー版・完全版 …)", help: "版の印が付いた本の扱い"),
        "sources": Text(title: "入手経路違い(DL版・特装版 …)", help: "入手経路の印が付いた本の扱い"),
        "compilations": Text(title: "総集編・番外編の置き場所", help: "総集編の語のある本を、どのシリーズに入れるか"),
        "compilationVolume": Text(title: "本編に含めた総集編の巻数", help: "置き場所が「本編に含める」のときだけ効く"),
        "magazines": Text(title: "雑誌", help: "年と号のある名前のまとめ方"),
        "unnumberedFirst": Text(title: "番号の無い 1 冊", help: "シリーズの中で番号の無い本を 1 巻とみなすか"),
        "differentRelation": Text(title: "原作が違う本", help: "同じ組になった本の原作(@source)が違うとき"),
        "differentGenre": Text(title: "ジャンルが違う本", help: "ジャンル(@genre)が違う本を同じシリーズにしてよいか"),
        "subtitled": Text(title: "副題の付いた本", help: "「X 〇〇編」を、巻でまとめた「X」の組に入れるか"),
    ]

    static let choices: [String: [String: String]] = [
        "editions": ["sameWork": "同じ作品の別の版(重複として扱う)", "separateBooks": "別の本として数える", "ignore": "印を見分けない"],
        "sources": ["sameWork": "同じ作品(重複として扱う)", "separateBooks": "別の本として数える", "ignore": "印を見分けない"],
        "compilations": ["ownSeries": "「X 総集編」という別のシリーズにする", "inMainSeries": "本編のシリーズに含める", "notInSeries": "どのシリーズにも入れない"],
        "compilationVolume": ["offset": "オフセットを足した数にする(総集編2 → 102)", "none": "巻数を付けない", "afterRange": "収録範囲の最後の巻の直後にする(1~4 → 4.5)"],
        "magazines": ["perYear": "1 年ぶんごとのシリーズにする", "whole": "雑誌全体で 1 つのシリーズにする"],
        "unnumberedFirst": ["inferFirst": "1 巻とみなす", "leaveEmpty": "巻数を空のままにする"],
        "differentRelation": ["split": "別のシリーズに分ける", "keep": "分けない"],
        "differentGenre": ["split": "別のシリーズにする", "keep": "同じシリーズにしてよい"],
        "subtitled": ["attach": "組に入れる", "separate": "入れない"],
    ]

    // MARK: - 規則

    static let treatments: [String: Text] = [
        "keep": Text(title: "そのまま読む", help: "何もしない。下の規則と巻の読み手から、この語を守る(例外はこれを上に置いて書く)"),
        "edition": Text(title: "版の印", help: "比べるときはタイトルから外す。外して同じ題名になる本は、同じ作品の版違い"),
        "source": Text(title: "入手経路の印", help: "比べるときはタイトルから外す。中身は同じで、手に入れた経路だけが違う"),
        "compilation": Text(title: "総集編の語", help: "置き場所は方針「総集編・番外編の置き場所」で決まる"),
        "standalone": Text(title: "シリーズに入れない", help: "この語のある本は、どのシリーズにも入れない"),
    ]

    static let rules: [String: Text] = [
        "plain": Text(title: "そのまま読む語", help: "「フルカラー総集編」のように、版の印でも総集編でもない語"),
        "edition": Text(title: "版の印", help: "フルカラー版・完全版・〇〇語版 …"),
        "source": Text(title: "入手経路の印", help: "DL版・電子版・特装版 …"),
        "compilationMark": Text(title: "総集編の語", help: "総集編・番外編 …"),
        "standalone": Text(title: "シリーズに入れない語", help: "この語のある本は、どのシリーズにも入れない(同梱の一覧は空)"),
        "compilation": Text(title: "総集編のシリーズ", help: "総集編を「X 総集編」のシリーズにまとめる"),
        "volumeHead": Text(title: "1 段目: タイトル + 巻", help: "「X 3」の形の本を、巻を除いた頭でまとめる"),
        "sharedPrefix": Text(title: "2 段目: 先頭の共通部分", help: "残りの本を、タイトルの先頭の共通部分でまとめる"),
        "reject-hiragana-ending": Text(title: "ひらがなで終わる共通部分は組にしない", help: "語の途中で切れた共通部分が、助詞などで終わるとき"),
        "reject-single-script": Text(title: "1 種類の文字だけの共通部分は組にしない", help: "語の途中で切れた共通部分が、カタカナだけ・漢字だけのとき"),
        "reject-common-english": Text(title: "一般的な英単語だけの題名は組にしない", help: "2 冊とも辞書にある英単語だけでできているとき"),
        "splitByRelation": Text(title: "原作の違いで組を分ける", help: "働くかどうかは方針「原作が違う本」で決まる"),
        "rejectSameWork": Text(title: "版違いだけの組はシリーズにしない", help: "働くかどうかは方針「版違い」「入手経路違い」で決まる"),
        "includeClosingBrackets": Text(title: "開いた括弧を閉じるまで含める", help: "シリーズ名が「【X」で切れないように"),
        "includeFollowing": Text(title: "すぐ後ろの「!」「?」を含める", help: "「月の庭!」の「!」をシリーズ名に入れる"),
        "trimTrailing": Text(title: "末尾の区切りの記号を落とす", help: "シリーズ名の末尾の「-」「~」など"),
        "dropLastWord": Text(title: "末尾の「side」「part」などを落とす", help: "「X side A」「X side B」のシリーズ名は「X」"),
        "ordinal": Text(title: "丸数字など(①②③)", help: ""),
        "number": Text(title: "数字(3・第3巻・Vol.3・36-37)", help: ""),
        "kanji": Text(title: "漢数字(三・第三巻)", help: ""),
        "greek": Text(title: "ギリシャ文字(α β γ)", help: ""),
        "roman": Text(title: "ローマ数字(II・III)", help: ""),
        "position": Text(title: "上・中・下、前編・後編", help: ""),
        "sharedLeadingKanji": Text(title: "先頭の漢数字を巻として読む", help: "同じシリーズの本の先頭に漢数字が並ぶとき"),
        "firstVolume": Text(title: "番号の無い 1 冊を 1 巻とみなす", help: "働くかどうかは方針「番号の無い 1 冊」で決まる"),
    ]

    static let stages: [String: String] = [
        "grouping": "組の作り方(この順に働く)",
        "grouping.sharedPrefix.conditions": "2 段目の、組にしない条件",
        "naming": "シリーズ名の整え方(この順に働く)",
        "volume.inference": "巻の推定",
    ]

    static let parameters: [String: String] = [
        "treat": "扱い", "words": "語", "patterns": "正規表現", "singleWhenMainExists": "本編のシリーズがあれば、総集編が 1 冊でもシリーズにする",
        "volumeOffset": "総集編・番外編のオフセット", "minPrefix": "語の途中で切れる共通部分の、最小の文字数",
        "minWholeTitle": "片方の題名の全体が一致するときの、最小の文字数", "dictionary": "辞書",
        "unlessVolume": "後ろに巻があれば組にする", "pairs": "括弧の対", "characters": "文字",
        "prefixes": "巻の番号の前に付く語", "counters": "巻の番号の後ろに付く単位", "wholeOnlyCounters": "残りが巻だけかを見るときの単位",
        "mergedSpan": "合併号とみなす、前後の号の差の上限", "first": "最初を表す語", "middle": "中ほどを表す語", "last": "最後を表す語",
        "minBooks": "何冊そろえば読むか", "excludeMarkers": "この語が後ろにある本は 1 巻とみなさない",
        "excludePrefixes": "この語がすぐ後ろに付く本は 1 巻とみなさない",
    ]

    // MARK: - 一覧

    static let lists: [String: Text] = [
        "plainWords": Text(title: "そのまま読む語", help: "版の印にも総集編にも巻にもしない語"),
        "standaloneWords": Text(title: "シリーズに入れない語", help: "この語のある本は、どのシリーズにも入れない。1 冊だけ外すなら、その本の題名を書く"),
        "editionWords": Text(title: "版の印", help: ""),
        "sourceWords": Text(title: "入手経路の印", help: ""),
        "compilationWords": Text(title: "総集編の語", help: ""),
        "volumePrefixes": Text(title: "巻の番号の前に付く語", help: "vol・第・その …。英字の語は後ろの「.」も受け付ける"),
        "volumeCounters": Text(title: "巻の番号の後ろに付く単位", help: "巻・話・号 …"),
        "wholeOnlyCounters": Text(title: "残りが巻だけかを見るときの単位", help: ""),
        "kanjiCounters": Text(title: "漢数字の後ろに付く単位", help: ""),
        "positionFirst": Text(title: "最初を表す語(上・前編)", help: ""),
        "positionMiddle": Text(title: "中ほどを表す語(中・中編)", help: ""),
        "positionLast": Text(title: "最後を表す語(下・後編)", help: ""),
        "notFirstMarkers": Text(title: "1 巻とみなさない本の語", help: "シリーズ名より後ろにこの語がある本"),
        "notFirstPrefixes": Text(title: "1 巻とみなさない本の、すぐ後ろの語", help: "「X ex」「X SP」"),
        "labelIntroducers": Text(title: "シリーズ名の末尾から落とす語", help: "side・part・episode …"),
        "ignoredInComparison": Text(title: "比べるときに無視する文字", help: "空白と、題名の飾りによく使う記号"),
        "boundaryCharacters": Text(title: "語の切れ目とみなす文字", help: "空白と数字は、いつも切れ目"),
        "trimTrailing": Text(title: "シリーズ名の末尾から落とす文字", help: ""),
        "keepFollowing": Text(title: "シリーズ名のすぐ後ろにあれば含める文字", help: ""),
        "variantKanji": Text(title: "同じ字とみなす異体字", help: "左の字を、右の字と同じとみなして比べる"),
        "brackets": Text(title: "括弧の対", help: "閉じ括弧 → 開き括弧"),
    ]

    /// 一覧を画面に並べる順(よく直すものを上に)。
    static let listOrder = [
        "plainWords", "standaloneWords", "editionWords", "sourceWords", "compilationWords",
        "volumePrefixes", "volumeCounters", "wholeOnlyCounters", "kanjiCounters", "positionFirst", "positionMiddle", "positionLast",
        "notFirstMarkers", "notFirstPrefixes", "labelIntroducers",
        "ignoredInComparison", "boundaryCharacters", "trimTrailing", "keepFollowing", "variantKanji", "brackets",
    ]

    static func rule(_ id: String) -> Text { rules[id] ?? Text(title: id) }
    static func list(_ id: String) -> Text { lists[id] ?? Text(title: id) }
    static func parameter(_ name: String) -> String { parameters[name] ?? name }
    static func treatment(_ id: String) -> Text { treatments[id] ?? Text(title: id) }

    /// 目に見えない文字(空白・タブ)を、見える形にする。
    static func visible(_ item: String) -> String {
        switch item {
        case " ": "␠(半角の空白)"
        case "　": "□(全角の空白)"
        case "\t": "⇥(タブ)"
        default: item
        }
    }
}
