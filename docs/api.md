# API

**最新(2026-09-21 時点の実装)。** qooMeta をライブラリとして使うときの API。型名・引数名は実装どおりで、コード例は
一時的なテストでコンパイルと動きを確かめたもの。欄は `BookMetadata`(タイトル・著者の並び・ジャンル・イベント・原作・情報・
シリーズ・巻数)で、以前の案にあったサークル・ネタ・関連・本の種別の語彙(`Vocabulary`・`mediaTypes`)・`config.json` は無い。
規則ファイルの形は [rules.md](rules.md)・[filename-format.md](filename-format.md)、欄の意味は [metadata.md](metadata.md)。

## 前提

| 利用側 | 持っているもの | 欲しいもの |
|---|---|---|
| qooViewer | 本のパス・ファイルノード、登録済みのメタデータ(著者・タイトル・シリーズ・巻) | 「メタデータの編集」の初期値、シリーズ・巻、なぜそうなったかの説明 |
| StackNest | 本のパス・DB の ID | 取り込み時の補完、既存の本の一括補完 |
| ShelfRow | 本のパス | タイトル・著者・原作などの補完(シリーズの欄は無い) |
| qooMeta のアプリ・CLI | フォルダ | 一括の提案、見直し、作業ファイル、書き出し |

- **下限は macOS 15**。本体(`QooMetaKit`)は Foundation(と CryptoKit)だけに依存する。端末内モデル(`QooMetaAI`)だけが macOS 26 以降。
- **Swift 6.2 以降**(`@concurrent` を使う)。厳格な並行性で、利用側が既定でメインアクターに隔離していても呼べる。

## 方針

1. **本体は純粋な計算にする。** ファイルを読まない・書かない、通信しない、ログを出さない、グローバルな状態を持たない
   (`scripts/ci/check-kit-purity.sh` が確かめる)。規則のデータと辞書は利用側が値で渡す。書き出しも作業ファイルも `Data` を返すまで。
2. **利用側の識別子を尊重する。** 本は利用側の不透明な ID(文字列)で指す。qooMeta は中身を解釈しない
   (アプリと CLI は、走査の起点からの相対パスを ID にしている)。
3. **読むのはファイル名だけ。** フォルダ名は欄にしない(3 つのアプリがどれも読まないため)。フォルダは、どの型の並び
   (プリセット)で読むかを選ぶ手がかりにだけ使う。
4. **まとめて渡す。** シリーズは本どうしを見比べて決める。1 冊だけの読み取り(`parseName`)は別に用意する。
5. **変えた分だけ計算し直せる。** 比べる単位(書き手 = 著者の先頭 + ジャンル)ごとに持ち、変わった単位だけを計算し直す。
   そのために、**提案は単位の中だけで決まる**ようにしている(単位をまたぐ情報は提案に含めない)。
6. **出力は決まった順で、毎回同じ。** 同じ入力(本・規則・辞書)なら同じ出力。
7. **文字列ではなく値と符号を返す。** 表示の言葉は利用側が決める(例外は CLI 用の `description` と、書き出しの欄の見出し)。
8. **利用者が確定させた値に従う。** 道具の側で偏りをかけず、読んだ結果を見せて利用者が直す([concept.md](concept.md))。

## モジュール

`Package.swift` のコメントと同じ分け方。

| モジュール | 役割 | 依存 |
|---|---|---|
| `QooMetaKit` | 名前の読み取り(型の並び)・シリーズ・巻・版・推定、規則の組み立てと検証、規則とプリセットのカタログ、規則の変更(`RuleChanges`)、変更の索引(`ProposalIndex`)、まとめて編集、作業ファイル、例のファイル、フィードバック、説明 | Foundation |
| `QooMetaRules` | 同梱の既定値のデータ(`series-rules.json`・`filename-formats.json`・`examples.json`)の読み込み口と、システムの辞書 | QooMetaKit |
| `QooMetaExport` | Stackroom XML・qooViewer JSON・ComicInfo と、書き出し先ごとの欄の対応表(`FieldMapping`)。`Data` を返す | QooMetaKit |
| `QooMetaScan` | フォルダの走査(名前と属性だけ。書庫の中身は開かない) | QooMetaKit |
| `QooMetaAI` | 端末内モデルによるシリーズの判定(任意、macOS 26 以降) | QooMetaKit |

## 流れ

```
規則のデータ(同梱 + 利用者の差分)──compile──▶ CompiledRules
                                                    │
走査(QooMetaScan)/ 作業ファイル(Workfile)──▶ [BookInput] ──▶ proposeSync / propose ──▶ ProposalSet
                                                    │                                         │
                                                    └──▶ ProposalIndex(変えた分だけ計算し直す)─┤
                                                                                              ▼
                                               BulkEdit(直しを Confirmation にする) ◀── 利用者の見直し
                                                                                              │
                                                     Exporter + FieldMapping(書き出し先ごとの欄)◀┘
```

いちばん短い使い方(README と同じもの):

```swift
import QooMetaKit
import QooMetaRules

let books = [
    BookInput(id: "1", name: "[架空工房] 月の庭 1", preset: "commercial"),
    BookInput(id: "2", name: "[架空工房] 月の庭 2", preset: "commercial"),
]
let set = proposeSync(books, rules: .builtin, dictionaries: SystemDictionaries.all)
for book in set.proposals {
    print(book.metadata.series, book.metadata.volume)   // 月の庭 1 / 月の庭 2
}
```

シリーズの組そのもの(`SeriesProposal`。名前・種類・巻の順の本・根拠)は `book.seriesID.flatMap { set.series($0) }` で引く。

## 1. 規則を組み立てる

規則は 2 つの JSON に分かれている。どちらも同梱の既定値に、利用者の変更(差分)を重ねて使う。

- `filename-formats.json`: 型の並び(プリセット)。ファイル名のどこが何の欄か、著者の区切り、既定の欄、型として読まない文字列、
  本ごとに自動で選ぶ条件(`auto`)。
- `series-rules.json`: タイトルからシリーズ名と巻を導く規則(`policies`・`compare`・`markers`・`grouping`・`naming`・`volume`・`lists`)。

