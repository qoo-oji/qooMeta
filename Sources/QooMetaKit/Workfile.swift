import Foundation

/// 本の名前の揃え方。**見た目は変えない**(全角・半角も、名前の中の空白もそのまま)。直すのは 2 つだけ。
///
/// - 合成済み(NFC)にする。macOS はファイル名を分解形(NFD)で返すことがあり、そのままだと濁点・半濁点を含む語が
///   規則の語(画面で打つので NFC)と当たらない ―― 「(上)」は効くのに「(デカパイ)」は効かない、という出方になる
///   (2026-09-20、利用者の指摘)。
/// - 前後の空白を落とす。「… (原作) .cbz」のように拡張子の手前に空白がある名前は、拡張子を外すと末尾に空白が残る。
///   括弧で終わる型は末尾に空白の部品を持たないので**すべて**外れ、丸括弧が題に飲み込まれる(2026-09-20、利用者の指摘)。
///
/// 名前が入ってくる所(走査・作業ファイルの読み込み)でかける。ここで揃えておかないと、画面に出る名前と
/// 照合する名前が食い違い、利用者が画面から写した語が当たらない。
public enum BookName {
    public static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 作業ファイル: いま開いている一覧(本の ID と名前)と、利用者の修正、フォルダごとの型の並び(プリセット)の割り当て。
///
/// **ライブラリではない**(docs/concept.md)。qooMeta は蔵書を持たず、この作業ファイルは「いま直している途中の一覧」
/// だけを覚える。アプリの設定(型の並び・規則の差分・スタンプ)は別に持つ: 設定はどの一覧にも共通で、
/// 作業ファイルは一覧ごとだから。
///
/// **中身は蔵書の名前そのもの**なので、書き出す先は利用者が選んだ場所だけ(リポジトリの中には書かない。CLAUDE.md)。
/// 提案(シリーズ・巻)は持たない。規則を変えたら計算し直せばよく、古い提案が残ると食い違うため
/// (CLI の提案ファイルと同じ考え方)。
public struct Workfile: Codable, Sendable, Hashable {
    /// ファイルの種類(読むときに確かめる)。
    public static let kind = "qoometa.workfile"
    public static let formatVersion = 1

    public var kind: String
    public var formatVersion: Int
    public var savedAt: Date?
    /// 走査の起点(利用者の手元のパス)。本の ID はここからの相対パス。
    public var rootPath: String
    public var books: [Book]
    /// フォルダごとに、どの型の並びで名前を読むか。
    public var presets: PresetAssignment

    /// 1 冊。名前と、利用者の修正だけ。
    public struct Book: Codable, Sendable, Hashable, Identifiable {
        /// 起点からの相対パス(本の ID)。
        public var id: String
        /// 本の名前(ファイルは拡張子を除いたもの。フォルダの本は名前の全体)。
        public var name: String
        /// フォルダの本(画像フォルダ)か。ID の末尾からは決められない(「第1.5巻」というフォルダに拡張子は無い)ので覚えておく。
        public var isFolder: Bool
        /// 利用者の修正(欄・シリーズ・巻)。何も直していなければ `.none`。
        public var confirmation: Confirmation

        public init(id: String, name: String, isFolder: Bool = false, confirmation: Confirmation = .none) {
            self.id = id
            self.name = name
            self.isFolder = isFolder
            self.confirmation = confirmation
        }

        /// 書き出しに使う拡張子(フォルダの本は空)。
        public var fileExtension: String { isFolder ? "" : (id as NSString).pathExtension.lowercased() }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            // 揃える前に保存した作業ファイルのために、読むときにもかける(走査の側で直すようにしたのは後から)。
            name = BookName.normalized(try c.decode(String.self, forKey: .name))
            isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
            confirmation = try c.decodeIfPresent(Confirmation.self, forKey: .confirmation) ?? .none
        }

        /// 直していない本は `confirmation` を、ファイルの本は `isFolder` を書かない(作業ファイルを小さく、差分を読みやすく保つ)。
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            if isFolder { try c.encode(isFolder, forKey: .isFolder) }
            if confirmation != .none { try c.encode(confirmation, forKey: .confirmation) }
        }

        enum CodingKeys: String, CodingKey { case id, name, isFolder, confirmation }
    }

    /// フォルダごとの型の並びの割り当て(CLI の `--presets` と同じ形)。
    /// 起点からの相対パスの頭が合うものを使い、長い頭から先に見る。
    public struct PresetAssignment: Codable, Sendable, Hashable {
        /// どのフォルダにも当たらない本が使う名前(nil なら同梱の既定)。
        public var defaultPreset: String?
        /// 相対パスの頭 → プリセットの名前。
        public var folders: [String: String]

        public init(defaultPreset: String? = nil, folders: [String: String] = [:]) {
            self.defaultPreset = defaultPreset
            self.folders = folders
        }

        public func preset(for id: String) -> String? {
            let match = folders.keys.filter { id == $0 || id.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            return match.flatMap { folders[$0] } ?? defaultPreset
        }

        enum CodingKeys: String, CodingKey { case defaultPreset = "default", folders }
    }

    public init(rootPath: String, books: [Book], presets: PresetAssignment = .init(), savedAt: Date? = nil) {
        kind = Self.kind
        formatVersion = Self.formatVersion
        self.rootPath = rootPath
        self.books = books
        self.presets = presets
        self.savedAt = savedAt
    }

    /// 提案を計算する入力(本ごとにプリセットを割り当てたもの)。
    public var inputs: [BookInput] {
        books.map { BookInput(id: $0.id, name: $0.name, preset: presets.preset(for: $0.id), confirmation: $0.confirmation) }
    }

    /// 起点の直下のフォルダ(プリセットを割り当てる単位。名前は利用者の蔵書のもの)。
    public var topLevelFolders: [String] {
        Set(books.compactMap { $0.id.contains("/") ? String($0.id[..<$0.id.firstIndex(of: "/")!]) : nil }).sorted()
    }

    public enum LoadError: Error, Sendable, Hashable, CustomStringConvertible {
        case notAWorkfile
        case newerFormat(Int)

        public var description: String {
            switch self {
            case .notAWorkfile: "qooMeta の作業ファイルではありません"
            case .newerFormat(let v): "作業ファイルの形式が新しい(version \(v))。qooMeta を新しくしてください"
            }
        }
    }

    /// 書き出し(本体はファイルに触らないので、Data を返すところまで。保存は利用側)。
    public func encoded() throws -> Data {
        var copy = self
        copy.savedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    public static func decoded(_ data: Data) throws -> Workfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(Workfile.self, from: data)
        guard file.kind == Self.kind else { throw LoadError.notAWorkfile }
        guard file.formatVersion <= Self.formatVersion else { throw LoadError.newerFormat(file.formatVersion) }
        return file
    }
}
