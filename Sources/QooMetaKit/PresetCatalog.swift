import Foundation

/// ファイル名フォーマットのプリセットの一覧(今の値・同梱の既定値・利用者が変えたかどうか)。プリセットの編集画面用。
/// 表示の言葉は含まない。中身は filename-formats.json を重ねた結果から読む(docs/filename-format.md の 4)。
public struct PresetCatalog: Sendable, Hashable {
    /// 1 つの型。区切りと既定の欄は、書いたときだけその型に効く(書かなければプリセットのものを使う)。
    public struct Format: Sendable, Hashable {
        public var text: String
        public var separators: [String]?
        /// 欄の名前(`genre` `event` `source` `info`)→ 値。
        public var defaults: [String: String]
        /// この型のときにだけ足す「型として読まない文字列」。
        public var plain: PlainText

        public init(text: String, separators: [String]? = nil, defaults: [String: String] = [:], plain: PlainText = .none) {
            self.text = text
            self.separators = separators
            self.defaults = defaults
            self.plain = plain
        }
    }

    public struct Preset: Sendable, Hashable {
        public var name: String
        public var label: String
        public var note: String
        /// このプリセットだけの著者の区切り。nil ならファイル全体の区切りを使う。
        public var separators: [String]?
        public var defaults: [String: String]
        /// このプリセットで足す「型として読まない文字列」(ファイル全体の分に足される)。
        public var plain: PlainText
        /// 題の途中の括弧を読み残しに数えないか(既定は数えない。`FilenameFormats.ignoresBracketsInsideTitle`)。
        public var ignoresBracketsInsideTitle: Bool
        public var formats: [Format]

        public init(name: String, label: String = "", note: String = "", separators: [String]? = nil,
                    defaults: [String: String] = [:], plain: PlainText = .none,
                    ignoresBracketsInsideTitle: Bool = true, formats: [Format] = []) {
            self.name = name
            self.label = label
            self.note = note
            self.separators = separators
            self.defaults = defaults
            self.plain = plain
            self.ignoresBracketsInsideTitle = ignoresBracketsInsideTitle
            self.formats = formats
        }
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { preset.name }
        public let preset: Preset
        /// 同梱の既定値(利用者が足したプリセットなら nil)。「初期化」で戻る先。
        public let original: Preset?
        public var isBuiltIn: Bool { original != nil }
        public var isModified: Bool { original.map { $0 != preset } ?? false }
    }

    /// 同梱のプリセット(同梱の順)に、利用者のプリセット(名前の順)が続く。
    public let entries: [Entry]
    public let defaultPreset: String
    public let builtInDefaultPreset: String

    /// 既定を書ける欄(ジャンル・イベント・原作・情報)。
    public static var defaultFields: [String] { RuleSchema.presetDefaultFields }

    public var names: Set<String> { Set(entries.map(\.preset.name)) }
}

extension CompiledRules {
    public var presetCatalog: PresetCatalog {
        func strings(_ v: JSONValue?) -> [String]? { v?.arrayValue?.compactMap(\.stringValue) }
        func defaults(_ v: JSONValue?) -> [String: String] { v?.objectValue?.compactMapValues(\.stringValue) ?? [:] }
        func plain(_ v: JSONValue?) -> PlainText { PlainText(words: strings(v?["words"]) ?? [], patterns: strings(v?["patterns"]) ?? []) }
        func preset(_ name: String, _ v: JSONValue) -> PresetCatalog.Preset {
            PresetCatalog.Preset(
                name: name, label: v["label"]?.stringValue ?? "", note: v["note"]?.stringValue ?? "",
                separators: strings(v["separators"]), defaults: defaults(v["defaults"]), plain: plain(v["plain"]),
                ignoresBracketsInsideTitle: v["ignoreBracketsInsideTitle"]?.boolValue ?? true,
                formats: (v["formats"]?.arrayValue ?? []).compactMap { entry in
                    guard let text = RuleLoader.formatText(entry).stringValue else { return nil }
                    return PresetCatalog.Format(text: text, separators: strings(entry["separators"]), defaults: defaults(entry["defaults"]),
                                                plain: plain(entry["plain"]))
                })
        }
        let now = mergedFilenameFormats["presets"]?.objectValue ?? [:]
        let before = defaultFilenameFormats["presets"]?.objectValue ?? [:]
        // JSON のオブジェクトは順を持たないので、同梱の順はコードの側の並び(綴りの候補と同じもの)で決める。
        let builtIn = RuleSchema.presetNames.filter { before[$0] != nil } + before.keys.filter { !RuleSchema.presetNames.contains($0) }.sorted()
        let names = builtIn.filter { now[$0] != nil } + now.keys.filter { before[$0] == nil }.sorted()
        return PresetCatalog(
            entries: names.map { name in PresetCatalog.Entry(preset: preset(name, now[name]!), original: before[name].map { preset(name, $0) }) },
            defaultPreset: mergedFilenameFormats["defaultPreset"]?.stringValue ?? "",
            builtInDefaultPreset: defaultFilenameFormats["defaultPreset"]?.stringValue ?? "")
    }
}

