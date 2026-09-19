# API 仕様(案)

2026-09-19(同日のレビューを反映)。qooMeta をライブラリとして使うときの API。qooViewer からは全機能を使え、StackNest や
ShelfRow のような蔵書管理アプリに組み込んでも十分に使えることを目標にする。規則ファイルの形式は rules-format-design.md。

## 前提

| 利用側 | 対応 OS | 持っているもの | 欲しいもの |
|---|---|---|---|
| qooViewer | macOS 15 | 本のパス・ファイルノード、登録済みのメタデータ(著者・タイトル・シリーズ・巻) | 「メタデータの編集」の初期値、シリーズ・巻、規則の編集、なぜそうなったかの説明 |
| StackNest | macOS 15 | 本のパス・DB の ID、Stackroom の欄 | 取り込み時の補完、既存の本の一括補完 |
| ShelfRow | macOS 26.5 | 本のパス、タイトル・作者・ジャンル・関連・キーワード | 取り込み時の補完(シリーズの欄は無い) |
| qooMeta の GUI アプリ・CLI | macOS 15 | フォルダ | 一括の提案、見直し、書き出し |

- **下限は macOS 15**。本体は Foundation だけに依存する。端末内モデルは別のモジュールで macOS 26 以降。
- **Swift 6.2 以降(Xcode 26 以降)**が要る(`@concurrent` を使う)。厳格な並行性。利用側が既定でメインアクターに隔離していても呼べる。

## 方針

1. **本体は純粋な計算にする。** ファイルを読まない・書かない、通信しない、ログを出さない、グローバルな状態を持たない。
   外の資源(規則のデータ、辞書)はすべて利用側が値で渡す。
2. **利用側の識別子を尊重する。** 本は利用側の不透明な ID(文字列)で指す。qooMeta は中身を解釈しない。
3. **まとめて渡す。** シリーズは本どうしを見比べて決める。1 冊だけの名前の解析は別に用意する。
4. **変えた分だけ計算し直せる。** 比べる単位(書き手 + 本の種別)ごとに持ち、変わった単位だけを計算し直す。
   そのために、**提案は単位の中だけで決まる**ようにする(単位をまたぐ情報は提案に含めない)。
5. **出力は決まった順で、毎回同じ。** 同じ入力(本・規則・語彙・辞書)なら同じ出力。
6. **文字列ではなく値と符号を返す。** 表示の言葉は利用側が決める。
7. **利用者が確定させた値に従う。**
8. **公開面を小さく保つ。** 第三者のアプリの欄に合わせる処理のような、相手の都合で壊れるものは本体に入れない。
   試しの API は `@_spi(Experimental)`。パッケージは SemVer に従う(安定版にする時期は状況を見て決める)。

## モジュール

| モジュール | 役割 | 依存 |
|---|---|---|
| `QooMetaKit` | 名前の解析・シリーズ・巻・版・推定、規則の組み立てと検証、規則のカタログ、説明、`ProposalIndex`、フィードバックの例づくり | Foundation、QooFormat(内部) |
| `QooMetaRules` | 同梱の既定値のデータ、利用者の変更(差分)の編集、`rules-bundle`、例の確認、システムの英単語辞書の読み込み口 | QooMetaKit |
| `QooMetaExport` | Stackroom XML・qooViewer JSON・ComicInfo。`Data` を返し、ファイルには書かない | QooMetaKit |
| `QooMetaScan` | フォルダの走査(名前と属性だけ) | QooMetaKit |
| `QooMetaAI` | 端末内モデル(任意、macOS 26) | QooMetaKit |

QooFormat(qooLibrary から写したファイル名の照合)は QooMetaKit の内部に置き、公開しない。

## 型と関数

### 規則

