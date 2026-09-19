# 引き継ぎ

2026-09-19 時点。次にこのリポジトリで作業する人(AI エージェントを含む)向け。

## いまの状況

- コンセプトを土台から見直し、利用者と合意した。**シリーズと巻を導く中核は移し、ほかは作り直す。**
- 作り直しはまだ始めていない。計画は同じ日にコードと突き合わせて見直した。次にやるのは [roadmap.md](roadmap.md) の段階 0(片付け)と
  段階 1(基準を取る)。roadmap.md の未決は、2026-09-19 にすべて決まった。
- 見直した docs と `CLAUDE.md` はコミットした。試作(下の「作業ツリー」)は未コミットのまま残っていて、捨てると決まっている。

## 読む順

| 文書 | 状態 | 中身 |
|---|---|---|
| [concept.md](concept.md) | **最新** | 目的、**ターゲットのアプリと参考のアプリの区別**、原則(9 項目)。まずこれ |
| [metadata.md](metadata.md) | **最新** | 利用先 3 アプリの調査、qooMeta の欄、書き出し先ごとのシリーズと巻、画面の案 |
| [filename-format.md](filename-format.md) | **最新** | ファイル名フォーマットの書き方・予約語・同梱プリセット |
| [roadmap.md](roadmap.md) | **最新** | 中核の入口、作り直しの段階(0〜12)と終わりの条件、未決 |
| [rules.md](rules.md)・[rules-format-design.md](rules-format-design.md) | 規則ファイルの形式(第 2 版)は有効 | 版・入手経路・本の種別などの方針は古い欄が前提 |
| [api.md](api.md)・[design.md](design.md) | **古い** | サークル・ネタなど旧来の欄が前提。作り直しで書き直す |
| `CLAUDE.md` | **最新**(2026-09-19 に冒頭を直した) | 目的、ターゲットと参考の区別、名前を外へ出さない約束 |

## 決まったこと(2026-09-19)

- **欄**: タイトル、著者(並び)、ジャンル(並び)、関連(並び)、キーワード A・B・C(それぞれ並び)、種類、メモ、シリーズ、
  巻(表記と数)。3 アプリが管理に使う欄の和集合。
- **予約語**: `@title @author @genre @source @keywordA @keywordB @keywordC @type @ignore`。
  - `@author` と `@ignore` は何度でも書ける。並びの欄は区切りで分ける。既定の区切りは括弧・`,`・`、` だけ(`×` `&` `・` は名義の中にも
    現れ、取り違えると著者の先頭が壊れるので入れない。設定で足せる)。
  - `@source` は StackNest・ShelfRow の `@relation`(二次創作の元作品)。取り込みで読み替え、書き出しで戻す。`@original`(同人誌で
    「オリジナル」と書かれる値と紛れる)と `@parody`(日本では印象が違う)は採らない。
  - `@series` `@volume` は持たない(中核の規則で導く)。`@memo` も持たない(キーワードで足りる)。`@genre` に語の一覧は持たない
    (ほかの欄と同じ自由な文字列。先頭の丸括弧をどの欄にするかは利用者がフォーマットで選ぶ)。
- **プリセット**: 同梱するのは、混ざった蔵書をそのまま読む型の並び 1 つ(本の種類ごとの組には分けない)。出発点はターゲットの既定
  (qooViewer の 12 通り)で、`@ignore` の位置へ欄を割り当てる(先頭の丸括弧 = `@genre`、角括弧の中の丸括弧 = `@author`、末尾の丸括弧 =
  `@source`、末尾の角括弧 = `@ignore`)。qooLibrary のプリセットは参考として 1 項目ずつ吟味した(filename-format.md の 5)。同梱するかは
  一致冊数ではなく「取り違えたときに何が壊れるか」で決める(タイトル・著者が壊れる型は入れない): 末尾が角括弧だけの形は入れ(16 通り)、
  `@title - @author`・`@title [@author]`・`@title` は入れない。`「」` `【】` ` - ` を特別扱いしない。
