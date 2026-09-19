# qooMeta

漫画・同人誌の書庫ファイル(zip/cbz・rar/cbr・7z/cb7)の**ファイル名の一覧**から、蔵書管理用のメタデータ
(サークル・作者・タイトル・シリーズ・巻・ネタ・版)を提案するコマンドラインツールです。

- 書庫の中身は開きません。ファイル名とフォルダ構成だけを読みます。
- ファイル名の読み取りには、[qooLibrary](https://github.com/qoo-oji/qooLibrary) のファイル名フォーマット処理を使います
  (`Sources/QooFormat` に写してあります)。
- 番号の無いシリーズも、同じ書き手の本どうしを見比べて見つけます。1 冊目にだけ番号の無いシリーズ、総集編、
  版違い(フルカラー版など)や入手経路違い(DL版など)、雑誌の号・合併号も扱います。
- 通信はしません。判定は規則と、任意で端末内モデル(Apple Intelligence)だけで行います。

## 書き出せるもの

| 書き出し | 使い道 |
|---|---|
| シリーズの一覧(CSV) | 表計算ソフトで確かめる |
| 見直し表(HTML) | シリーズの組ごとに手元で見直す |
| Stackroom 2.1b のライブラリ XML | [StackNest](https://github.com/shelfsmith/stacknest) に取り込む(新しいライブラリになる) |
| qooViewer の保存データ JSON | qooViewer の「保存データの読み込み」でメタデータとして取り込む |

## 動作環境

- macOS 26 以降(開発は macOS 27 / Xcode 27、Swift 6.4)
- 端末内モデルでの判定(`judge`)を使うときだけ、Apple Intelligence が有効な Apple Silicon の Mac

## ビルドとテスト

```bash
swift build -c release
swift test
```

## 使い方

生成物には蔵書の名前がそのまま入るので、**リポジトリの外**に置きます(`qoometa` は Git の作業ツリーの中へは書きません)。

```bash
Q=.build/release/qoometa
OUT=~/Library/Application\ Support/qooMeta-dev/runs

$Q scan <蔵書のフォルダ> --out "$OUT/proposals.json"          # 走査・名前の解析・シリーズの組
$Q stats --in "$OUT/proposals.json"                            # 集計(名前は出さない)
$Q series-list --in "$OUT/proposals.json" --out "$OUT/series-list.csv" [--exclude-from <以前の一覧.csv>]
$Q report --in "$OUT/proposals.json" --out "$OUT/review.html"
$Q export --in "$OUT/proposals.json" --format stackroom --out "$OUT/Library.xml"
$Q export --in "$OUT/proposals.json" --format qooviewer --out "$OUT/qooviewer.json"
$Q judge --in "$OUT/proposals.json"                            # 任意: 端末内モデルでシリーズの組を判定
$Q evaluate --corpus <正解付き.jsonl>                           # 公開データで規則を採点
```

### 設定

`~/Library/Application Support/qooMeta-dev/config.json`(リポジトリの外):

```json
{ "mediaTypes": ["<本の種別の名前>", "..."] }
```

`mediaTypes` は本の種別(ファイル名の先頭の丸括弧に書く分類)の語彙です。ここにある語は本の種別、無い語は頒布イベント名として
読みます。本の種別が違う本は同じシリーズにしません。

## 蔵書の名前を外へ出さないために

- 標準出力には集計だけを出し、名前を含む生成物はリポジトリの外へ書きます。
- `.gitignore` は、生成物になりうる形式(CSV・JSON・XML・HTML・SQLite など)をまとめて追跡しません。
- 蔵書のフォルダ名・ファイル名から作った禁止語の一覧(リポジトリの外)と照合する検査を、git hook で必ず通します。

```bash
scripts/dev/build-private-terms.py <蔵書のフォルダ> [別のフォルダ …]   # 禁止語の一覧を作る(語は表示しない)
scripts/dev/install-git-hooks.sh                                     # pre-commit / commit-msg / pre-push を有効にする
scripts/ci/check-private-terms.sh --require-terms                   # 手で検査する
```

一覧が無いとコミットは拒否されます。検査の出力に語そのものは出ません。

## 公開データでの検討

規則は、国立国会図書館サーチの書誌(商業コミック、利用登録不要)でも採点しています
(`scripts/corpus/fetch-ndl.py` → `scripts/corpus/ndl-to-labeled.py` → `qoometa evaluate`)。取得したデータはリポジトリの外に置きます。

## ドキュメント

- [docs/rules.md](docs/rules.md) — 規則ファイル(`filename-formats.json` と `series-rules.json`)の説明書
- [docs/design.md](docs/design.md) — 設計、規則の一覧、未決事項
- [docs/rules-format-design.md](docs/rules-format-design.md) — 規則ファイルの形式を育てていくための設計(第 2 版の案)
- [docs/api.md](docs/api.md) — ライブラリとしての API 仕様(案)
- [docs/roadmap.md](docs/roadmap.md) — 実装計画(規則ファイルの第 2 版 → ライブラリ化 → GUI アプリ → qooViewer への組み込み)
- [Sources/QooFormat/README.md](Sources/QooFormat/README.md) — qooLibrary から写したコードの出どころ

## ライセンス

MIT License([LICENSE](LICENSE))。`Sources/QooFormat` は qooLibrary(MIT、同じ作者)から写したものです。