```swift
/// 組み立て済みの規則。1 度作って使い回す。不変で、スレッドをまたいで共有してよい。
public struct CompiledRules: Sendable {
    /// 規則のデータから組み立てる。誤りは**すべて**集めて返す(1 件でもあれば rules は nil)。
    public static func compile(_ sources: RuleSources, limits: RuleLimits = .default) -> RulesCompilation
    public var contentHash: String { get }             // キャッシュの判定用(内容から計算する)
    public var catalog: RuleCatalog { get }            // 規則の編集画面用
    public static var engineLevel: Int { get }
}

public struct RuleSources: Sendable {
    public var builtIn: BuiltInRules                   // QooMetaRules.builtIn(同梱の既定値のデータ)
    public var userChanges: Data?                      // 利用者の変更(差分、または rules-bundle)
}

public struct RulesCompilation: Sendable {
    public let rules: CompiledRules?
    public let errors: [RulesIssue]                    // 書き間違いなど(位置・行・列・近い綴りの候補)
    public let warnings: [RulesIssue]                  // 新しい版の規則を飛ばした、廃止された ID への参照、辞書が無い、など
}

public struct RulesIssue: Sendable, Hashable {
    public enum Code: Sendable { case malformedJSON, unknownKey, unknownRuleType, invalidValue, unsafePattern, tooLarge,
                                  unsupportedSchemaVersion, unresolvedList, newerRuleSkipped, requiredRuleUnknown,
                                  retiredID, missingDictionary }
    public let code: Code
    public let source: String                          // "builtin" / "user"
    public let path: String                            // "grouping.sharedPrefix.minPrefx"
    public let line: Int?, column: Int?
    public let suggestion: String?                     // "minPrefix"
}

/// 規則の一覧(種類・パラメータの型と範囲・今の値・既定値・利用者が変えたかどうか)。表示の言葉は含まない。
public struct RuleCatalog: Sendable {
    public struct Entry: Sendable, Identifiable {
        public let id: RuleID, stage: Stage
        public let isEnabled: Bool, isModified: Bool
        public let parameters: [Parameter]             // 名前・型(数/真偽/一覧の参照)・範囲・今の値・既定値
    }
    public let entries: [Entry]
    public let lists: [ListEntry]                      // 一覧の名前・今の語・利用者が足した語・外した語
}
```

### 入力

```swift
public struct BookInput: Sendable, Hashable {
    public var id: String                    // 利用側の ID
    public var name: String                  // 拡張子を除いたファイル名(またはフォルダ名)
    public var folders: [String]             // 入っているフォルダ名(近い順、任意)
    public var confirmation: Confirmation    // 既定は .none
}

/// 利用者が確定させた内容。
public enum Confirmation: Sendable, Hashable {
    case none
    /// 欄の値を確定した(nil の欄は未確定)。シリーズについては何も言っていない。
    case fields(ConfirmedFields)
    /// このシリーズの本だと確定した。volume が nil なら巻は未確定。
    case series(name: String, volume: String?, fields: ConfirmedFields = .init())
    /// シリーズの本ではないと確定した。
    case notInSeries(fields: ConfirmedFields = .init())
}

public struct ConfirmedFields: Sendable, Hashable {
    public var circle: String?, title: String?, relation: String?, genre: String?
}

/// 利用者ごとの語彙と辞書。蔵書の語を含むので、利用側の設定に置く。
public struct Vocabulary: Sendable, Hashable {
    public var genres: [String]                          // 先頭の括弧のうち、本の種別とみなす語
    public var dictionaries: [String: WordSet]           // 規則が名前で指す辞書("english" など)
}
```

#### 確定した値の効き方

- 確定した欄(`ConfirmedFields`)は、名前の解析の結果より優先する(比べる単位も確定した値で決まる)。
- `.series(name:)` の本は**錨**になる。同じ単位で、規則が同じ組にした未確定の本は、**確定した名前**のシリーズに入る
  (利用者が規則より短い名前を付けた場合、その名前が組全体に及ぶ)。