```swift
/// 同梱の 2 つの JSON(読むのは QooMetaRules の `BuiltInRules.bundled()`)。
public struct BuiltInRules: Sendable {
    public init(seriesRules: Data, filenameFormats: Data)
}

/// 同梱の既定値と、利用者の変更(差分。シリーズの規則・フォーマット・rules-bundle のどれか)。
public struct RuleSources: Sendable {
    public init(builtIn: BuiltInRules, userChanges: Data? = nil)
}

public struct CompiledRules: Sendable {
    /// 誤りは**すべて**集めて返す(1 件でもあれば rules は nil)。`dictionaries` は利用側が渡せる辞書の名前。
    public static func compile(_ sources: RuleSources, dictionaries: Set<String> = ["english"]) -> RulesCompilation
    public static let engineLevel: Int                  // 本体が知っている規則の水準(規則の `since` と比べる)
    public let formats: FormatPresets                   // 名前を付けた型の並び
    public let contentHash: String                      // 内容から計算(`revision` には依らない)。キャッシュの判定用
    public let changedPaths: [String]                   // 利用者の変更が効いている値の道筋
    public let mergedSeriesRules: JSONValue, mergedFilenameFormats: JSONValue      // 重ねた結果
    public let defaultSeriesRules: JSONValue, defaultFilenameFormats: JSONValue    // 重ねる前
    public var catalog: RuleCatalog { get }             // シリーズの規則の編集画面用
    public var presetCatalog: PresetCatalog { get }     // 型の並びの編集画面用

    /// 方針と値だけを置き換えた規則(例のファイル・「好み」の切り替え)。
    public func applying(policies: [String: String], settings: [String: JSONValue] = [:],
                         dictionaries: Set<String> = ["english"]) -> RulesCompilation
    /// 型の並びだけを差し替えたもの(公開データの採点のように、別のプリセットで読みたいとき)。
    public func replacingFormats(_ formats: FormatPresets) -> CompiledRules
    public func replacingFormats(_ formats: FilenameFormats) -> CompiledRules
}

public struct RulesCompilation: Sendable {
    public let rules: CompiledRules?
    public let errors: [RulesIssue]
    public let warnings: [RulesIssue]                   // 新しい版の規則を飛ばした、廃止された ID、辞書が無い、など
}

public struct RulesIssue: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Code: String, Sendable, Hashable {
        case malformedJSON, wrongKind, unsupportedSchemaVersion, unknownKey, missingKey, invalidValue, duplicateID,
             unresolvedList, unsafePattern, tooLarge, notYetSupported
        case newerRuleSkipped, requiredRuleUnknown, retiredID, missingDictionary   // ここから警告
    }
    public var code: Code
    public var source: String         // "builtin" / "user" / "examples"
    public var path: String           // JSON の中の道筋("grouping.sharedPrefix.minPrefx")
    public var detail: String?        // 値や理由(壊れた JSON は行・列)
    public var suggestion: String?    // 近い綴りの候補
    public var isWarning: Bool { get }
}
```

`QooMetaRules` が、同梱の既定値とシステムの辞書の読み込み口を持つ(本体はファイルを読まないので):

```swift
extension BuiltInRules { public static func bundled() throws -> BuiltInRules }
extension CompiledRules { public static let builtin: CompiledRules }       // 同梱の既定値だけを組み立てたもの
extension ExampleFile { public static func bundled() throws -> ExampleFile } // 同梱の例

public enum SystemDictionaries {
    public static let english: WordSet?                  // /usr/share/dict/words(約 24 万語)。1 度だけ読む
    public static var all: [String: WordSet] { get }     // 規則が指す名前 → 辞書("english")
}
```

利用者の変更を重ねて組み立てる:

```swift
var changes = RuleChanges.none
changes.setPolicy("ownSeries", for: "compilations")
let compilation = CompiledRules.compile(
    RuleSources(builtIn: try BuiltInRules.bundled(), userChanges: changes.data()),
    dictionaries: Set(SystemDictionaries.all.keys))
guard let rules = compilation.rules else {
    // 表示の言葉は利用側で。code・path・detail・suggestion から組み立てる。
    for issue in compilation.errors { print(issue.code, issue.path, issue.detail ?? "") }
    return
}
```

- 規則は辞書を名前(`"english"`)で指すだけで、パスを持たない(規則ファイルから利用側のファイルを読ませないため)。
  渡されなかった辞書を使う条件は働かず、`missingDictionary` の警告になる。
- `applying(policies:settings:)` の `settings` は、点つなぎの場所(`grouping.compilation.singleWhenMainExists`)→ 値。
  **すでにある場所だけ**を置き換える(書き間違いを黙って新しいキーにしない。無い場所は `unknownKey`)。
- 組み立てた規則は不変で、スレッドをまたいで共有してよい。組み立ては 1 度だけにして使い回す。

## 2. 入力

```swift
public struct BookInput: Sendable, Hashable {
    public var id: String                 // 利用側の ID
    public var name: String               // 拡張子を除いたファイル名(フォルダの本は名前の全体)
    public var preset: String?            // どの型の並びで読むか。nil なら既定(FormatPresets.defaultName)
    public var confirmation: Confirmation
    public init(id: String, name: String, preset: String? = nil, confirmation: Confirmation = .none)
}

/// 利用者が確定させた内容。
public enum Confirmation: Sendable, Hashable, Codable {
    case none
    case fields(ConfirmedFields)                                            // 欄だけ。シリーズについては何も言っていない
    case series(name: String, volume: String?, fields: ConfirmedFields = .init())   // volume が nil なら巻は未確定
    case notInSeries(fields: ConfirmedFields = .init())
    public var fields: ConfirmedFields { get }
}

/// 確定した欄(書いていない欄は未確定)。並びの欄(著者)は値の並び、1 つの値の欄は先頭だけを使う。
public struct ConfirmedFields: Sendable, Hashable, Codable {
    public var values: [BookMetadata.Field: [String]]
    public init(_ values: [BookMetadata.Field: [String]] = [:])
    public subscript(field: BookMetadata.Field) -> [String]? { get set }
    public func applied(to metadata: BookMetadata) -> BookMetadata
}
```

- `preset` を本ごとに持つのは、1 つの蔵書に商業誌と同人誌が混ざっていて、フォルダごと・本ごとに読み方を変えたいため
  (選び方は「6. プリセットと本ごとの割り当て」)。
- 名前は `BookName.normalized(_:)`(合成済みにして前後の空白を落とす)にかけてから渡す。macOS はファイル名を分解形で返すことがあり、
  そのままだと濁点を含む語が規則の語と当たらない。走査(`QooMetaScan`)と作業ファイルの読み込みは、自分でかけている。
