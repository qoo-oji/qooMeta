# API 仕様(案)

2026-09-19。qooMeta をライブラリとして使うときの API。qooViewer からは全機能を使え、StackNest や ShelfRow のような
蔵書管理アプリに組み込んでも十分に使えることを目標にする。規則ファイルの形式は docs/rules-format-design.md。

## 前提

| 利用側 | 対応 OS | 持っているもの | 欲しいもの |
|---|---|---|---|
| qooViewer | macOS 15 | 本のパス・ファイルノード、登録済みのメタデータ(著者・タイトル・シリーズ・巻) | 「メタデータの編集」の初期値、シリーズ・巻、利用者の規則の編集 |
| StackNest | macOS 15 | 本のパス・DB の ID、Stackroom の欄(Author・Genre・Neta・Keyword A〜C・Series・Volume) | 取り込み時の補完、既存の本の一括補完 |
| ShelfRow | macOS 26.5 | 本のパス、タイトル・作者・ジャンル・関連・キーワード | 取り込み時の補完(シリーズの欄は無い) |
| qooMeta の GUI アプリ・CLI | macOS 15 | フォルダ | 一括の提案、見直し、書き出し |

- **下限は macOS 15**。本体は Foundation だけに依存する。端末内モデルは別のモジュールで macOS 26 以降。
- Swift 6(厳格な並行性)。利用側が既定でメインアクターに隔離していても(qooViewer)、そのまま呼べる。

## 設計の方針

1. **本体は純粋な計算にする。** ファイルを読まない、書かない、通信しない、ログを出さない、グローバルな状態を持たない。
   入力(名前の一覧・規則・語彙)から出力(提案)を計算するだけ。ファイルの走査・規則の読み込み・書き出しは別のモジュール。
2. **利用側の識別子を尊重する。** 本は利用側の不透明な ID(パス、DB の ID、UUID …)で指す。qooMeta は ID の中身を解釈しない。
3. **まとめて渡す。** シリーズは本どうしを見比べて決めるので、1 冊ずつではなく一覧で渡す。1 冊だけの名前の解析も別に用意する。
4. **変えた分だけ計算し直せる。** 大きな蔵書(数万冊)で 1 冊足すたびに全体を計算し直さない。比べる単位(書き手 + 本の種別)
   ごとに持ち、変わった単位だけを計算し直す。
5. **出力は決まった順で、毎回同じ。** 同じ入力と規則なら、同じ出力になる(差分の表示・キャッシュ・テストのため)。
6. **文字列を返さず、値と符号を返す。** 表示の言葉は利用側が決める(qooViewer は日本語と英語を切り替える)。
7. **利用者が確かめた値を尊重する。** 利用側がすでに確定させた値(シリーズ名・巻・シリーズから外す)を渡せ、提案はそれに従う。
8. **安定した公開面を小さく保つ。** 公開する型と関数を絞り、試しの API は `@_spi(Experimental)` に置く。パッケージは
   セマンティック バージョニングに従う(規則ファイルの形式の版とは別)。

## モジュール

| モジュール | 役割 | 依存 | 使う側 |
|---|---|---|---|
| `QooMetaKit` | 名前の解析・シリーズ・巻・版・推定。規則の組み立てと検証 | Foundation、QooFormat(内部) | すべて |
| `QooMetaRules` | 規則ファイルの読み込み(同梱の既定値・利用者の変更)、書き出し、初期化 | QooMetaKit | すべて(必要なら) |
| `QooMetaExport` | 提案を各形式へ(Stackroom XML・qooViewer JSON・ComicInfo)。結果は `Data` で返し、ファイルには書かない | QooMetaKit | GUI・CLI・必要な利用側 |
| `QooMetaScan` | フォルダの走査(書庫の拡張子で絞る)。名前と属性だけを読み、中身は開かない | QooMetaKit | GUI・CLI |
| `QooMetaAI` | 端末内モデルによる判定(任意、macOS 26) | QooMetaKit | GUI(任意) |

QooFormat(qooLibrary から写したファイル名の照合)は QooMetaKit の内部に置き、公開しない。

## 型と関数

### 規則