- 1 つの組に確定した名前が 2 種類以上あれば、組を確定した名前ごとに割る。未確定の本は、タイトルの先頭がいちばん長く一致する名前へ入れる。
- 同じ単位で同じ名前に確定した本は、規則が別の組にしていても同じシリーズにする。
- `.notInSeries` の本はどのシリーズにも入れない。残りが 2 冊に満たなければ、その組はシリーズにしない。
- 確定した巻はそのまま使う。推定(1 巻とみなす)は、確定した巻を読めた巻として扱う。
- **qooViewer の注意**: qooViewer の DB では「シリーズが空」は未入力の意味で、「シリーズではない」と区別できない。
  シリーズが空の登録は `.fields` として渡す。

### 辞書(`QooMetaRules`)

```swift
/// 語の集合(比べる形にそろえて持つ)。
public struct WordSet: Sendable, Hashable { public init(_ words: some Sequence<String>) }

public enum SystemDictionaries {
    /// macOS の /usr/share/dict/words を読む(無ければ nil)。読むのはこのモジュールで、本体ではない。
    public static func english() -> WordSet?
}
```

規則は辞書を名前(`"english"`)で指すだけで、パスを持たない。渡されなかった辞書を使う条件は働かず、警告になる。

### 1 冊の解析

```swift
/// ファイル名を欄に分ける(シリーズは見ない)。取り込みの瞬間に 1 冊ずつ補完したい利用側向け。
public func parseName(_ name: String, rules: CompiledRules, vocabulary: Vocabulary) -> ParsedName

public struct ParsedName: Sendable, Hashable {
    public var genre: String?, event: String?, circle: String?, authors: [String]
    public var title: String, relation: String?, keyword: String?
    public var editions: [String], sources: [String]
    public var format: FormatMatch                 // .format(profile:index:) / .fallback(id)
    public var standaloneVolume: Volume?           // 1 冊だけで読める巻(「X 第3巻」)。シリーズ名は推定しない
}
```

### まとめて提案する

```swift
/// 一覧をまとめて提案する。CPU を使う同期の計算。メインスレッドの外で呼ぶ。
public func proposeSync(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                        options: ProposalOptions = .default) -> ProposalSet

/// 同じ計算を、呼び出し側のアクターの外で行う。Task の取り消しと、進み具合の通知に対応する。
@concurrent
public func propose(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                    options: ProposalOptions = .default,
                    progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError) -> ProposalSet

public struct ProposalOptions: Sendable {
    public var explanations: Bool = false          // 説明(下の Explanation)を作る。費用がかかるので既定は無し
    public var limits: InputLimits = .default
}

public struct ProposalSet: Sendable {
    public let proposals: [BookProposal]           // 入力と同じ順
    public let series: [SeriesProposal]            // 決まった順(書き手 → 名前 → 最小の本の ID)
    public let rulesHash: String
    public let rejected: [InputIssue]              // 上限を超えた名前など、扱わなかった入力
    public subscript(id: String) -> BookProposal? { get }
}

public struct BookProposal: Sendable, Hashable {
    public let id: String
    public let parsed: ParsedName
    public let seriesID: SeriesID?
    public let volume: Volume?
    public let flags: Set<Flag>                    // .inferredVolume, .edition, .compilation, .confirmed …
}

public struct SeriesProposal: Sendable, Hashable, Identifiable {
    public let id: SeriesID
    public let name: String
    public let kind: Kind                          // .series / .compilation / .magazineYear
    public let memberIDs: [String]                 // 巻の順
    public let evidence: Evidence                  // .volumeHead / .sharedPrefix(cleanCut:) / .confirmed
}

public struct Volume: Sendable, Hashable {
    public let text: String                        // 表記(「36-37」「上」「後編1」)
    public let sortKey: Double?                    // 並べ替え用(36、1、3.1)
    public let inferred: Bool
}
```

#### `SeriesID` の約束

- `SeriesID` は**その `ProposalSet`(または `ProposalIndex` の今の状態)の中でだけ意味を持つ**。本を足すとシリーズ名が変わりうるので、
  ID も変わりうる。利用側は `SeriesID` を保存しない。**保存するのは確定した内容(`Confirmation`)**。
- 同じ書き手・本の種別・名前の組が複数できることがある(ネタで割れた組)。ID は、組の中の最小の本の ID を含めて作り、重ならないようにする。
- 同じ入力なら同じ ID になる(方針 5)。

