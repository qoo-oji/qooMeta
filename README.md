# qooMeta

蔵書(漫画・同人誌の書庫ファイル)のファイル名の一覧から、蔵書管理用のメタデータを提案するコマンドラインツール。
規則による機械的な処理と、端末内モデル(Apple Intelligence)による判定を組み合わせ、番号の無いシリーズも
候補として見つける。書き出し先は qooViewer の保存データ JSON と、StackNest が取り込める Stackroom ライブラリ XML。

- 通信はしない(端末内モデルだけを使う)。
- 標準出力には集計だけを出す。名前を含む生成物は指定したファイルへ書き、Git の作業ツリーの中へは書かない。

## 動作環境

macOS 26 以降、Apple Intelligence が有効な Apple Silicon の Mac(判定の段だけ。ほかの段は要らない)。

## 使い方

```bash
swift build -c release
Q=.build/release/qoometa
OUT=~/Library/Application\ Support/qooMeta-dev/runs

$Q scan <蔵書のフォルダ> --out "$OUT/proposals.json"      # 走査・解析・規則の候補
$Q judge --in "$OUT/proposals.json"                        # 端末内モデルで候補を判定
$Q report --in "$OUT/proposals.json" --out "$OUT/review.html"   # 手元で見直す
$Q export --in "$OUT/proposals.json" --format stackroom --out "$OUT/Library.xml"
$Q export --in "$OUT/proposals.json" --format qooviewer --out "$OUT/qooviewer.json"
```

設計は [docs/design.md](docs/design.md)。
