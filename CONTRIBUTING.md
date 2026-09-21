# 貢献の手引き

## 名前は架空のものだけを書く

qooMeta は蔵書のファイル名を扱いますが、**実在する本・サークル・作者の名前は、どこにも書かないでください。**
コード・コメント・文書・テスト・例のファイル・Issue・Pull Request・コミットメッセージのすべてが対象です。

- 「うまく読めない名前がある」という報告は、形を保ったまま、**すべての語**を架空のものに置き換えて書いてください
  (置き換えの規則は `docs/api.md`「フィードバック」)。
  - かな・カタカナ・漢字の語は、同じ文字種・同じ長さの架空の語に。同じ語は同じ語へ置き換えます。
  - 英字の語は、同じ長さの作り語に(一般的な英単語は、別の一般的な英単語に)。
  - 規則の一覧にある語(総集編・vol・第・上・フルカラー版 …)、括弧・記号・空白・数字はそのまま残します。
  - 例: 実在の名前の代わりに `(種別A) [架空工房 (山田太郎)] 月の庭 2 (作品A) [DL版]`
- 置き換えたあとの名前で、同じ結果(同じ誤り)になることを確かめてから送ってください。
- 本の種別(ファイル名の先頭の丸括弧に書く分類)の名前も、`種別A` のような架空のものにしてください。

## 同梱の規則ファイルについて

`Sources/QooMetaRules/Resources/filename-formats.json` と `series-rules.json` は、作者の手元の設定を既定値として取り込んだもので、
語の一覧に蔵書の分け方の語を含みます。この 2 つだけは禁止語の検査の対象外です(`scripts/ci/check-private-terms.py` の `EXEMPT`)。
ここにある語を、ほかのファイル(コード・テスト・文書・例)や Issue・Pull Request に写さないでください。

## 規則を変えるとき

規則(`Sources/QooMetaRules/Resources/*.json`)や処理を変える前に、確かめたい形を**例のファイル**
(`Sources/QooMetaRules/Resources/examples.json`)に足します。形式は `docs/rules-format-design.md`「例のファイル」です。

```json
{
  "id": "same-first-word-is-not-a-series",
  "files": ["(種別A) [架空工房] NEON 夜の街 (作品A)", "(種別A) [架空工房] NEON 朝の港 (作品B)"],
  "expect": [{ "series": null }, { "series": null }],
  "covers": ["splitByRelation"]
}
```

- `expect` は `files` と同じ順で、書いた項目だけを確かめます。`"series": null` は「シリーズに入ってはいけない」。
- `covers` には、その例が確かめる規則の ID を書きます。
- 例が前提にする規則の値は、例の側に書きます。方針は `"policies": { "compilations": "ownSeries" }`、ほかの値は
  `"settings": { "grouping.mergeSubseries.enabled": false }`(点つなぎの場所 → 値)。同梱の既定値は利用者の蔵書に合わせて
  変わることがあるので、書いておかないと、既定値を変えたときに関係の無い例まで崩れます。テストも同じで、
  `CompiledRules.builtin.applying(policies:settings:)` で前提の値を決めてから確かめます。

変えたら、次がすべて通ることを確かめてください(CI でも同じものが走ります)。利用者に見える変更は
[CHANGELOG.md](CHANGELOG.md) の `[Unreleased]` に書きます。

```bash
swift build
swift test
swift run qoometa rules test          # 例のファイル
scripts/ci/check-all.sh               # リポジトリの約束事(個人のパスなど)
```