- **フォルダ名は読まない**(フォルダ名の型は qooLibrary 固有。3 アプリはどれも読まない)。
- **ライブラリは無い**。設定はアプリの設定として 1 組。
- **画面**: 上に値の列(値ごとの冊数と「(空)」の行つき)、中に 1 冊 1 行の一覧(絞り込みは「シリーズに入らなかった本」だけ)、
  右に詳細(複数選択でまとめて直す、提案 / 直した値、ファイル名のどこがどの欄か)。スタンプ・取り消し・適用前のプレビュー・
  型の編集の窓・書き出しのプレビュー。利用者の返事は「ひとまずそれでよい。ダメならまたダメと言う」。
- **作り直しの方針**: 中核は移す(A)。詳しくは roadmap.md。
- **ジャンルと比べる単位**: 単位は今と同じ「書き手 + ジャンル」で、ジャンルが違えば分ける。`@genre` にイベント名などが入って
  シリーズが割れるのは、仕組みで防がない(利用者が画面で気づく)。アプリは、全選択を含む複数選択 + 1 回の入力で、選んだ全冊の
  任意の欄を書き換える手段を用意する。ジャンルを見ないことも利用者が設定で選べる(今の方針 `differentGenre` の `split` / `keep`。既定は `split`)。
- **書き手が空の本・合わなかった名前**: 特別扱いせず中核へ渡す(合わなかった名前は、名前全体を仮のタイトルに)。書き手が空の本は
  1 つの単位。**道具の側で偏りをかけない**: 取り違えや偶然の組は、仕組みで先回りして防ぐのではなく、一覧(並べ替え・値の列)で
  見えるようにして、利用者が直す。ジャンル・関連の取り違えと同じ考え方。
- **画面は早く見せる**: 架空のデータで骨組みを先に作り、利用者がよいと言ってから残りを積む(roadmap.md の段階 5)。

## ターゲットと参考(2026-09-19 決定)

- **ターゲットは qooViewer・StackNest・ShelfRow だけ**(その欄・フォーマットの書き方・受け渡しの形式が要件)。**qooLibrary は参考で、
  ターゲットではない。** 区別は concept.md の表。根拠に参考のアプリを挙げない。コード・語・構造を持ってこない。
- いまのコードには、qooLibrary に引っ張られた部分が残っている: 中核のコードの語(`mediaType` `Vocabulary` …)、`filename-formats.json` の形(`profiles` `protectedTokens`)。
  作り直しの中で qooMeta の語と形に直す。参考は無視するのではなく、そのまま使わずに吟味して、要る知識だけを取り入れる
  (利用者の指示。プリセットの吟味は filename-format.md の 5)。

## 中核として移すもの

`Sources/QooMetaKit/` の次の部分。ロジックと規則の中身は変えない。中核が読むのは、比べるタイトル・書き手のキー・ジャンル・関連・
確定した内容(roadmap.md の「中核の入口」)。まず今のコードの中で入口の型の後ろへ切り出し、指紋が変わらないことを確かめてから、前段を替える。

- `VolumeExtractor.swift`(巻の読み取り)、`SeriesGrouper.swift`(シリーズの組み立て)、`TextForms.swift`(文字の正規化)
- `EditionMarkers.swift` の、タイトルから印を除く処理(比べるタイトルを作っている。`Propose.swift` の `parse` の後半)。
  捨てるのは版・入手経路の「欄」だけ
- `RuleLoader.swift` `RuleFiles.swift` `RuleJSON.swift` `RuleSchema.swift` `RuleCatalog.swift`(規則の第 2 版)
- `ProposalIndex.swift`(変更の索引)、`BulkEdit.swift` と `Confirmation` の考え方(欄は作り直す)
- `Sources/QooMetaRules/Resources/series-rules.json`・`examples.json`(例のファイルは移した後の確かめに使う)

捨てるもの: `NameParser.swift` `QooLibraryNameParser.swift`、サークル・イベント・版・入手元の欄、`QooMetaPreview`、`App/` の今の画面。
`Sources/QooFormat`(qooLibrary から写したコード)も捨てる。**qooLibrary は参考情報として参照するだけで、コードは持ってこない**
(2026-09-19 決定)。型の照合は qooMeta で書く。消すのは前段を替える段階 6(それまでは指紋の確認に要る)。`RuleLoader.swift` の
`RegexSafety` への依存も、そのとき qooMeta のものに替える。

## 確かめ方と基準値