- 制御文字と書式文字(Cc・Cf)は、本体が読む前に落とす。上限(`InputLimits`: 名前 1,000 文字・100 万冊)を超えた入力と
  重なった ID は扱わず、`ProposalSet.rejected` に理由(`emptyName`・`nameTooLong`・`duplicateID`・`tooManyBooks`)を返す。

### 欄(`BookMetadata`)

```swift
public struct BookMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var authors: [String]      // 並びなのは著者だけ。比べる単位の書き手はこの先頭
    public var genre: String
    public var event: String          // 頒布会の名前(型で `(@event)` と書いたときだけ入る)
    public var source: String         // 原作(予約語 `@source`)
    public var info: String           // 情報(名前の中の付記。予約語 `@info`)
    public var series: String         // 中核が導く(`@series` で名前から読むこともできる)
    public var volume: String         // 巻数(表示用。名前のとおりの表記)
    public var volumeSort: Double?    // 巻数(ソート用。総集編のオフセットを足した数)
    public enum Field: String, CaseIterable, Codable { case title, authors, genre, event, source, info, series, volume }
    public func values(_ field: Field) -> [String]
    public subscript(field: Field) -> String { get }
    public mutating func set(_ field: Field, to newValues: [String])   // 巻数(表示用)を変えるとソート用は捨てる
    public static func volumeSortText(_ value: Double) -> String
}
```

空の欄は空の文字列・空の並びで表す(「無い」と「空」を分けない)。どの欄を書き出し先のどの欄へ渡すかは、欄の側ではなく
書き出しの対応表(`FieldMapping`)で決める。

### 確定した値の効き方

- 確定した欄は、名前の読み取りの結果より優先する(比べる単位も確定した値で決まる)。型が `@series`・`@volume` で名前から読んだ
  シリーズと巻数も、確定した値と同じ扱いで中核へ渡る(利用者の確定がさらに優先)。
- `.series(name:)` の本は**錨**になる。規則が同じ組にした未確定の本は、確定した名前のシリーズに入る。
  1 つの組に確定した名前が 2 種類以上あれば、組を名前ごとに割り、未確定の本はタイトルの先頭がいちばん長く一致する名前へ入れる。
- 同じ単位で同じ名前に確定した本は、規則が別の組にしていても同じシリーズにする。
- `.notInSeries` の本はどのシリーズにも入れない。残りが 2 冊に満たなければ、その組はシリーズにしない。
- 確定した巻はそのまま使う。`volume: ""` は「巻は無い」と確定したこと(1 巻の推定もしない)。
- **qooViewer の注意**: qooViewer の DB では「シリーズが空」は未入力の意味で、「シリーズではない」と区別できない。
  シリーズが空の登録は `.fields` として渡す。

## 3. 1 冊の読み取り

```swift
/// ファイル名を型で読んで欄に分ける(シリーズと巻数は中核が導くので、ここでは `@series`・`@volume` で読めたときだけ入る)。
public func parseName(_ name: String, rules: CompiledRules, preset: String? = nil) -> FormatReading

public struct FormatReading: Sendable, Hashable {
    public var metadata: BookMetadata
    public var formatIndex: Int?          // 一致した型の番号(0 から)。nil なら合わなかった(名前全体が仮のタイトル)
    public var spans: [Span]              // 名前のどこがどの欄か(文字 = Character の番号。色分け用)
    public var nearest: Nearest?          // 合わなかったとき、最も近い型と、どこで外れたか
}

extension FilenameFormats {
    /// 読めぐあい(.read / .leftover / .unread)と、直すところの位置まで返す。型の並びを直す画面と、段 2 の指標が使う。
    public func check(_ name: String) -> FormatCheck
}
```

```swift
let reading = parseName("[架空工房] 月の庭 (作品A)", rules: rules, preset: "doujinshi")
// reading.metadata.authors == ["架空工房"], title == "月の庭", source == "作品A"
let check = rules.formats["doujinshi"].check("[架空工房] 月の庭 (作品A)")   // check.outcome == .read
```

- 型の書き方(予約語 `@title` `@author` `@genre` `@event` `@source` `@info` `@series` `@volume` `@ignore`)は
  [filename-format.md](filename-format.md)。型を 1 つ組み立てるのは `FilenameFormat(_:separators:defaults:plain:)`(誤りは `FormatError`)。
- `FormatPresets` は名前 → `FilenameFormats`(型の並び)。`rules.formats[name]` は、無い名前なら既定のプリセットを返す。
  同梱の名前は `commercial`・`doujinshi`・`doujinshi-event`(コードの側の既定は `FormatPresets.bundled`)。
- `.leftover` は、型には合ったがどの欄にもならない括弧がタイトルに残ったこと。題の途中の括弧は既定では数えない
  (`ignoresBracketsInsideTitle`。どの型でも欄になりようがなく、数えると直しようのない警告になるため)。

## 4. まとめて提案する

```swift
/// CPU を使う同期の計算。メインスレッドの外で呼ぶ。
public func proposeSync(_ books: [BookInput], rules: CompiledRules, dictionaries: [String: WordSet],
                        options: ProposalOptions = .default) -> ProposalSet

/// 同じ計算を呼び出し側のアクターの外で、塊ごとに並列に行う。Task の取り消しと進み具合の通知に対応する。
@concurrent
public func propose(_ books: [BookInput], rules: CompiledRules, dictionaries: [String: WordSet],
                    options: ProposalOptions = .default,
                    progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError) -> ProposalSet

public struct ProposalOptions: Sendable, Hashable {
    public init(explanations: Bool = false, limits: InputLimits = .default)   // 説明は費用がかかるので既定は無し
}

public struct ProposalSet: Sendable {
    public let proposals: [BookProposal]      // 入力と同じ順
    public let series: [SeriesProposal]       // 決まった順(書き手 → 名前 → 最小の本の ID)
    public let rulesHash: String
    public let rejected: [InputIssue]
    public subscript(id: String) -> BookProposal? { get }
    public func series(_ id: SeriesID) -> SeriesProposal?
}

public struct BookProposal: Sendable, Hashable {
    public enum Flag: String, CaseIterable {
        case inferredVolume, edition, source, compilation, magazineIssue, confirmed, standalone
    }
    public let id: String
    public let name: String                   // 入力の名前(並べ替え「ファイル名順」に使う)
    public let reading: FormatReading         // 型で読んだ結果(確定した欄は重ねていない)
    public let metadata: BookMetadata         // 提案の欄(読んだ欄 + 確定した欄 + 中核が導いたシリーズと巻数)
    public let seriesID: SeriesID?
    public let flags: Set<Flag>
}

public struct SeriesProposal: Sendable, Hashable, Identifiable {
    public enum Kind: String { case series, compilation, magazineYear }
    public enum Evidence: Hashable { case volumeHead, sharedPrefix(cleanCut: Bool), compilation, confirmed }
    public let id: SeriesID
    public let name: String
    public let kind: Kind
    public let memberIDs: [String]            // 巻の順
    public let evidence: Evidence
}
```

