# CLAUDE.md

qooMeta は、蔵書(漫画・同人誌の書庫ファイル)の**ファイル名の一覧**から、蔵書管理用のメタデータ
(著者・サークル・タイトル・シリーズ・巻・ネタ)を提案するツール。規則による機械的な処理と、
端末内モデル(Apple Intelligence / FoundationModels)による判定を組み合わせる。出力先は
qooViewer の保存データ JSON と、StackNest が取り込める Stackroom ライブラリ XML。
設計と経緯は `docs/design.md`。

## 最重要: 蔵書の名前を外へ出さない

- **蔵書のフォルダ名・ファイル名(ボリューム名は除く)を、コード・コメント・docs・テスト・コミットメッセージ・
  ブランチ名のどこにも書かない。** 「一般的な語だから」は理由にならない。テストの名前は合成したものだけを使う。
- 実データでの確認は、**集計だけを出力する**形で行う。CLI(`qoometa`)は標準出力へ名前を出さない作りで、
  名前を含む生成物(提案 JSON・見直し表 HTML・書き出し)はリポジトリの外
  (`~/Library/Application Support/qooMeta-dev/`)へ書く。CLI は Git の作業ツリーの中へは書かない。
- AI エージェントは、実データの生成物(提案 JSON・見直し表・書き出したファイル)を**読まない**。
  中身の確認は利用者が手元で行う。エージェントが見るのは集計と、名前を「形」(文字種)に置き換えたものだけ。
- 禁止語の一覧は `~/Library/Application Support/qooMeta-dev/private-terms.txt`(リポジトリの外。
  `scripts/dev/build-private-terms.py <蔵書のフォルダ>` で作る。qooViewer の一覧も併せて入れてある)。
  git hook(`scripts/dev/install-git-hooks.sh` で有効化)が、一覧が無ければコミットを拒否する。
  検査の出力に語そのものは出ない(`--reveal` は手元だけ)。
- 端末内モデルは通信しない。クラウドの AI サービスへ名前を送る機能は作らない(作るなら利用者の明示の判断で)。

## ビルドとテスト

```bash
swift build            # macOS 26 以降(FoundationModels)。開発機は macOS 27 / Xcode 27
swift test             # QooMetaCore のテスト(合成した名前だけ。端末内モデルは使わない)
swift build -c release && .build/release/qoometa        # 使い方が出る
```

## 作業の約束

- `git commit` は、そのたびに明示の指示があるときだけ。リモート(GitHub)へは登録しない(利用者の指示があるまで)。
- コミットメッセージは英語。1 行目に要約、空行、箇条書き。
- コメントは日本語で、何をするかより「なぜそうするか」を書く(qooViewer と同じ流儀)。
