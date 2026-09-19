import Foundation

/// 走査で見つけた本 1 冊分のファイル情報。
public struct BookFile: Codable, Sendable, Equatable {
    public var path: String
    /// 走査の起点からの相対パス(フォルダの手がかりに使う)。
    public var relativePath: String
    public var baseName: String
    public var fileExtension: String
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    /// qooViewer がファイルを同定する手段(パスが変わっても追える)。qooViewer の JSON へそのまま書く。
    public var inodeNumber: Int64?
    public var volumeDeviceNumber: Int64?
    public var volumeUUID: String?

    public init(path: String, relativePath: String, baseName: String, fileExtension: String,
                size: Int64? = nil, created: Date? = nil, modified: Date? = nil,
                inodeNumber: Int64? = nil, volumeDeviceNumber: Int64? = nil, volumeUUID: String? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.size = size
        self.created = created
        self.modified = modified
        self.inodeNumber = inodeNumber
        self.volumeDeviceNumber = volumeDeviceNumber
        self.volumeUUID = volumeUUID
    }

    /// 入っているフォルダの名前(起点の直下なら空)。
    public var folderName: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

/// 1 冊分の提案。ファイル名の解析結果と、最終的に書き出す値。
public struct BookProposal: Codable, Sendable, Equatable {
    public var id: Int
    public var file: BookFile
    public var parsed: ParsedName
    /// 同じ書き手とみなす単位(サークル名の比較用の形。無ければフォルダ名)。
    public var circleKey: String
    /// 所属するシリーズ候補(SeriesGroup.id)。
    public var groupID: Int?
    /// 最終的なシリーズ名(候補の判定を反映したもの)。空ならシリーズなし。
    public var series: String = ""
    /// 巻。数字とは限らない(「上」「前編」など)。
    public var volumeText: String = ""
    /// 巻を数値として読めたときの値(Stackroom の Volume は数値だけを持てる)。
    public var volumeNumber: Double?
    /// 巻をタイトルから読んだのではなく、推定したか(ProposalFinalizer.inferFirstVolumes)。
    public var volumeInferred: Bool?

    public init(id: Int, file: BookFile, parsed: ParsedName, circleKey: String) {
        self.id = id
        self.file = file
        self.parsed = parsed
        self.circleKey = circleKey
    }
}

/// 端末内モデルの判定結果。
public struct AIVerdict: Codable, Sendable, Equatable {
    public enum Confidence: String, Codable, Sendable { case high, medium, low }

    public var isSeries: Bool
    public var seriesName: String
    /// シリーズから外すべき本(BookProposal.id)。
    public var excludedIDs: [Int]
    public var confidence: Confidence
    public var seconds: Double

    public init(isSeries: Bool, seriesName: String, excludedIDs: [Int], confidence: Confidence, seconds: Double) {
        self.isSeries = isSeries
        self.seriesName = seriesName
        self.excludedIDs = excludedIDs
        self.confidence = confidence
        self.seconds = seconds
    }
}

/// 規則で作ったシリーズの候補(同じ書き手の、タイトルの前半が共通する本の組)。
public struct SeriesGroup: Codable, Sendable, Equatable {
    public var id: Int
    public var circleKey: String
    public var memberIDs: [Int]
    /// 規則が求めたシリーズ名(共通する前半部分を、元の表記で)。
    public var ruleName: String
    /// 全員が語の切れ目で切れているか(途中で切れた共通部分は、偶然の一致の疑いがある)。
    public var cleanBoundary: Bool
    /// この前半部分で始まるタイトルを持つ書き手の数(多いほど、ありふれた言葉の疑い)。
    public var circlesSharingPrefix: Int
    public var aiVerdict: AIVerdict?
    /// 1 冊でもシリーズにする組(本編のシリーズがある総集編。SeriesGrouper)。
    public var allowsSingle: Bool?
    /// 判定できなかった理由(安全装置による拒否など)。
    public var aiError: String?

    public init(id: Int, circleKey: String, memberIDs: [Int], ruleName: String, cleanBoundary: Bool,
                circlesSharingPrefix: Int) {
        self.id = id
        self.circleKey = circleKey
        self.memberIDs = memberIDs
        self.ruleName = ruleName
        self.cleanBoundary = cleanBoundary
        self.circlesSharingPrefix = circlesSharingPrefix
    }
}

/// 提案一式。走査 → 候補 → 判定 → 書き出しの各段がこのファイルを読み書きする。
///
/// **中身は蔵書の名前そのもの**なので、リポジトリの外に置く(CLI は Git の作業ツリーの中へは書かない)。
public struct ProposalDocument: Codable, Sendable {
    public var formatVersion = 1
    public var createdAt: Date
    public var rootPath: String
    public var minPrefix: Int
    public var books: [BookProposal]
    public var groups: [SeriesGroup]

    public init(createdAt: Date = Date(), rootPath: String, minPrefix: Int, books: [BookProposal],
                groups: [SeriesGroup]) {
        self.createdAt = createdAt
        self.rootPath = rootPath
        self.minPrefix = minPrefix
        self.books = books
        self.groups = groups
    }
}