- 巻は `BookProposal.metadata.volume`(表記)と `volumeSort`(並べ替え用)に入る。`flags` の `.inferredVolume` は、番号の無い
  1 冊を 1 巻とみなしたこと。`Volume`(`text`・`sortKey`・`inferred`)は `SeriesDerivation` と `ProposalIndex` の内側で使う形。
- 認識の結果(`flags` の `.edition`・`.source`・`.compilation`・`.standalone`)は、**方針に関わらず返す**。総集編を本編に
  含めるか・版違いを別の本として数えるかは規則の `policies` で選べるが、利用側が印を見て自分の扱いを決めてもよい。
- 方針(`policies`)の名前と選べる値は `rules.catalog.policies` で引ける(`editions`・`sources`・`compilations`・
  `compilationVolume`・`magazines`・`unnumberedFirst`・`unnumberedVolume`・`differentRelation`・`differentGenre`・`subtitled`)。

### `SeriesID` の約束

- `SeriesID` は**その `ProposalSet`(または `ProposalIndex` のいまの状態)の中でだけ意味を持つ**。本を足すとシリーズ名が変わりうるので、
  ID も変わりうる。利用側は `SeriesID` を保存しない。**保存するのは確定した内容(`Confirmation`)**。
- 同じ書き手・ジャンル・名前の組が複数できることがある(原作の違いで割れた組)。ID は組の中の最小の本の ID を含めて作り、重ならない。
- 同じ入力なら同じ ID になる。

### 説明

```swift
/// なぜその提案になったか。options.explanations のときだけ作る。表示の言葉は含まない(規則の ID)。
public struct Explanation: Sendable, Hashable {
    public let appliedRules: [String]         // "volumeHead"・"firstVolume"・"number"・"edition" …
    public let nearMisses: [NearMiss]         // 組になりかけて、ならなかった相手
}
public struct NearMiss: Sendable, Hashable {
    public let otherID: String
    public let sharedPrefixLength: Int
    public let rejectedBy: String             // "reject-single-script"・"splitByRelation"・"rejectSameWork"・"sharedPrefix" …
}
extension ProposalSet {
    public func explanation(for id: String) -> Explanation?
    /// ありふれた言葉の疑い: そのシリーズ名で始まるタイトルを持つ書き手の数。単位をまたぐので提案には含めず、ここで数える。
    public func prefixCommonness(of id: SeriesID, rules: CompiledRules) -> Int
}
```

「なぜこの 2 冊がシリーズにならないのか」に答えるためのもの(規則を育てる作業の中心になる問い)。

## 5. 変更の索引(`ProposalIndex`)

本の追加・変更・削除のたびに、影響のある単位だけを計算し直す。アプリの一覧はこの上に載っている。

```swift
public actor ProposalIndex {
    public init(rules: CompiledRules, dictionaries: [String: WordSet], options: ProposalOptions = .default)
    /// 空の索引へ一覧をまとめて入れる(名前の読み取りも単位の計算も並列)。空でなければ apply と同じ道を通る。
    public func load(_ inputs: [BookInput]) async throws(CancellationError)
    /// 足す・変える・消す。影響のある単位だけを計算し直し、変わった所を返す。
    @discardableResult public func apply(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta
    /// 状態を変えずに、変更を当てた場合の差分を返す(「ほかに n 冊がこのシリーズに入ります」)。
    public func preview(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta
    /// 規則・辞書を替えて読み直す(並列)。型の並びも巻の読み手も変わっていなければ、名前は読み直さない。
    public func reload(rules: CompiledRules, dictionaries: [String: WordSet]) async throws(CancellationError)
    /// 同じことを 1 本で行い、前後の差分を返す。
    @discardableResult public func update(rules: CompiledRules, dictionaries: [String: WordSet]) throws(CancellationError) -> ProposalDelta
    public func proposal(for id: String) -> BookProposal?
    public func snapshot() -> ProposalSet     // 作り置きしない。要るとき(開いた・規則を替えた・書き出す)にだけ呼ぶ
}

public enum BookChange: Sendable, Hashable { case upsert(BookInput), remove(id: String) }

public struct ProposalDelta: Sendable {
    public let changed: [BookProposal]        // 変わった(または新しく入った)本
    public let removedBooks: [String]
    public let removedSeries: [SeriesID]
    public let changedSeries: [SeriesProposal]
}
```

```swift
let index = ProposalIndex(rules: rules, dictionaries: SystemDictionaries.all)
try await index.load(workfile.inputs)
let set = await index.snapshot()
// 選んだ本を同じシリーズにする。BulkEdit は Confirmation を返すだけなので、入力に書き戻して apply する。
let edits = BulkEdit.setSeries("月の庭", for: selectedIDs, in: set)
let changes = edits.map { id, confirmation in
    BookChange.upsert(BookInput(id: id, name: set[id]!.name, preset: workfile.presets.preset(for: id),
                                confirmation: confirmation))
}
let ripple = try await index.preview(changes)     // 錨の効果で、ほかの本の提案も変わりうる
try await index.apply(changes)
```

- **`apply` の結果は、同じ本の一覧(入れた順)を `proposeSync` に渡した結果と常に同じ**(テストで確かめている)。
- **全か無か**: 取り消されたら、状態は呼ぶ前のまま。変える前の値は変わった所だけ控える(1 冊の変更が冊数に比例しないように)。

### まとめて編集(`BulkEdit`)

複数の本の確定した内容を、まとめて組み立てる。**値(本の ID → `Confirmation`)を返すだけ**で、何も保存しない
(保存と取り消しは利用側)。`current` に今の確定した内容を渡すと、変えない欄と巻を保つ。