```swift
/// 組み立て済みの規則。組み立てに費用がかかるので、1 度作って使い回す。不変で、スレッドをまたいで共有してよい。
public struct CompiledRules: Sendable {
    /// 同梱の既定値だけ。
    public static var builtIn: CompiledRules { get }
    /// 規則ファイルの内容から組み立てる。書き間違いは RulesError、新しい版の規則は警告として返す。
    public static func compile(_ sources: [RuleSource], limits: RuleLimits = .default) throws(RulesError) -> CompiledRulesResult
    public var revision: RuleRevision { get }          // 既定値と利用者の変更の改訂
    public var ruleIDs: [RuleID] { get }               // 有効な規則の ID(GUI の一覧、トレース)
}

public struct RuleSource: Sendable {
    public static var builtIn: RuleSource { get }
    public static func data(_ data: Data, name: String) -> RuleSource   // 利用者の変更など。name はエラー表示用
}

public struct CompiledRulesResult: Sendable {
    public let rules: CompiledRules
    public let warnings: [RulesWarning]               // 新しい版の規則を飛ばした、など
}

public struct RulesError: Error, Sendable, Equatable {
    public enum Code: Sendable { case malformedJSON, unknownKey, unknownRuleType, invalidValue, unsafePattern,
                                  tooLarge, unsupportedSchemaVersion, unresolvedList, duplicateID }
    public let code: Code
    public let source: String          // RuleSource の name
    public let path: String            // JSON の位置("grouping.rules[3].minPrefx")
    public let line: Int?, column: Int?
    public let suggestion: String?     // 近い綴り("minPrefix")
}
```

### 入力

```swift
/// 本 1 冊。利用側の不透明な ID と、名前だけを持つ。パスは要らない(あれば文脈として使う)。
public struct BookInput: Sendable, Hashable {
    public var id: String                    // 利用側の ID。qooMeta は解釈しない
    public var name: String                  // 拡張子を除いたファイル名(またはフォルダ名)
    public var folders: [String]             // 入っているフォルダ名(近い順、任意)。書き手が名前に無いときの手がかり
    public var fileExtension: String?        // 任意(書き出しで使う)
    public var confirmed: ConfirmedMetadata? // 利用者が確定させた値(任意)
}

/// 利用者が確定させた値。提案はこれに従う(上書きしない)。
public struct ConfirmedMetadata: Sendable, Hashable {
    public var circle: String?
    public var title: String?
    public var series: String?               // 確定したシリーズ名。同じ名前の本は同じシリーズとして扱う
    public var volume: String?
    public var notInSeries: Bool             // 「シリーズではない」と確定した
}

/// 利用者ごとの語彙(本の種別の名前など)。蔵書の語なので、利用側の設定に置く。
public struct Vocabulary: Sendable, Hashable {
    public var genres: [String]              // ファイル名の先頭の括弧のうち、本の種別とみなす語
}
```

### 1 冊の解析(軽い)

```swift
/// ファイル名を欄に分ける(シリーズは見ない)。取り込みの瞬間に 1 冊ずつ補完したい利用側向け。
public func parseName(_ name: String, rules: CompiledRules, vocabulary: Vocabulary) -> ParsedName

public struct ParsedName: Sendable, Hashable {
    public var genre: String?, event: String?, circle: String?, authors: [String]
    public var title: String, relation: String?, keyword: String?
    public var editions: [String], sources: [String]
    public var format: FormatMatch                 // 一致したフォーマット(.format(profile:index:) / .fallback)
    public var standaloneVolume: Volume?           // 1 冊だけで読める巻(「X 第3巻」)。シリーズ名は推定しない
}
```

### まとめて提案する

