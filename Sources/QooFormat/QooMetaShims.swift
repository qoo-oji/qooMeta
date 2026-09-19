//
//  qooLibrary から写したフォーマット処理が参照する、qooLibrary 側の型の最小限の代わり。
//  写した元のファイルは手を入れずに(文言の準拠を外した FormatCompileError を除く)保つため、足りない型をここに置く。
//
import Foundation

/// qooLibrary の `AppLimits.Format`(Model/AppLimits.swift)の値をそのまま写したもの。
public enum AppLimits {
    public enum Format {
        public static let maxFields = 10
        public static let maxMatchSteps = 20_000
        public static let maskPlaceholderCapacity = 256
        public static let maskPlaceholderBase: UInt32 = 0xE000
        public static let regexMatchBudget: TimeInterval = 0.02
        public static let regexProbeBudget: TimeInterval = 0.02
        public static let maxRegexProbeSamples = 48
        public static let regexProbeTotalBudget: TimeInterval = 0.1
    }
}

/// qooLibrary の地域化文字列。qooMeta は利用者向けの文言を出さないので、鍵をそのまま返す。
enum QooKitStrings {
    static func text(_ key: String) -> String { key }
    static func format(_ key: String, _ args: any CVarArg...) -> String {
        ([key] + args.map { "\($0)" }).joined(separator: " ")
    }
}

/// qooLibrary の `LibrarySettingsSnapshot` のうち、ファイル名の照合に要る部分だけ。
public struct LibrarySettingsSnapshot: Sendable {
    /// `@mediatype` の照合語彙。
    public let mediaTypeVocabulary: [String]
    public let delimiters: DelimiterSet
    public let protectedTokens: [CompiledProtectedToken]
    /// 優先順に並んだファイル名フォーマット。
    public let filenameFormats: [CompiledFormat]
    /// 優先順に並んだ巻数フォーマット。
    public let volumeFormats: [CompiledVolumePattern]
    public let semanticBindings: [SemanticKeyword: Int]

    public init(mediaTypeVocabulary: [String] = [], delimiters: DelimiterSet = .default,
                protectedTokens: [CompiledProtectedToken] = [], filenameFormats: [CompiledFormat] = [],
                volumeFormats: [CompiledVolumePattern] = [], semanticBindings: [SemanticKeyword: Int] = [:]) {
        self.mediaTypeVocabulary = mediaTypeVocabulary
        self.delimiters = delimiters
        self.protectedTokens = protectedTokens
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.semanticBindings = semanticBindings
    }
}