```swift
public enum BulkEdit {
    /// 選んだ本のタイトルの共通部分を、語の切れ目まで縮めて規則の名前の整え方に通したもの(無ければ nil)。
    public static func suggestedSeriesName(for ids: [String], in set: ProposalSet, rules: CompiledRules) -> String?
    public static func suggestedSeriesName(forTitles titles: [String], rules: CompiledRules) -> String?

    public static func setSeries(_ name: String, for ids: [String], in set: ProposalSet,
                                 current: [String: Confirmation] = [:]) -> [String: Confirmation]
    public static func setFields(_ fields: ConfirmedFields, for ids: [String], in set: ProposalSet,
                                 current: [String: Confirmation] = [:]) -> [String: Confirmation]
    /// 並べた順に、上から巻を振る(Numbering: start・step・padding = .matchSeries / .none / .width(n))。
    public static func numberSequentially(_ orderedIDs: [String], in set: ProposalSet, seriesName: String? = nil,
                                          numbering: Numbering = .init(),
                                          current: [String: Confirmation] = [:]) -> [String: Confirmation]
    public static func removeFromSeries(_ ids: [String], in set: ProposalSet,
                                        current: [String: Confirmation] = [:]) -> [String: Confirmation]
    public static func revertToProposal(_ ids: [String]) -> [String: Confirmation]              // すべて .none
    public static func acceptProposals(_ ids: [String], in set: ProposalSet) -> [String: Confirmation]
    /// 「巻は無い」と確定する(.series(name:volume: ""))。シリーズに入っていない本は何もしない。
    public static func clearVolumes(_ ids: [String], in set: ProposalSet,
                                    current: [String: Confirmation] = [:]) -> [String: Confirmation]
    /// 連番の前の並べ替え(Order: .title / .name / .date / .currentVolume)。日付は利用側が渡す。
    public static func sorted(_ ids: [String], by order: Order, in set: ProposalSet, dates: [String: Date] = [:]) -> [String]
}
```

巻は表記(文字列)で確定する。並べ替え用の数は、表記を巻の読み手に通して決まる。

## 6. プリセットと本ごとの割り当て

どの型の並びで読むかは本ごとに決める(`BookInput.preset`)。決め方は 2 つあり、どちらも最後は `Workfile.PresetAssignment` に入る。

### フォルダごと・本ごとの割り当て(`Workfile.PresetAssignment`)

```swift
public struct PresetAssignment: Codable, Sendable, Hashable {
    public var defaultPreset: String?           // どこにも当たらない本が使う名前(nil なら同梱の既定)。JSON では "default"
    public var folders: [String: String]        // 起点からの相対パスの頭(フォルダか、本の ID そのもの)→ プリセットの名前
    public init(defaultPreset: String? = nil, folders: [String: String] = [:])
    public func preset(for id: String) -> String?
}
```

長い頭から先に見る(本の ID そのもの → そのフォルダ → その上のフォルダ …)。割り当てを全部なめないので、本ごとの割り当てが
1 万件あっても 1 冊あたりの手間は変わらない。CLI の `--presets` も同じ形。

### 本ごとに自動で選ぶ(`PresetAutoRule`・`PresetAutoChoice`)

プリセットの `auto` に、そのプリセットを当てる条件を書く。条件は 2 段:
① フォルダのパスか名前に含む語(`words`)と、② ファイル名の先頭の語句(`headRequired` = 必須、`headExcluded` = 例外)。
大文字と小文字、全角と半角は同じとみなす。

```swift
public struct PresetAutoRule: Sendable, Hashable {
    public var words: [String]            // 空なら自動では選ばれない
    public var headRequired: [String]
    public var headExcluded: [String]
    public init(words: [String] = [], headRequired: [String] = [], headExcluded: [String] = [])
    public var isActive: Bool { get }
    public var requiresHead: Bool { get }
    public func fits(path: String, name: String) -> Bool
    public func explain(path: String, name: String) -> Explanation   // どの条件でどう決まったか(設定の画面用)
}

public enum PresetAutoChoice {
    public struct Book { public init(id: String, path: String, name: String) }   // path は起点を含めた全体
    public enum Decision { case none, one(String), many([String]) }
    public struct Result { public var assigned: [String: String]; public var unmatched: Int; public var ambiguous: Int
                           public var isComplete: Bool { get } }
    public static func decide(path: String, name: String, rules: [(name: String, rule: PresetAutoRule)]) -> Decision
    public static func choose(_ books: [Book], rules: [(name: String, rule: PresetAutoRule)]) -> Result
}
```

```swift
let autoRules = rules.presetCatalog.autoRules          // [(name, rule)]。同梱の順に、利用者のプリセットが続く
let choice = PresetAutoChoice.choose(workfile.books.map {
    PresetAutoChoice.Book(id: $0.id, path: workfile.rootPath + "/" + $0.id, name: $0.name)
}, rules: autoRules)
for (id, name) in choice.assigned { workfile.presets.folders[id] = name }   // 本の ID そのものに割り当てる
// choice.unmatched・choice.ambiguous は決まらなかった冊数。利用者に見せて、フォルダごとの割り当てで決めてもらう。
```

当たるものが 2 つ以上なら、先頭の語句を必須にしたもの(狭い条件)を採る。それでも絞れない本と、どれにも当たらない本は
**決めずに残す**(それ以上の順を道具の側で決めると、取り違えが見えないまま一覧に入るため)。語はコードに書かず、
同梱の JSON か利用者の設定が持つ。

### プリセットの一覧と編集(`PresetCatalog`)

```swift
public struct PresetCatalog: Sendable, Hashable {
    public struct Preset {        // name・label・note・separators・defaults・plain・ignoresBracketsInsideTitle・auto・formats
        public init(name: String, label: String = "", note: String = "", separators: [String]? = nil,
                    defaults: [String: String] = [:], plain: PlainText = .none,
                    ignoresBracketsInsideTitle: Bool = true, auto: PresetAutoRule = .none, formats: [Format] = [])
    }
    public struct Format { public init(text: String, separators: [String]? = nil, defaults: [String: String] = [:],
                                       plain: PlainText = .none) }
    public struct Entry: Identifiable { public let preset: Preset; public let original: Preset?   // 同梱の既定値(利用者のものは nil)
                                        public var isBuiltIn: Bool { get }; public var isModified: Bool { get } }
    public let entries: [Entry]               // 同梱の順に、利用者のプリセット(名前の順)が続く
    public let defaultPreset: String, builtInDefaultPreset: String
    public static var defaultFields: [String] { get }   // 既定を書ける欄(genre・event・source・info)
    public var autoRules: [(name: String, rule: PresetAutoRule)] { get }
}

extension RuleChanges {
    /// original が同梱の既定値なら違う所だけを差分に書き、nil なら利用者の新しいプリセットとして全体を書く。
    public mutating func setPreset(_ preset: PresetCatalog.Preset, original: PresetCatalog.Preset?)
    public mutating func removePreset(_ name: String)     // 同梱なら初期化、利用者のものなら削除
    public mutating func setDefaultPreset(_ name: String, builtIn: String)
}
```