extension RuleChanges {
    /// プリセットを保存する。`original` が同梱の既定値なら**違う所だけ**を差分に書き(同じに戻れば差分から消える)、
    /// nil なら利用者の新しいプリセットとして全体を書く。
    public mutating func setPreset(_ preset: PresetCatalog.Preset, original: PresetCatalog.Preset?) {
        func whole(_ plain: PlainText) -> JSONValue {
            .object(["words": .array(plain.words.map(JSONValue.string)), "patterns": .array(plain.patterns.map(JSONValue.string))])
        }
        func entry(_ format: PresetCatalog.Format) -> JSONValue {
            guard format.separators != nil || !format.defaults.isEmpty || !format.plain.isEmpty else { return .string(format.text) }
            var o: [String: JSONValue] = ["format": .string(format.text)]
            if !format.plain.isEmpty { o["plain"] = whole(format.plain) }
            if let separators = format.separators { o["separators"] = .array(separators.map(JSONValue.string)) }
            if !format.defaults.isEmpty { o["defaults"] = .object(format.defaults.mapValues(JSONValue.string)) }
            return .object(o)
        }
        var o: [String: JSONValue] = [:]
        if let original {
            // 見出しと説明は空にできない(空なら、同梱の値のまま)。
            if !preset.label.isEmpty, preset.label != original.label { o["label"] = .string(preset.label) }
            if !preset.note.isEmpty, preset.note != original.note { o["note"] = .string(preset.note) }
            if let separators = preset.separators, separators != original.separators {
                o["separators"] = .object(["$replace": .array(separators.map(JSONValue.string))])
            }
            var defaults: [String: JSONValue] = [:]
            for field in Set(preset.defaults.keys).union(original.defaults.keys) where preset.defaults[field] != original.defaults[field] {
                defaults[field] = preset.defaults[field].map(JSONValue.string) ?? .null
            }
            if !defaults.isEmpty { o["defaults"] = .object(defaults) }
            if preset.plain != original.plain { o["plain"] = Self.replacing(preset.plain) }
            if preset.ignoresBracketsInsideTitle != original.ignoresBracketsInsideTitle {
                o["ignoreBracketsInsideTitle"] = .bool(preset.ignoresBracketsInsideTitle)
            }
            if preset.formats != original.formats { o["formats"] = .object(["$replace": .array(preset.formats.map(entry))]) }
        } else {
            if !preset.label.isEmpty { o["label"] = .string(preset.label) }
            if !preset.note.isEmpty { o["note"] = .string(preset.note) }
            if let separators = preset.separators { o["separators"] = .array(separators.map(JSONValue.string)) }
            if !preset.defaults.isEmpty { o["defaults"] = .object(preset.defaults.mapValues(JSONValue.string)) }
            if !preset.plain.isEmpty { o["plain"] = whole(preset.plain) }
            if !preset.ignoresBracketsInsideTitle { o["ignoreBracketsInsideTitle"] = .bool(false) }
            o["formats"] = .array(preset.formats.map(entry))
        }
        if o.isEmpty { Self.remove(&formats, ["presets", preset.name]) } else { Self.set(&formats, ["presets", preset.name], .object(o)) }
    }

    /// 差分からプリセットを消す。同梱のプリセットなら**初期化**(既定値に戻る)、利用者のプリセットなら**削除**。
    /// 既定のプリセットに選んでいたら、それも既定に戻す(無い名前を指したままにしない)。
    public mutating func removePreset(_ name: String) {
        Self.remove(&formats, ["presets", name])
        if formats["defaultPreset"]?.stringValue == name, !RuleSchema.presetNames.contains(name) { Self.remove(&formats, ["defaultPreset"]) }
    }

    /// 本がプリセットを選ばなかったときに使う名前。
    public mutating func setDefaultPreset(_ name: String, builtIn: String) {
        if name == builtIn { Self.remove(&formats, ["defaultPreset"]) } else { Self.set(&formats, ["defaultPreset"], .string(name)) }
    }

    /// 既定値のある所の `plain` を、丸ごと置き換える差分。
    static func replacing(_ plain: PlainText) -> JSONValue {
        .object(["words": .object(["$replace": .array(plain.words.map(JSONValue.string))]),
                 "patterns": .object(["$replace": .array(plain.patterns.map(JSONValue.string))])])
    }

}