```swift
/// 一覧をまとめて提案する。CPU を使う同期の計算なので、メインスレッドの外で呼ぶ。
public func propose(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                    options: ProposalOptions = .default) -> ProposalSet

/// 同じもの。取り消し(Task のキャンセル)と進み具合の通知に対応する。
@concurrent
public func propose(_ books: [BookInput], rules: CompiledRules, vocabulary: Vocabulary,
                    options: ProposalOptions = .default,
                    progress: (@Sendable (ProposalProgress) -> Void)? = nil) async throws(CancellationError) -> ProposalSet

public struct ProposalOptions: Sendable {
    public var trace: Bool = false                 // どの規則が効いたかを記録する(GUI の見直し、不具合の調査)
    public var limits: InputLimits = .default
}

public struct ProposalSet: Sendable {
    public let proposals: [BookProposal]           // 入力と同じ順
    public let series: [SeriesProposal]            // 決まった順(書き手 → 名前 → ID)
    public let rulesRevision: RuleRevision
    public let rejected: [InputIssue]              // 大きすぎる名前など、扱わなかった入力
    public subscript(id: String) -> BookProposal? { get }
}

public struct BookProposal: Sendable, Hashable {
    public let id: String
    public let parsed: ParsedName
    public let seriesID: SeriesID?                 // SeriesProposal を指す
    public let volume: Volume?
    public let flags: Set<Flag>                    // .inferredVolume, .edition, .compilation, .confirmedByUser …
    public let trace: [RuleID]                     // options.trace のときだけ
}

public struct SeriesProposal: Sendable, Hashable, Identifiable {
    public let id: SeriesID                        // 入力が同じなら同じ ID(書き手 + 本の種別 + 名前から作る)
    public let name: String
    public let kind: Kind                          // .series / .compilation / .magazineYear
    public let memberIDs: [String]                 // 巻の順
    public let evidence: Evidence                  // .volumeHead / .sharedPrefix(cleanCut:) / .confirmed …
}

public struct Volume: Sendable, Hashable {
    public let text: String                        // 表記(「36-37」「上」「後編1」)
    public let sortKey: Double?                    // 並べ替え用(36、1、3.1)
    public let inferred: Bool
}
```

### 変えた分だけ計算し直す

```swift
/// 蔵書の今の状態を持ち、変わった分だけ計算し直す。値型ではなく、利用側が 1 つ持つ(アクター)。
public actor ProposalIndex {
    public init(rules: CompiledRules, vocabulary: Vocabulary, options: ProposalOptions = .default)
    /// 足す・変える・消す。影響のある単位(書き手 + 本の種別)だけを計算し直し、変わった提案を返す。
    public func apply(_ changes: [BookChange]) throws(CancellationError) -> ProposalDelta
    public func proposal(for id: String) -> BookProposal?
    public func snapshot() -> ProposalSet
    /// 規則や語彙を変えたとき(全体の計算し直し)。
    public func update(rules: CompiledRules, vocabulary: Vocabulary) throws(CancellationError) -> ProposalDelta
}

public enum BookChange: Sendable { case upsert(BookInput), remove(id: String) }

public struct ProposalDelta: Sendable {
    public let changed: [BookProposal]             // 提案が変わった本
    public let removedSeries: [SeriesID], changedSeries: [SeriesProposal]
}
```

### 書き出し(`QooMetaExport`)

```swift
/// 書き出し先の欄への対応。利用側の欄に合わせて選ぶ(ShelfRow のようにシリーズの欄が無い場合など)。
public struct FieldMapping: Sendable {
    public static var stackroom: FieldMapping { get }     // Author・Genre・Neta・Series・Volume・Keyword C(版)
    public static var qooViewer: FieldMapping { get }     // author(サークル)・title・series・seriesIndex
    public static var comicInfo: FieldMapping { get }
    public static func shelfRow(seriesInto: ShelfRowField) -> FieldMapping   // .title / .relation / .keywordA …
}

public enum Exporter {
    public static func stackroomXML(_ set: ProposalSet, books: [BookInput], files: [String: FileFacts]) throws -> Data
    public static func qooViewerJSON(_ set: ProposalSet, identities: [String: FileIdentity]) throws -> Data
    public static func fields(_ proposal: BookProposal, mapping: FieldMapping) -> [String: FieldValue]  // 利用側の DB へ直接
}
```

`fields(_:mapping:)` は、利用側が自分の DB に直接書くための値を返す(StackNest・ShelfRow の取り込みで使う想定)。

### 規則の管理(`QooMetaRules`)

```swift
/// 利用者の変更(既定値との差分)を扱う。保存先は利用側が決める(アプリごとに分ける)。
public struct RuleOverrides: Sendable, Codable {
    public static func load(from data: Data) throws(RulesError) -> RuleOverrides
    public func encoded() throws -> Data
    public mutating func setEnabled(_ enabled: Bool, rule: RuleID)
    public mutating func setValue(_ value: RuleValue, rule: RuleID, key: String)
    public mutating func add(_ words: [String], toList: String)
    public mutating func remove(_ words: [String], fromList: String)
    public static var empty: RuleOverrides { get }       // 初期化
}

/// 例のファイル(架空の名前で書いた見本)で確かめる。
public func checkExamples(_ examples: Data, rules: CompiledRules, vocabulary: Vocabulary) throws -> ExampleReport
```

### フィードバック