```swift
let catalog = rules.presetCatalog
var preset = catalog.entries.first { $0.preset.name == "doujinshi" }!.preset
preset.name = "my-doujinshi"                       // 名前をつけて保存(元のプリセットは変わらない)
preset.label = "自分用"
preset.auto = PresetAutoRule(words: ["種別A"], headRequired: ["["])
var changes = RuleChanges.none
changes.setPreset(preset, original: nil)
changes.setDefaultPreset("my-doujinshi", builtIn: catalog.builtInDefaultPreset)
```

## 7. 作業ファイル(`Workfile`)

いま開いている一覧(本の ID と名前)・利用者の直し・プリセットの割り当てだけを持つ。**提案(シリーズ・巻)は持たない**
(規則を変えたら計算し直せばよく、古い提案が残ると食い違うため)。**ライブラリではない**。アプリの設定(規則の差分・
スタンプ・書き出しの対応表)は別に持つ: 設定はどの一覧にも共通で、作業ファイルは一覧ごとだから。

```swift
public struct Workfile: Codable, Sendable, Hashable {
    public static let kind = "qoometa.workfile"
    public static let formatVersion = 1
    public var rootPath: String                   // 走査の起点。本の ID はここからの相対パス
    public var books: [Book]                      // Book(id:name:isFolder:confirmation:)。直していない本は confirmation を書かない
    public var presets: PresetAssignment
    public init(rootPath: String, books: [Book], presets: PresetAssignment = .init(), savedAt: Date? = nil)
    public var inputs: [BookInput] { get }        // 本ごとにプリセットを割り当てた、提案の入力
    public var topLevelFolders: [String] { get }  // プリセットを割り当てる単位
    public func encoded() throws -> Data          // 保存は利用側(本体はファイルに触らない)
    public static func decoded(_ data: Data) throws -> Workfile   // 種類と版を確かめる(LoadError)
}
```

```swift
let workfile = try Workfile.decoded(data)
let set = proposeSync(workfile.inputs, rules: rules, dictionaries: SystemDictionaries.all)
```

**中身は蔵書の名前そのもの**なので、書き出す先は利用者が選んだ場所だけ(リポジトリの中には書かない)。

## 8. 規則の変更(`RuleChanges`)と一覧(`RuleCatalog`)

利用者の変更は、既定値との差分として持つ。作った差分はそのまま `RuleSources.userChanges` に渡せ、値の正しさは組み立てのとき
(`compile`)にすべて確かめる。保存先は利用側が決める。

```swift
public struct RuleChanges: Sendable, Hashable {
    public static var none: RuleChanges { get }
    public init(data: Data) throws(RulesIssue)          // 差分(どちらかの半分)か rules-bundle を読む
    public var isEmpty: Bool { get }
    public func data() -> Data                          // rules-bundle(両方の半分。キーを並べ替えるので同じ変更なら同じバイト列)

    public enum Half { case fileNames, series }         // filename-formats / series-rules。画面も別々に持つ
    public func isEmpty(_ half: Half) -> Bool
    public func data(_ half: Half) -> Data              // 片側だけの差分(画面に出して直に書き換えてもらう)
    public mutating func replace(_ half: Half, with data: Data) throws(RulesIssue)
    public mutating func reset(_ half: Half)

    // 方針・規則・値
    public mutating func setPolicy(_ choice: String, for policy: String)
    public mutating func resetPolicy(_ policy: String)
    @discardableResult public mutating func setEnabled(_ enabled: Bool, rule: String) -> Bool   // 知らない ID なら false
    @discardableResult public mutating func setValue(_ value: JSONValue, rule: String, parameter: String) -> Bool
    public mutating func resetValue(rule: String, parameter: String)
    public mutating func reset(rule: String)
    public mutating func setReaderOrder(_ ids: [String])
    public mutating func resetReaderOrder()

    // 語の規則(markers)
    public static var markerTreatments: [String] { get }   // keep・edition・source・compilation・standalone
    public mutating func addMarker(id: String, treat: String, words: [String] = [], patterns: [String] = [])
    public mutating func removeMarker(id: String)           // 足した規則だけ(同梱の規則は止めるだけ)
    public mutating func setMarkerOrder(_ ids: [String]?)
    public func isAddedMarker(_ id: String) -> Bool

    // 一覧(lists)
    public mutating func add(_ words: [String], to list: String)
    public mutating func remove(_ words: [String], from list: String)
    public mutating func setPair(_ key: String, _ value: String, in list: String)   // 対応表(異体字・括弧)
    public mutating func removePair(_ key: String, from list: String)
    public mutating func resetList(_ list: String)
}
```

`RuleCatalog`(`rules.catalog`)は、編集画面に並べるための一覧。表示の言葉は含まない。

- `policies: [Policy]` — 方針(`id`・`choices`・`current`・`defaultChoice`・`isModified`)。規則より手前の、ふつうの設定として見せる。
- `entries: [Entry]` — 規則(`id`・`stage` = JSON の中の道筋・`canDisable`・`isEnabled`・`isModified`・`isUserAdded`・
  `parameters`)。パラメータは `Parameter.Kind`(`bool`・`int(範囲)`・`choice`・`list(種類)`・`patterns`)と今の値・既定値を持つ。
- `lists: [ListEntry]` — 語の一覧(`kind` = characters / words / pairs、今の中身・足した語・外した語)。

アプリの規則の窓は、変えるたびに `RuleChanges` を通して組み立て直し、誤りがあれば変えずに理由を出す。

## 9. 例のファイル(`ExampleFile`・`ExampleRunner`)

規則や処理を変える前に、確かめたい形を例のファイル(`qoometa.examples`、第 2 版)に足す。**例には架空の名前だけを書く**
(公開するファイル)。同梱の例は `Sources/QooMetaRules/Resources/examples.json`、CLI は `qoometa rules test`。