- 例のファイル: `qoometa rules test`(架空の名前だけ。CI でも走る)。
- 結果の指紋: `qoometa scan` の最後の行。手元の蔵書 A の基準値は `bf1bb7c0e11c90eb1e5e2972`(11,269 冊、候補 1,087 組)。
  蔵書のパスは利用者に聞く(docs・コミットに書かない)。
- 公開データ(国立国会図書館): `qoometa evaluate --corpus ~/Library/Application Support/qooMeta-dev/corpus/ndl-labeled.jsonl`。
  適合率 0.766、再現率 0.988。
- 速さ: `qoometa bench`。一括 2.8 秒、並列 0.9 秒、1 冊の変更 3〜5 ms。
- 中核を入口の後ろへ切り出す段階(2)は、指紋が 1 文字も変わらないことで確かめる。前段を替える段階(6)では結果が変わる
  (書き手・ジャンルの読みの違い、フォルダ名を読まない、型の違い)ので、違いを原因別の集計で報告する。本の出力は同じ単位の
  ほかの本で決まるので、本ごとのハッシュだけでは比べられない。本ごとの記録はソルト付きのハッシュで、リポジトリの外へ置く。
- `examples.json` は古い欄(`circle` `event`)とジャンルの語彙が前提。段階 6 で書き換える。

## 守ること

- **蔵書の名前を外へ出さない**(CLAUDE.md)。フォルダ名・ファイル名をコード・docs・テスト・コミットに書かない。実データは集計だけ、
  名前を含む生成物は `~/Library/Application Support/qooMeta-dev/` へ。エージェントはそれを読まない。名前を見るときは文字種の「形」に
  置き換える。
- **ジャンルの語(利用者の本の種類の語)も書かない**。禁止語の検査(git hook)で止まる。
- アプリの画面を確かめるときは架空のデータ(`-demo`)だけを使い、実際の蔵書を画面に出さない。
- **コミットとプッシュは、そのたびに利用者の指示があるときだけ。** コミットメッセージは英語、コメントは日本語で「なぜ」を書く。

## 利用者との進め方

- 利用者に決めてもらうことは、**応答の中で 1 件ずつ**、背景・選択肢・おすすめを添えて聞く。「docs のどこそこを読んで」で済ませない。
  一度に全部を並べない。質問の道具の横の欄(プレビュー)は利用者に見えないことがあるので、中身は本文に書く。
- 他アプリを調べて取り入れるのは、欄・フォーマットの書き方・画面の操作の流れまで。中核に他アプリのやり方を持ち込まない。
- 決め打ちせず、利用者が選べるようにする(フォーマットで選べることは、仕組みを作らずフォーマットに任せる)。

## 作業ツリー(未コミット)

| 変更 | 扱い |
|---|---|
| `docs/concept.md` `docs/metadata.md` `docs/filename-format.md` `docs/roadmap.md` `docs/handoff.md` | 見直しの結果。残す |
| `App/`・`Sources/QooMetaPreview/`・`Tests/QooMetaPreviewTests/`・`Sources/QooMetaScan/ScanDocument.swift`・`Sources/QooMetaKit/SeriesVerdict.swift`・`scripts/dev/generate-app-project.sh`(追跡していないもの)と、`Sources/qoometa/Document.swift` `Sources/QooMetaAI/SeriesJudge.swift` `Package.swift` `README.md` `.gitignore` `.github/workflows/check.yml` の変更 | 旧来の欄で作った画面とその部品。**捨てる**(2026-09-19 決定。退避しない)。追跡していないものは消し、変更は `86d105a` の状態へ戻す。消したあと `swift build` と `swift test` が通ることを確かめる |

## 参考にしたもの

- qooViewer: このリポジトリと並ぶ `../qooViewer`(`4b912b1` で調査)。ファイル名フォーマット・除外文字列・巻数フォーマット、
  書き出し(EPUB・PDF・ComicInfo)。
- qooLibrary(**参考。ターゲットではない**): このリポジトリと並ぶ `../qooLibrary`。世の中の命名の形を知る材料としてだけ見る。
- StackNest: github.com/shelfsmith/stacknest。テンプレート・Stackroom XML・絞り込みの列・詳細ペイン・スタンプ・一括編集。
- ShelfRow: github.com/umberbyte/ShelfRow(`7355a41` で調査)。フォーマット 1 つ、Stackroom XML の取り込み(Neta をメモへ入れる)。