```swift
/// 利用者が直した結果を、例のファイルの 1 件にする。名前は**形を保ったまま架空の語に置き換える**(文字種・長さ・記号・数字は残す)。
/// 置き換えた結果は利用側が利用者に見せ、同意を得てから送る。qooMeta は送らない。
public func makeFeedbackExample(_ books: [BookInput], corrected: [String: ConfirmedMetadata]) -> FeedbackExample
```

## セキュリティ

| 危険 | 対策 |
|---|---|
| 名前・規則に細工された文字列(極端に長い、制御文字、大量の括弧) | 入力の上限(`InputLimits`: 名前 1 件の長さ、冊数、フォルダの深さ)。超えた入力は `rejected` に入れて扱わない。制御文字は比べる前に落とす |
| 規則の正規表現による計算の暴走(ReDoS) | 規則の正規表現は組み立てのときに検査し、危険な形(入れ子の繰り返し・後方参照・先読み)は `unsafePattern` で拒む。照合には時間の上限を付ける(QooFormat の `SafeRegex` と同じ仕組み) |
| 巨大な規則ファイル | 大きさ・規則の数・一覧の語数に上限(`RuleLimits`) |
| 名前の流出 | 本体はログを出さない・通信しない・ファイルに書かない。トレースは利用側へ返すだけ。フィードバックは架空の名前に置き換え、送るかどうかは利用側と利用者が決める |
| 書き出しでの注入 | XML・HTML は必ずエスケープする |
| ファイルの上書き | 書き出しは `Data` を返すだけで、書き先は利用側が決める(パスを受け取らない) |
| 規則の読み込み場所 | 本体は規則を `Data` で受け取る。ファイルを読むのは `QooMetaRules` の読み込み口だけで、利用側が渡した URL だけを読む |

## 性能

- 名前の解析: 1 冊ずつ独立。フォーマットの照合は QooFormat(探索の上限あり)。
- シリーズ: 比べる単位(書き手 + 本の種別)の中だけで比べる。単位の中は並べ替え(O(n log n))と隣どうしの比較。
  単位をまたぐ計算は「ありふれた言葉の疑い」の数え上げだけで、索引を作って O(n) にする。
- 単位ごとに独立なので並列にできる(`propose` の async 版は単位ごとに並列で計算する)。
- 比べるための形(正規化・異体字)は本ごとに 1 度だけ作って使い回す。
- `CompiledRules` の組み立て(正規表現・一覧の索引)は 1 度だけ。
- 英単語の辞書は遅延で 1 度だけ読み、全体で共有する(利用側が別の一覧を渡すこともできる)。
- 目安(実測して書く): 1 万冊の一括で数秒以内、1 冊の追加で数ミリ秒以内。測定は CLI の `bench` で行い、CI で悪化を見張る。

## 利用側ごとの使い方(想定)

- **qooViewer**: 起動時に `CompiledRules` を組み立てる(既定値 + 利用者の変更)。「メタデータの編集」を開くとき、対象の本
  (登録済みの本は `confirmed` 付き)を `ProposalIndex` に入れ、提案を初期値にする。本が増減したら `apply` で差分だけ。
  保存は `FieldMapping.qooViewer`。
- **StackNest**: 取り込みの直前に `parseName` で欄を埋め、取り込み後にライブラリ全体で `propose`(または `ProposalIndex`)
  を回してシリーズ・巻を補う。確定済みの欄は `confirmed` で渡す。書き込みは `fields(_:mapping: .stackroom)`。
- **ShelfRow**: `parseName` でタイトル・作者・ジャンル・関連を埋める。シリーズは `FieldMapping.shelfRow(seriesInto:)` で
  利用者が選んだ欄へ。
- **GUI アプリ・CLI**: `QooMetaScan` で走査 → `propose` → 見直し → `QooMetaExport`。

CSV の書き出しは API に含めない。利用側はどれも `fields(_:mapping:)` や Stackroom XML で足り、見直しは GUI アプリの画面で行う。
CLI の `series-list`(開発中の見直し用)にだけ残す(利用者の判断)。

## 決まったこと(2026-09-19)

- モジュールの名前はこの案のとおり。安定版(1.0)とする時期と範囲は、状況を見て決める。
- `ProposalIndex`(変わった分だけ計算し直す)は最初から用意する。
- フィードバックの例を作る関数は本体(`QooMetaKit`)に置く。
- CSV の書き出しは API に含めない(CLI の見直し用にだけ残す)。