```json
{
  "kind": "qoometa.examples", "schemaVersion": 2,
  "examples": [{
    "id": "first-volume-inferred",
    "files": ["[架空工房] 月の庭", "[架空工房] 月の庭 2"],
    "expect": [{ "series": "月の庭", "volume": "1" }, { "series": "月の庭", "volume": "2" }],
    "covers": ["volumeHead", "firstVolume"],
    "preset": "doujinshi",
    "policies": { "unnumberedFirst": "inferFirst" },
    "settings": { "grouping.compilation.singleWhenMainExists": true }
  }]
}
```

- `expect` は `files` と同じ順・同じ数。書いた項目だけを確かめる(`series`・`volume`・`volumeSort`・`inferred`・`authors`・
  `title`・`genre`・`event`・`source`・`info`・`format`・`editionMark`・`sourceMark`)。`"series": null` は「シリーズに入ってはいけない」。
- **例が前提にしている値は、例の側に書く。** `policies`(方針 → 値)と `settings`(点つなぎの場所 → 値)は、渡された規則の上で
  その例のときだけ置き換える(`CompiledRules.applying`)。同梱の既定値は利用者の蔵書に合わせて変わるので、既定値を変えるたびに
  関係の無い例まで崩れないように。`preset` はその例の名前を読むプリセット。
- `covers` はその例が確かめる規則の ID(規則を止めたときに壊れる例が分かるように)。知らない ID は誤り。

```swift
let file = try ExampleFile.load(data).get()           // 誤りはすべて集めて RulesIssues で返す
let outcomes = ExampleRunner.run(file, rules: rules, dictionaries: SystemDictionaries.all)
for outcome in outcomes where !outcome.passed { print(outcome.id, outcome.mismatches) }
```

## 10. フィードバック

```swift
/// 利用者の直しを、例のファイルの 1 件にする。送るのは利用側と利用者で、qooMeta は送らない。
public func makeFeedbackExample(_ books: [BookInput], corrected: [String: Confirmation], rules: CompiledRules,
                                dictionaries: [String: WordSet]) -> FeedbackExample

public struct FeedbackExample: Sendable, Hashable {
    public let data: Data                         // 例のファイル(1 件)
    public let isFaithful: Bool                   // 置き換えた名前で、元と同じ結果(組と巻)になるか
    public let satisfiedByPolicy: PolicyChoice?   // 方針を 1 つ切り替えれば満たされるなら、その方針と値
}
```

名前は**すべての語を架空のものに置き換える**(実名を残さないため):

| 元の語 | 置き換え |
|---|---|
| 規則の一覧にある語(総集編・vol・第・上 …)、括弧・記号・空白、数字(漢数字を含む) | そのまま残す(規則の働きを保つため) |
| 辞書にある英単語 | 辞書にある別の同じ長さの英単語(同じ語は同じ語へ) |
| かな・カタカナ・漢字・それ以外の英字 | 同じ文字種の架空の文字へ 1 文字ずつ。「そこまでの元の並び」で決めるので、同じ語は同じ語へ、先頭が共通する語は置き換えた後も同じ長さだけ共通する(シリーズの組が保たれる) |

- 直しが方針を 1 つ切り替えれば満たされるなら、それは好みの違いであって報告する不具合ではない。利用側は、報告の前に切り替えを提案する。
- `isFaithful == false` なら、置き換えで形が変わった(そのまま送っても再現しない)。
- 利用側は、置き換えた結果を利用者に見せ、同意を得てから送る。

## 11. 書き出し(`QooMetaExport`)

**読み方は 1 つ、書き出し先ごとの違いは対応表で振り分ける。** ファイル名は同じ型の並びで qooMeta の欄に読み、どの欄を
どの欄へ渡すかだけを書き出し先ごとに決める。直した内容は作業ファイルに残るので、使うアプリを乗り換えたら出力し直せばよい。

```swift
public enum ExportTarget: String, CaseIterable, Codable {
    case qooViewer, stackNest, shelfRow
    public var format: ExportFormat          // .qooViewerJSON / .stackroomXML(StackNest と ShelfRow は同じ XML)
    public var slots: [ExportSlot]           // そのアプリの取り込みが実際に読む欄だけ
    public var takesAllAuthors: Bool         // 著者の並びを全部渡せるか(StackNest だけ)
}
public enum ExportSlot: String, CaseIterable, Codable {
    case title, author, genre, series, volume, seriesIndex, neta, keywordA, keywordB, keywordC
}

/// qooMeta の欄 → 書き出し先の欄。**書いていない欄は落ちる**。アプリの設定として持つ(作業ファイルには入れない)。
public struct FieldMapping: Sendable, Hashable, Codable {
    public enum Key: String, CaseIterable { case title, authors, genre, event, source, info, series, volume, volumeSort }
    public var target: ExportTarget
    public var slots: [Key: ExportSlot]
    public static func standard(for target: ExportTarget) -> FieldMapping    // 既定の対応(metadata.md)
    public func merging(_ changes: [Key: ExportSlot?]) -> FieldMapping      // 利用者の差分を重ねる(nil は落とす)
    public func slot(for key: Key) -> ExportSlot?
}

public enum Exporter {
    public static func preview(_ set: ProposalSet, mapping: FieldMapping) -> ExportPreview   // 落ちる欄と冊数(名前は含まない)
    public static func stackroomXML(_ set: ProposalSet, files: [String: FileFacts],
                                    mapping: FieldMapping = .standard(for: .stackNest),
                                    options: StackroomOptions = StackroomOptions()) throws -> Data
    public static func qooViewerJSON(_ set: ProposalSet, identities: [String: FileIdentity],
                                     mapping: FieldMapping = .standard(for: .qooViewer)) throws -> Data
    public static func comicInfoXML(_ proposal: BookProposal, series: SeriesProposal?) -> Data
}
```

```swift
let mapping = FieldMapping.standard(for: .shelfRow).merging([.genre: .keywordB, .volume: nil])
let preview = Exporter.preview(set, mapping: mapping)          // preview.droppedRows を画面に出す
let xml = try Exporter.stackroomXML(set, files: facts, mapping: mapping)
```

- 書き出しは `Data` を返すだけで、パスを受け取らない。XML は必ずエスケープし、XML 1.0 で書けない制御文字は落とす。
- `stackroomXML` は `files`(本の ID → `FileFacts(path:fileExtension:dateAdded:)`)に無い本を書かない。StackNest はこれを取り込んで
  **新しいライブラリを作る**。ShelfRow は同じ XML を読むが、読む欄が違う(`ExportTarget.slots`。読まない欄は行き先に出さない)。
