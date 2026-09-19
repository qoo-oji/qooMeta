import Foundation
import QooFormat

/// qooLibrary のファイル名フォーマット処理(`Sources/QooFormat` に写したもの)で、ファイル名を部分に分ける。
///
/// qooLibrary の同人誌のプリセットのフォーマット群を上から順に照合し、最初に一致したものを採る。
/// 先頭の丸括弧が**本の種別(`@mediatype`、旧 `@booktype`)なのかイベント名(`@event`)なのかは、
/// 本の種別の語彙との照合で決まる**(qooLibrary の 04 章 §4.8)。本の種別が違う本は、同じシリーズに
/// しない(SeriesGrouper.partitionKey)。
///
/// **本の種別の語彙はコードに書かない。** 語彙は蔵書のフォルダ名と同じ語であることが多く、リポジトリに
/// 置けない(CLAUDE.md)。利用者の設定(リポジトリの外の config.json の `mediaTypes`)から渡す。
///
/// どのフォーマットにも一致しない名前は nil を返し、呼び出し側が qooMeta 自身の NameParser へ戻す。
public struct QooLibraryNameParser: Sendable {
    let settings: LibrarySettingsSnapshot
    let parser = FilenameParser()

    /// qooLibrary の同人誌のプリセット(`builtin.doujinshi`、library-types.json)のファイル名フォーマット。
    /// 予約語と括弧だけでできているので、そのまま写してある。
    public static let doujinshiFormats = [
        "(@mediatype) [@studio (@author)] @title (@genre) [@keyword]",
        "(@mediatype) [@studio (@author)] @title (@genre)",
        "(@mediatype) [@studio (@author)] @title [@keyword]",
        "(@mediatype) [@studio (@author)] @title",
        "(@mediatype) [@studio] @title (@genre) [@keyword]",
        "(@mediatype) [@studio] @title (@genre)",
        "(@mediatype) [@studio] @title [@keyword]",
        "(@mediatype) [@studio] @title",
        "(@event) [@studio (@author)] @title (@genre) [@keyword]",
        "(@event) [@studio (@author)] @title (@genre)",
        "(@event) [@studio (@author)] @title [@keyword]",
        "(@event) [@studio (@author)] @title",
        "(@event) [@studio] @title (@genre) [@keyword]",
        "(@event) [@studio] @title (@genre)",
        "(@event) [@studio] @title [@keyword]",
        "(@event) [@studio] @title",
        "[@studio] @title (@genre) [@keyword]",
        "[@studio] @title (@genre)",
        "[@studio] @title [@keyword]",
        "[@studio] @title",
    ]

    /// 同じプリセットの予約語 → フィールド番号。
    static let doujinshiBindings: [SemanticKeyword: Int] = [
        .author: 1, .studio: 2, .genre: 3, .event: 4, .keyword: 5, .mediaType: 7,
    ]

    /// qooLibrary の既定の保護文字列(AppDefaults.Library.protectedTokenPatterns)。
    /// 「(2019)」のような年や「(完結)」を、末尾の丸括弧(`@genre`)と取り違えないため。
    static let protectedTokenPatterns = [
        #"\((19[0-9]{2})\)"#,
        #"\((20[0-9]{2})\)"#,
        #"\((結|終|完|完結|完全版)\)"#,
    ]

    /// - Parameter mediaTypes: 本の種別の語彙(利用者の設定から)。空なら先頭の丸括弧はすべてイベントとして読む。
    public init(mediaTypes: [String], formats: [String] = doujinshiFormats) throws {
        let context = FormatCompilationContext(mediaTypeVocabulary: mediaTypes, semanticBindings: Self.doujinshiBindings)
        let compiled = try formats.enumerated().map { try FormatCompiler.compile($0.element, context: context, priority: $0.offset) }
        settings = LibrarySettingsSnapshot(
            mediaTypeVocabulary: mediaTypes,
            protectedTokens: ProtectedTokenCompiler.compileAll(Self.protectedTokenPatterns.map { ProtectedToken(pattern: $0) }),
            filenameFormats: compiled,
            semanticBindings: Self.doujinshiBindings)
    }

    public func parse(baseName: String) -> ParsedName? {
        guard let result = parser.parse(TextRules.normalizeDisplay(baseName), settings: settings) else { return nil }
        func value(_ ref: FieldRef) -> String { TextRules.normalizeDisplay(result.fields[ref]?.text ?? "") }
        let title = value(.title)
        guard !title.isEmpty else { return nil }
        let authors = value(.author)
            .split(whereSeparator: { "、,，&＆/／".contains($0) })
            .map { TextRules.normalizeDisplay(String($0)) }
            .filter { !$0.isEmpty }
        let mediaType = value(.mediaType)
        let event = value(.event)
        let studio = value(.studio)
        return ParsedName(
            leading: mediaType.isEmpty ? event : mediaType,
            circle: studio.isEmpty ? (authors.first ?? "") : studio,
            authors: authors,
            title: title,
            trailing: value(.genre),
            matchedPattern: true,
            mediaType: mediaType,
            event: event,
            keyword: value(.keyword))
    }
}