### 説明

```swift
/// なぜその提案になったか。options.explanations のときだけ作る。表示の言葉は含まない(符号と規則の ID)。
public struct Explanation: Sendable, Hashable {
    public let appliedRules: [RuleID]                       // 効いた規則
    public let nearMisses: [NearMiss]                       // 組になりかけて、ならなかった相手
}
public struct NearMiss: Sendable, Hashable {
    public let otherID: String
    public let sharedPrefixLength: Int
    public let rejectedBy: RuleID                           // "reject-single-script"、"splitByRelation"、"rejectSameWork" …
}
extension ProposalSet { public func explanation(for id: String) -> Explanation? }
```

「なぜこの 2 冊がシリーズにならないのか」に答えるためのもの(規則を育てる作業の中心になる問い)。

### 変えた分だけ計算し直す

```swift
public actor ProposalIndex {
    public init(rules: CompiledRules, vocabulary: Vocabulary, options: ProposalOptions = .default)
    /// 足す・変える・消す。影響のある単位だけを計算し直し、変わった提案を返す。
    /// **全か無か**: 取り消されたら状態は呼ぶ前のまま。
    public func apply(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta
    public func proposal(for id: String) -> BookProposal?
    public func snapshot() -> ProposalSet
    public func update(rules: CompiledRules, vocabulary: Vocabulary) throws(CancellationError) -> ProposalDelta
}

public enum BookChange: Sendable { case upsert(BookInput), remove(id: String) }

public struct ProposalDelta: Sendable {
    public let changed: [BookProposal]
    public let removedSeries: [SeriesID], changedSeries: [SeriesProposal]
}
```

- `apply` の結果は、同じ本の一覧を `proposeSync` に渡した結果と**常に同じ**(テストで確かめる)。
- 今の実装にある「同じ前半部分を持つ書き手の数」(ありふれた言葉の疑い)は単位をまたぐので、提案には含めない。
  必要なら `ProposalSet` に対する別の問い合わせ(`prefixCommonness(of:)`)として、その時点の全体から計算する。

### 規則の変更と例(`QooMetaRules`)

```swift
/// 利用者の変更(既定値との差分)。保存先は利用側が決める。
public struct RuleChanges: Sendable {
    public static var none: RuleChanges { get }                           // 初期化
    public init(data: Data) throws(RulesIssue)
    public func data() -> Data                                            // 保存・持ち運び用(rules-bundle)
    public mutating func setEnabled(_ enabled: Bool, rule: RuleID)
    public mutating func setValue(_ value: RuleValue, rule: RuleID, parameter: String)
    public mutating func add(_ words: [String], to list: String)
    public mutating func remove(_ words: [String], from list: String)
    public mutating func reset(rule: RuleID)                              // その規則だけ既定値に戻す
}

public func checkExamples(_ examples: Data, rules: CompiledRules, vocabulary: Vocabulary) -> ExampleReport
```

### フィードバック

```swift
/// 利用者が直した結果を、例のファイルの 1 件にする。送るのは利用側と利用者で、qooMeta は送らない。
public func makeFeedbackExample(_ books: [BookInput], corrected: [String: Confirmation],
                                rules: CompiledRules, vocabulary: Vocabulary) -> FeedbackExample
```

置き換えの規則(実名を残さないため、**すべての語を置き換える**):

| 元の語 | 置き換え |
|---|---|
| 規則の一覧にある語(総集編・vol・第・上・フルカラー版 …)、括弧・記号・空白、数字 | そのまま残す(規則の働きを保つため) |
| 本の種別の語 | `種別A`・`種別B` …(例の `vocabulary` にも同じ語を書く) |
| 辞書にある英単語 | 辞書にある別の英単語(同じ語は同じ語へ) |
| それ以外の英字の語 | 辞書に無い作り語(同じ長さ) |
| かな・カタカナ・漢字の語 | 同じ文字種・同じ長さの架空の語(同じ語は同じ語へ。先頭が共通する語は、置き換えた後も同じ長さだけ共通させる) |