- `qooViewerJSON` は qooViewer の保存データ(formatVersion 4 の `metadata`)。照合はファイルノード
  (`FileIdentity(path:inodeNumber:volumeDeviceNumber:volumeUUID:)`)が主で、パスは最終手段。著者は先頭だけ。
- ComicInfo は、著者を `Writer`、原作を `Tags`、ジャンルを `Genre`、情報を `Notes`、巻数(表示用)を `Number` に入れる。
- CSV と見直し表(HTML)は CLI の見直し用で、API には含めない。

## 12. 走査(`QooMetaScan`)

```swift
public enum FolderScanner {
    public static func scan(root: URL) throws -> [ScannedFile]                          // 起点そのものは本にしない
    public static func scan(items: [URL]) throws -> (root: URL, files: [ScannedFile])   // 選んだ項目の共通の親が起点
}
public struct ScannedFile: Codable, Sendable, Equatable {
    public var path, relativePath, baseName, fileExtension: String   // 画像フォルダの本は fileExtension が空
    public var size: Int64?; public var created, modified: Date?
    public var inodeNumber, volumeDeviceNumber: Int64?; public var volumeUUID: String?   // qooViewer の JSON へそのまま
    public var isFolder: Bool { get }
    public func bookInput(confirmation: Confirmation = .none) -> BookInput          // ID は相対パス。preset は付けない
}
```

何を 1 冊と数えるかは qooViewer と同じ: 書庫(zip・cbz・rar・cbr・7z・cb7)・PDF・EPUB と、画像フォルダ。読むのは名前と属性だけ。
`bookInput()` はプリセットを付けないので、割り当ては `Workfile.PresetAssignment` か自動の選択で決めて `preset` に入れる。

## 13. 端末内モデル(`QooMetaAI`、任意)

```swift
@available(macOS 26.0, *)
public struct SeriesJudge: Sendable {
    public var chunkSize = 20                          // 1 回に見せる冊数の上限
    public static var isAvailable: Bool { get }
    public static var availability: String { get }
    public func judge(series: SeriesProposal, titlesByID: [String: String]) async throws -> AIVerdict
    public static func describe(_ error: Error) -> String   // 名前を含まない短い文(エラーの説明に入力が写ることがあるため)
}
public struct AIVerdict: Codable, Sendable, Equatable {
    public var isSeries: Bool; public var seriesName: String; public var excludedIDs: [String]
    public var confidence: Confidence; public var seconds: Double
    public func confirmations(for series: SeriesProposal) -> [String: Confirmation]
}
```

モデルに任せるのは、規則で作ったシリーズ候補 1 組を見て判断することだけ(蔵書全体を渡して分類させない)。判定は
`confirmations(for:)` で確定した内容に直し、`ProposalIndex.apply` に渡すと、錨の効果で名前と組が反映される。通信はしない。

## 14. そのほかの公開面

- `SeriesDerivation` — 欄(`BookMetadata`)から直にシリーズと巻を導く入口(段階 5 の画面の骨組み用)。画面は今は `ProposalIndex` を使う。
- `Evaluator`・`LabeledBook` — 正解付きの書誌で規則を採点する(`qoometa evaluate`)。
- `WordSet` — 語の集合。1 本のバイト列に詰めて二分探索で引く(英単語の一覧を `Set<String>` で持つと 12 MB を超えたため)。
  大きな一覧は `WordSet(lines:)` で 1 行 1 語のテキストから作る。
- `JSONValue` — 規則の値(`setValue`・`applying(settings:)`・`RuleCatalog.Parameter` が使う)。

## セキュリティ

| 危険 | 対策 |
|---|---|
| 細工された名前(極端に長い、制御文字・書式文字) | 入力の上限(`InputLimits`)。超えた入力は `rejected`。Cc・Cf は読む前に落とす |
| 規則の正規表現による計算の暴走 | 照合の時間の上限(印の正規表現は 1 回 0.02 秒。越えたら印は無いものとして扱う)と、組み立てのときの危険な形の検査(`unsafePattern`) |
| 巨大な規則ファイル | 大きさの上限(`tooLarge`) |
| 規則ファイル経由のファイルの読み取り | 規則はパスを持てない。辞書は名前で指し、実体は利用側が渡す |
| 名前の流出 | 本体はログ・通信・ファイルの書き込みをしない(CI の静的検査で守る)。フィードバックは全語を置き換え、送るのは利用側と利用者 |
| 書き出しでの注入 | XML は必ずエスケープ |

## 性能

- シリーズは比べる単位の中だけで比べる。並列化は**単位をまとめた塊ごと**(1 単位は平均して数冊なので、単位ごとにタスクを作ると遅くなる)。
- 比べる形(正規化・異体字)と、語の規則が取った語は、本ごとに 1 度だけ作る。`CompiledRules` の組み立ても 1 度だけ。
- `ProposalIndex.reload` は、型の並びと巻の読み手が変わっていなければ名前を読み直さない(シリーズの規則だけを直したとき)。
- 英単語の辞書は大きい(約 24 万語)。利用側が 1 度だけ読んで渡す(`SystemDictionaries.english`)。要らない利用側は渡さなければよい。
- 測るのは `qoometa bench --synthetic 20000`(合成した名前。`--no-authors` も)。

## 利用側ごとの使い方(想定)

- **qooViewer**: 起動時に規則を組み立てる(既定値 + 利用者の変更)。「メタデータの編集」で、対象の本(登録済みの本は確定した内容付き)を
  `ProposalIndex` に入れ、提案を初期値にする。見直しは `Explanation`。
- **StackNest**: 取り込みの直前に `parseName`、取り込み後に `propose` でシリーズ・巻を補う。確定済みの欄は確定した内容として渡す。
- **ShelfRow**: `parseName` でタイトル・著者・原作を埋める(シリーズの欄は無い)。
- **qooMeta のアプリ・CLI**: `QooMetaScan` → `Workfile`(プリセットの割り当て)→ `ProposalIndex` → 見直し(`BulkEdit`)→
  `Exporter` + `FieldMapping`。

## 決まったこと

- `SeriesID` は保存しない。保存するのは確定した内容。
- 辞書と規則のデータは利用側が渡す。本体はファイルを読まない。
- 書き出し先ごとの欄の対応表(`FieldMapping`)は `QooMetaExport` に置く(読み方は 1 つ、違いは書き出しで振り分ける)。
- CSV は API に含めない。
- 安定版(1.0)にする時期と範囲は、状況を見て決める。
