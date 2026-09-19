import Foundation
import QooFormat

/// qooLibrary のファイル名フォーマット処理(`Sources/QooFormat` に写したもの)で、ファイル名を部分に分ける。
///
/// フォーマットは `filename-formats.json` に、**Stackroom 式の予約語**で書く:
/// `(@genre) [@circle (@author)] @title (@relation) [@keywordA]`。上から順に照合し、最初に一致したものを採る。
/// 照合の処理(qooLibrary 由来)の予約語へは、JSON の `reservedWords` の対応表で置き換えてからコンパイルする。
///
/// 先頭の丸括弧が本の種別(`@genre`。照合の処理では `@mediatype`)なのかイベント名(`@event`)なのかは、
/// **本の種別の語彙との照合で決まる**(qooLibrary の 04 章 §4.8)。本の種別が違う本は、同じシリーズにしない
/// (SeriesGrouper.partitionKey)。
///
/// **本の種別の語彙はリポジトリに置かない。** 語彙は蔵書のフォルダ名と同じ語であることが多い(CLAUDE.md)。
/// 利用者の設定(リポジトリの外の config.json の `mediaTypes`)から渡す。
///
/// どのフォーマットにも一致しない名前は nil を返し、呼び出し側が qooMeta 自身の NameParser へ戻す。
public struct QooLibraryNameParser: Sendable {
    /// プロファイルごとの照合の設定(上から試す)。
    let settings: [LibrarySettingsSnapshot]
    let parser = FilenameParser()
    /// qooMeta の欄 → 照合の処理のフィールド。
    let fieldRefs: [String: FieldRef]
    let authorSeparators: Set<Character>

    /// フォーマットの予約語の読み替えと、意味のある予約語へのフィールドの番号。
    struct Vocabulary {
        var bindings: [SemanticKeyword: Int] = [:]
        var refs: [String: FieldRef] = [:]
        let engineWord: [String: String]

        init(_ rules: FilenameFormatRules) {
            engineWord = rules.reservedWords.mapValues(\.engine)
            // 意味のある予約語(サークル・作者・ネタ …)に、フィールドの番号を振る(番号そのものに意味は無い)。
            for (i, word) in rules.reservedWords.keys.sorted().enumerated() {
                let entry = rules.reservedWords[word]!
                if let keyword = SemanticKeyword(rawValue: entry.engine) {
                    bindings[keyword] = i + 1
                    refs[entry.field] = keyword.fieldRef
                } else if entry.engine == "@title" {
                    refs[entry.field] = .title
                }
            }
        }

        /// Stackroom 式の予約語 → 照合の処理の予約語(1 回の走査で置き換える。順に置き換えると
        /// 「@relation → @genre → @mediatype」のように連鎖してしまう)。
        func translate(_ format: String) -> String {
            let token = try! NSRegularExpression(pattern: "@[A-Za-z]+[0-9]*")
            let ns = format as NSString
            var out = "", last = 0
            for m in token.matches(in: format, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let word = ns.substring(with: m.range)
                out += engineWord[word] ?? word
                last = m.range.location + m.range.length
            }
            return out + ns.substring(from: last)
        }
    }

    static func delimiters(_ profile: FilenameFormatRules.Profile) -> DelimiterSet {
        DelimiterSet(pairs: profile.delimiters.compactMap { pair in
            guard pair.count == 2, let open = pair[0].first, let close = pair[1].first else { return nil }
            return PairDelimiter(open: open, close: close)
        })
    }

    /// フォーマット 1 つを組み立てる(規則の検証にも使う)。
    static func compile(_ format: String, profile: FilenameFormatRules.Profile, rules: FilenameFormatRules,
                        mediaTypes: [String], priority: Int = 0) throws -> CompiledFormat {
        let vocabulary = Vocabulary(rules)
        let context = FormatCompilationContext(delimiters: delimiters(profile), mediaTypeVocabulary: mediaTypes,
                                               semanticBindings: vocabulary.bindings)
        return try FormatCompiler.compile(vocabulary.translate(format), context: context, priority: priority)
    }

    /// - Parameter mediaTypes: 本の種別の語彙(利用者の設定から)。空なら先頭の丸括弧はすべてイベントとして読む。
    public init(mediaTypes: [String], rules: FilenameFormatRules = CompiledRules.builtin.formats) throws {
        let vocabulary = Vocabulary(rules)
        settings = try rules.profiles.map { profile in
            let delimiters = Self.delimiters(profile)
            let context = FormatCompilationContext(delimiters: delimiters, mediaTypeVocabulary: mediaTypes,
                                                   semanticBindings: vocabulary.bindings)
            let compiled = try profile.formats.enumerated().map {
                try FormatCompiler.compile(vocabulary.translate($0.element), context: context, priority: $0.offset)
            }
            return LibrarySettingsSnapshot(
                mediaTypeVocabulary: mediaTypes,
                delimiters: delimiters,
                protectedTokens: ProtectedTokenCompiler.compileAll(profile.protectedTokens.map { ProtectedToken(pattern: $0) }),
                filenameFormats: compiled,
                semanticBindings: vocabulary.bindings)
        }
        fieldRefs = vocabulary.refs
        authorSeparators = Set(rules.authorSeparators)
    }

    public func parse(baseName: String) -> ParsedName? {
        let name = TextRules.normalizeDisplay(baseName)
        guard let result = settings.lazy.compactMap({ parser.parse(name, settings: $0) }).first else { return nil }
        func value(_ field: String) -> String {
            guard let ref = fieldRefs[field] else { return "" }
            return TextRules.normalizeDisplay(result.fields[ref]?.text ?? "")
        }
        let title = value("title")
        guard !title.isEmpty else { return nil }
        let authors = value("authors")
            .split(whereSeparator: { authorSeparators.contains($0) })
            .map { TextRules.normalizeDisplay(String($0)) }
            .filter { !$0.isEmpty }
        let genre = value("genre")
        let event = value("event")
        let circle = value("circle")
        // 末尾の丸括弧が数字だけ(「X (12)」)なら、ネタ(関連)ではなく巻としてタイトルへ戻す(StackNest に倣った)。
        var relation = value("relation")
        var fullTitle = title
        if VolumeExtractor.isNumeralOnly(relation) {
            fullTitle = "\(title) (\(relation))"
            relation = ""
        }
        return ParsedName(
            leading: genre.isEmpty ? event : genre,
            circle: circle.isEmpty ? (authors.first ?? "") : circle,
            authors: authors,
            title: fullTitle,
            trailing: relation,
            matchedPattern: true,
            mediaType: genre,
            event: event,
            keyword: value("keyword"))
    }
}
