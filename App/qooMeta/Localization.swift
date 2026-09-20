import Foundation
import SwiftUI

/// 画面の言葉の言語。**鍵は英語**(`Text("Open Folder…")` の文字列そのもの)で、訳は `Localizable.xcstrings` が持つ。
///
/// `system` は macOS の「言語と地域」に従う(ふつうはこれ)。利用者が選べるようにしたのは、
/// システムを英語にしたまま qooMeta だけ日本語で使う(逆も)ことがあるため(2026-09-20、利用者の指示)。
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, en, ja

    var id: Self { self }

    /// 設定の画面に出す言葉の鍵。
    var key: String {
        switch self {
        case .system: "Follow System"
        case .en: "English"
        case .ja: "Japanese"
        }
    }

    /// 言葉を探す `.lproj` の名前。`system` は選ばない(macOS の選び方に任せる)。
    var localeIdentifier: String? { self == .system ? nil : rawValue }
}

/// 選んだ言語で言葉を返す包み。**`Bundle.main` のクラスをこれに差し替える**(`AppLanguage.apply`)。
///
/// SwiftUI の `Text` も、窓の題(`Window("…")`)も、言葉は最後に `Bundle.main` へ聞きに来るので、ここを替えれば
/// 画面の全体が選んだ言語になる。`.environment(\.locale, …)` だけでは、画面の中の `Text` には効くが、
/// 窓の題のように画面の外で決まる言葉には効かない。
///
/// 差し替えるのは**クラスだけ**で、`Bundle.main` の持ちものは変えない(この包みは値を持たない)。
final class LanguageBundle: Bundle, @unchecked Sendable {
    /// 選んだ言語の `.lproj`。nil なら macOS の選び方のまま。
    /// 言葉は画面の描き直しのたびに、どのスレッドからでも聞かれるので、錠で守る。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var selected: Bundle?
    nonisolated(unsafe) private static var selectedLocale = Locale.autoupdatingCurrent

    static var language: Bundle? {
        get { lock.withLock { selected } }
        set { lock.withLock { selected = newValue } }
    }

    /// 数の書き方と、英語の単数・複数の選び方に使う地域(画面の言語と同じもの)。
    static var locale: Locale {
        get { lock.withLock { selectedLocale } }
        set { lock.withLock { selectedLocale = newValue } }
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let bundle = Self.language else { return super.localizedString(forKey: key, value: value, table: tableName) }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension AppLanguage {
    /// この言語を画面に効かせる。**言葉を 1 つでも読む前に呼ぶ**(アプリの起動のとき、設定を変えたとき)。
    func apply() {
        // 1 度だけ、`Bundle.main` のクラスを包みに差し替える。
        if !(Bundle.main is LanguageBundle) { object_setClass(Bundle.main, LanguageBundle.self) }
        LanguageBundle.language = localeIdentifier
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap { Bundle(path: $0) }
        LanguageBundle.locale = locale
    }

    /// 数や日付の書き方(`system` なら macOS のまま)。画面の根に渡して、言語を変えたときに画面を描き直させる。
    var locale: Locale { localeIdentifier.map { Locale(identifier: $0) } ?? Locale.autoupdatingCurrent }
}

extension String {
    /// 画面に出す言葉(鍵は英語)。`Text` に渡せない所(取り消しの名前、誤りの文、`NSOpenPanel` の言葉)で使う。
    var ui: String { Bundle.main.localizedString(forKey: self, value: nil, table: nil) }

    /// 値を挟む言葉。鍵の `%@` `%lld` に、渡した値が入る(単数・複数の作り分けも効く)。
    func ui(_ arguments: any CVarArg...) -> String {
        String(format: ui, locale: LanguageBundle.locale, arguments: arguments)
    }
}

extension Text {
    /// 変数に入った鍵(英語)から作る。`Text(String)` は訳さないので、鍵を変数で持つ所(`RuleLabels`)はこの口を通す。
    init(key: String) { self.init(LocalizedStringKey(key)) }
}