- 置き換えた例で、元と同じ結果(組と巻)になることを確かめてから返す。ならなければ `FeedbackExample.isFaithful == false`。
- 利用側は、置き換えた結果を利用者に見せ、同意を得てから送る。

### 書き出し(`QooMetaExport`)

```swift
public enum Exporter {
    public static func stackroomXML(_ set: ProposalSet, files: [String: FileFacts]) throws -> Data
    public static func qooViewerJSON(_ set: ProposalSet, identities: [String: FileIdentity]) throws -> Data
    public static func comicInfoXML(_ proposal: BookProposal, series: SeriesProposal?) -> Data
}
```

- 書き出しは `Data` を返すだけ(パスを受け取らない)。XML は必ずエスケープする。
- 利用側が自分の DB に書くときは、`BookProposal` と `SeriesProposal` をそのまま使う(欄への対応は利用側が持つ)。
  **第三者のアプリの欄に合わせる対応表(ShelfRow のどの欄へ入れるか、など)は本体に入れず、GUI アプリに置く**(相手の変更で壊れるため)。
- CSV の書き出しは API に含めない(CLI の見直し用にだけ残す)。

## セキュリティ

| 危険 | 対策 |
|---|---|
| 細工された名前(極端に長い、大量の括弧、制御文字・書式文字) | 入力の上限(`InputLimits`)。超えた入力は `rejected`。制御文字と書式文字(Cc・Cf)は比べる前に落とす |
| 規則の正規表現による計算の暴走 | 本当の守りは**照合の時間の上限**(QooFormat の `SafeRegex` と同じ仕組み)。組み立てのときの危険な形の検査(`unsafePattern`)は補助 |
| 巨大な規則ファイル | 大きさ・規則の数・語数の上限(`RuleLimits`) |
| 規則ファイル経由のファイルの読み取り | 規則はパスを持てない。辞書は名前で指し、実体は利用側が渡す |
| 名前の流出 | 本体はログ・通信・ファイルの書き込みをしない(CI の静的検査で守る)。フィードバックは全語を置き換え、送るのは利用側と利用者 |
| 書き出しでの注入 | XML は必ずエスケープ |

## 性能

- シリーズは比べる単位の中だけで比べる。単位の中は並べ替え(O(n log n))と隣どうしの比較。
- 並列化は**単位をまとめた塊ごと**に行う(1 単位は平均して数冊なので、単位ごとにタスクを作ると遅くなる)。
- 比べるための形(正規化・異体字)は本ごとに 1 度だけ作る。`CompiledRules` の組み立ては 1 度だけ。
- 英単語の辞書は大きい(約 24 万語)。利用側が 1 度だけ読んで渡す。要らない利用側は渡さなければよい。
- 目安(実測して書く): 1 万冊の一括で数秒以内、1 冊の追加で数ミリ秒以内。`qoometa bench` で測る。

## 利用側ごとの使い方(想定)

- **qooViewer**: 起動時に規則を組み立てる(既定値 + 利用者の変更)。「メタデータの編集」で、対象の本(登録済みの本は確定した内容付き)を
  `ProposalIndex` に入れ、提案を初期値にする。規則の編集は `RuleCatalog` と `RuleChanges`、見直しは `Explanation`。
- **StackNest**: 取り込みの直前に `parseName`、取り込み後に `propose` でシリーズ・巻を補う。確定済みの欄は確定した内容として渡す。
- **ShelfRow**: `parseName` でタイトル・作者・ジャンル・関連を埋める。
- **GUI アプリ・CLI**: `QooMetaScan` → `propose` → 見直し → `QooMetaExport`。

## 決まったこと(2026-09-19)

- モジュールの名前はこの案のとおり。安定版(1.0)にする時期と範囲は、状況を見て決める。
- `ProposalIndex` は最初から用意する。フィードバックの例を作る関数は本体に置く。CSV は API に含めない。
- `SeriesID` は保存しない。保存するのは確定した内容。
- 辞書と規則のデータは利用側が渡す。本体はファイルを読まない。
