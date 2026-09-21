# qooMeta

本(商業のコミック・同人誌などの書庫ファイル)の**ファイル名の一覧**から、qooViewer・
[StackNest](https://github.com/shelfsmith/stacknest)・[ShelfRow](https://github.com/umberbyte/ShelfRow) が本を管理するための
メタデータを作る macOS のツールです。作るのはタイトル・著者の並び・ジャンル・イベント・原作・情報・シリーズ・巻数で、
利用者が確かめて直し、各アプリの取り込める形で書き出します。

- **読むのはファイル名だけ**です。書庫の中身は開かず、蔵書を管理するライブラリも持ちません(1 回きりの作業の道具)。
- ファイル名は、利用者が並べた**型**(`[@author] @title (@source)` のような書き方。3 つのアプリと同じ予約語)で読みます。
  型の並び(ルールセット)は、フォルダや名前に書いてある語から**本ごとに自動で選ぶ**こともできます。
- **シリーズ名と巻数は、タイトルから導きます**(中核)。番号の無いシリーズも、同じ書き手の本どうしを見比べて見つけます。
  総集編・番外編、版違い(フルカラー版など)や入手経路違い(DL版など)、雑誌の号も扱います。
- 取り違えを道具の側で先回りして防ぐことはせず、読んだ結果を一覧で見せて、利用者がまとめて直せるようにしています。
- 通信はしません。判定は規則(JSON)と、任意で端末内モデル(Apple Intelligence)だけで行います。

## アプリ

窓の上の段に沿って、1 回きりの流れで進みます。

1. **対象を選ぶ** — フォルダかファイルを選ぶ(書庫 `zip` `cbz` `rar` `cbr` `7z` `cb7`、`pdf`、`epub`、画像のフォルダ)。
   前に保存した作業ファイルを開いて続きから始めることもできます。
2. **解析方法を選ぶ** — ルールセット(商業誌・同人誌(ジャンル)・同人誌(イベント)・自分で作ったもの)ごとに、
   何冊の名前を読み切れたかを見て選びます。「自動」を選ぶと、本ごとに条件に当たるルールセットで読みます
   (全冊が決まるときだけ選べます)。
3. **確認・編集** — 一覧で欄を直す(セルを 2 回押す)、まとめて書き換える、スタンプを押す、シリーズを確定する・外す・巻を振る。
   どの型にも合わなかった本は灰色で出ます。右クリックで、選んだ本だけ別のルールセットで読み直せます。
4. **書き出す** — 書き出し先を選び、欄の対応表を確かめて書き出します。

| 書き出し先 | 形式 |
|---|---|
| qooViewer | 保存データの JSON(「保存データの読み込み」で取り込む) |
| StackNest | Stackroom 2.1b のライブラリ XML |
| ShelfRow | Stackroom XML(ShelfRow が読む欄に合わせる) |

設定の窓は 2 つあります。

- **解析の設定**(ファイル名の解析): ルールセットの型の並び・著者の区切り・既定の欄・型として読まない文字列・自動の判定の条件。
  直しながら、選んだ本の名前で読んだ結果をその場で見られます。
- **抽出の設定**(シリーズと巻数の抽出): やりたいこと(「同じシリーズにしたい本が別々になる」など)から入り、方針・語の規則・
  巻の読み方・語の一覧を直せます。

設定(同梱の既定値との差分・スタンプ・書き出しの対応表)は `~/Library/Application Support/qooMeta/settings.json` に、
作業ファイル(直している途中の一覧)は利用者が選んだ場所に保存します。画面の言葉は英語と日本語です。

### アプリの組み立て

```bash
cd App && xcodegen          # qooMeta.xcodeproj を作る(XcodeGen が要る)
open qooMeta.xcodeproj      # スキーム qooMeta。引数 -demo で架空のデータを開く
```

## 動作環境

- macOS 15 以降(アプリ・ライブラリ・CLI)。Swift 6.2 以降。開発は macOS 27 / Xcode 27。
- 端末内モデルでの判定(CLI の `judge`)を使うときだけ、macOS 26 以降で Apple Intelligence が有効な Apple Silicon の Mac。

## 構成

| モジュール | 役割 |
|---|---|
| `QooMetaKit` | 本体。型の照合、シリーズ・巻の導出、変更の索引、作業ファイル、規則の組み立てと検証。純粋な計算(ファイル・通信・ログに触れない) |
| `QooMetaRules` | 同梱の既定値(規則・例のファイル)と、システムの辞書の読み込み |
| `QooMetaExport` | 書き出し(Stackroom XML・qooViewer JSON・ComicInfo)と、書き出し先ごとの欄の対応表。`Data` を返す |
| `QooMetaScan` | フォルダの走査(名前と属性だけ) |
| `QooMetaAI` | 端末内モデルでの判定(任意、macOS 26 以降) |
| `qoometa` | CLI |
| `App/` | macOS アプリ(SwiftUI + AppKit の一覧) |

ライブラリとしての使い方は [docs/api.md](docs/api.md) です。

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

## ビルドとテスト

```bash
swift build -c release
swift test
swift run qoometa rules test     # 例のファイル(Sources/QooMetaRules/Resources/examples.json)
scripts/ci/check-all.sh          # リポジトリの約束事(CI でも走る)
```

規則を変えるときは、先に確かめたい形を例のファイルに足します([CONTRIBUTING.md](CONTRIBUTING.md))。

## CLI

生成物には蔵書の名前がそのまま入るので、**リポジトリの外**に置きます(`qoometa` は Git の作業ツリーの中へは書きません)。
標準出力には集計だけを出します。

```bash
Q=.build/release/qoometa
OUT=~/Library/Application\ Support/qooMeta-dev/runs

$Q scan <蔵書のフォルダ> --out "$OUT/proposals.json"                 # 走査・名前の解析・シリーズの提案
$Q stats --in "$OUT/proposals.json" [--explain]                       # 集計(--explain は組にしなかった規則も数える)
$Q formats --in "$OUT/proposals.json" [--preset <名前>]               # 型ごとの一致冊数
$Q report --in "$OUT/proposals.json" --out "$OUT/review.html"         # 手元で開く見直し表
$Q series-list --in "$OUT/proposals.json" --out "$OUT/series.csv"     # シリーズの付いた本の一覧
$Q export --in "$OUT/proposals.json" --to stacknest|shelfrow|qooviewer --out <ファイル> [--mapping <対応表.json>]
$Q judge --in "$OUT/proposals.json"                                   # 任意: 端末内モデルでシリーズを判定
$Q bench --synthetic 20000 [--no-authors]                             # 合成した名前で速さとメモリを測る
$Q evaluate --corpus <正解付き.jsonl>                                  # 公開データで規則を採点
$Q rules test [<例.json> …]                                           # 例のファイルで規則を確かめる
$Q rules validate <規則.json>                                         # 規則の変更(差分)を確かめる
$Q rules show                                                         # 既定値に変更を重ねた結果
```

- `--in` には、`scan` の提案ファイルのほか、**アプリの作業ファイル**(直した内容つき)も渡せます。
- どのコマンドにも `--rules <変更.json>`(既定値に重ねる規則の差分)と `--presets <割り当て.json>`
  (フォルダごとのルールセット)を付けられます。規則の書き方は [docs/rules.md](docs/rules.md) です。

## 蔵書の名前を外へ出さないために

- 標準出力には集計だけを出し、名前を含む生成物はリポジトリの外へ書きます。
- `.gitignore` は、生成物になりうる形式(CSV・JSON・XML・HTML など)をまとめて追跡しません。
- 蔵書のフォルダ名・ファイル名から作った禁止語の一覧(リポジトリの外)と照合する検査を、git hook で必ず通します。
  同梱の規則ファイル 2 つ(`filename-formats.json`・`series-rules.json`)だけは、利用者の設定を既定値として取り込んだものなので
  対象外です。

```bash
scripts/dev/build-private-terms.py <蔵書のフォルダ> [別のフォルダ …]   # 禁止語の一覧に足す(語は表示しない。作り直すのは --rebuild)
scripts/dev/install-git-hooks.sh                                     # pre-commit / commit-msg / pre-push を有効にする
scripts/ci/check-private-terms.sh --require-terms                   # 手で検査する
```

一覧が無いとコミットは拒否されます。検査の出力に語そのものは出ません。

## 公開データでの検討

規則は、国立国会図書館サーチの書誌(商業コミック、利用登録不要)でも採点しています
(`scripts/corpus/fetch-ndl.py` → `scripts/corpus/ndl-to-labeled.py` → `qoometa evaluate`)。取得したデータはリポジトリの外に置きます。

## ドキュメント

- [docs/concept.md](docs/concept.md) — 目的・ターゲットのアプリ・原則
- [docs/metadata.md](docs/metadata.md) — 欄と、書き出し先ごとの受け渡し
- [docs/filename-format.md](docs/filename-format.md) — ファイル名フォーマット(型の書き方・予約語・ルールセット・自動の判定)
- [docs/rules.md](docs/rules.md) — 規則ファイル(`filename-formats.json`・`series-rules.json`)の説明書
- [docs/rules-format-design.md](docs/rules-format-design.md) — 規則ファイルの形式の設計(版・差分・例のファイル)
- [docs/design.md](docs/design.md) — 設計
- [docs/api.md](docs/api.md) — ライブラリとしての API
- [docs/roadmap.md](docs/roadmap.md) — 実装計画と、決めたことの控え
- [docs/handoff.md](docs/handoff.md) — 開発の引き継ぎ(経緯と確かめ方)
- [CHANGELOG.md](CHANGELOG.md) — 変更履歴

## ライセンス

MIT License([LICENSE](LICENSE))。
