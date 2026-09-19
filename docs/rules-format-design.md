# 規則ファイルの形式の設計(第 2 版の案)

2026-09-19。今の 2 つの規則 JSON(docs/rules.md、以下「第 1 版」)は最初のサンプルにすぎない。これから利用者の
フィードバックを受けて**中身を育て**、その過程で**形式そのものも広げていく**。そのための土台をここで決める。

## 何が起きるか(想定する変化)

| 変化 | 例 | 今の第 1 版で起きること |
|---|---|---|
| 語を足す・外す | 区切り語に `arc` を足す、既定の `旧版` を外したい | 足すのは JSON の編集で済むが、**利用者が既定の語を外す手段が無い** |
| 規則の値を変える | `minPrefix` を 3 に | 済む |
| 新しい種類の規則が要る | 「同じ作者で発行年が 10 年以上離れていたら分ける」 | **決まった形の構造体**なので、キーを足すにはコードと形式の両方を変える。古いアプリは新しいキーを読めずに止まる |
| 今コードに埋め込んである読み方を変えたい | ローマ数字の上限、雑誌の号の形 | JSON に出ていないので変えられない |
| 命名の違う蔵書に対応する | 商業の単行本、雑誌、別の同人誌の命名 | フォーマットは 1 組(同人誌向け)しか持てない |
| 利用者が自分の上書きを持つ | 蔵書固有の区切り語 | 同梱の既定値を書き換えるしかない(次の版で消える) |
| 規則を変えて何かが壊れないか確かめる | フィードバックで 1 語足すたびに | 手元の蔵書と公開データで測るしかない。**規則と一緒に持ち運べる確認手段が無い** |

## 設計の方針

1. **包み(エンベロープ)と版を分ける。** ファイルの種類と形式の版(`schemaVersion`)は中身と別に持つ。中身の改訂(`revision`)は
   形式の版と独立に進める。
2. **規則は「型付きの規則の並び」にする。** 決まったキーの構造体ではなく、`type` を持つ規則の配列にする。新しい種類の規則は、
   **新しい `type` を足すだけ**で、形式の版は上がらない。新しい種類には必要な版(`since`)を書き、古いアプリはその規則だけを飛ばして動く(下の「間違いと、新しい版の規則の見分け」)。
3. **規則ごとに ID を持たせる。** 上書き・無効化・テスト・フィードバックの対象を ID で指せるようにする。
4. **既定値と利用者の変更を分けて持つ。** 同梱の既定値は書き換えない。利用者が変えた内容は**別の JSON として保存**し、
   以降はそれを既定値に重ねて使う。「初期化」はその JSON を消すだけで、既定値に戻る(利用者の判断、下の「既定値と利用者の変更」)。
5. **語の一覧は名前を付けて一か所に置く。** 規則からは名前で参照する(`"@list:editionWords"`)。同じ一覧を複数の規則で使える。
6. **コードに埋め込んだ読み方も、規則として外に出す。** 巻の読み方(数字・第N・ローマ数字・雑誌の号 …)は、並び順が優先順位の
   「読み手」の配列にする。
7. **例を規則と一緒に持ち運ぶ。** 「この名前ならこう読む」という例のファイル(これも JSON)を規則と並べて同梱し、
   `qoometa rules test` で確かめる。**実在しない本の名前だけで書くので公開してよい**(利用者の判断)。フィードバックは、
   架空の名前に置き換えた例として受け取り、例に足してから規則を直す。
8. **処理に関係しない説明は入れない。** 理由や由来の文は書かない(利用者の方針)。説明は docs/rules.md に書く。

## 包み(両方のファイルに共通)

```json
{
  "$schema": "https://raw.githubusercontent.com/qoo-oji/qooMeta/main/schema/series-rules.schema.json",
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "revision": "2026.09.19",
  "extends": ["builtin"],
  "...": "中身"
}
```

| キー | 意味 |
|---|---|
| `$schema` | エディタで補完と検証をするための JSON Schema の場所(任意。読み込みには使わない) |
| `kind` | ファイルの種類(`qoometa.filename-formats` / `qoometa.series-rules` / `qoometa.examples`) |
| `schemaVersion` | 形式の版。**互換のない変更のときだけ上げる** |
| `revision` | 中身の改訂の印(日付など)。書き出しや不具合の報告に添える |
| `extends` | 重ねる元。`builtin`(同梱の既定値)、または別の規則ファイルのパス。省略すると単独のファイルとして読む |

### 版の上げ方

- 新しいキー・新しい `type`・新しい語の一覧を**足すだけなら版は上げない**(足したものに `since` を書き、古いアプリはそれだけを飛ばす)。
- キーの名前や意味を変える・消すときだけ `schemaVersion` を上げ、**古い版を新しい版へ移す処理**(マイグレーション)を必ず書く。
  第 1 版のファイルは、読み込むときに第 2 版へ移して使う(同梱の既定値も、利用者の上書きも)。
- 読み込みの流れ: JSON を型なしで読む → 版を見て順に移す → 重ね合わせる → 検証する → 型付きの規則に組み立てる。

### 間違いと、新しい版の規則の見分け(利用者の判断)

| 状況 | 例 | 扱い |
|---|---|---|
| JSON として壊れている | 括弧の閉じ忘れ、`,` の抜け | エラー。何行目の何文字目かを示す |
| 書き間違い | `"minPrefx"`、`"type": "rejectPrefx"` | **エラー**。場所と、近い綴りの候補を示す(「`minPrefix` ですか?」)。読み飛ばすと、効いているつもりで効いていない状態になるため |
| 新しい版の規則を古いアプリで読んだ | 新しい qooMeta で足した種類の規則を、更新前の qooMeta や古い qooViewer で読んだ | その規則だけを飛ばし、残りで動かす。「この規則には新しい版が必要」と知らせる |

見分けるために、規則(と項目)に**必要な版**を書けるようにする: `"since": 3`。必要な版が今の版より新しければ「新しい版の規則」、
そうでなく知らない項目・種類があれば「書き間違い」とする。同梱の既定値には、足した規則ごとに `since` を書く。

## 既定値と利用者の変更(利用者の判断)

- **既定値**: このリポジトリの規則。アプリに同梱し、アプリの更新で新しくなる。書き換えない。
- **利用者の変更**: GUI アプリなどで利用者が規則を変えると、その内容を**別の JSON** として保存し、以降はそれを使う。
- **初期化**: 利用者の変更の JSON を消す(退避してから消す)。既定値だけの状態に戻る。
- 利用者の変更は**変えたところだけ**を持つ(下の「重ね合わせ」)。既定値を丸ごと写さないので、アプリの更新で既定値が
  良くなったとき、利用者が触っていない部分にはその改善が届く。利用者が変えた部分は利用者の値が勝つ。
- 置き場所はアプリごとに分ける(CLI・GUI アプリ・qooViewer)。**形式は共通**にし、各アプリに規則の書き出しと
  読み込みを付けて、育てた規則を持ち運べるようにする(利用者の判断)。

## 重ね合わせ(上書き)

利用者の変更のファイルは、変えたいところだけを書く。

```json
{
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "extends": ["builtin"],
  "lists": {
    "labelIntroducers": { "$add": ["arc"] },
    "editionWords": { "$remove": ["旧版", "新版"] }
  },
  "grouping": {
    "rules": [
      { "id": "reject-common-english", "enabled": false },
      { "id": "min-prefix", "minPrefix": 3 }
    ]
  }
}
```

| 書き方 | 意味 |
|---|---|
| 値(数・文字列・真偽) | 置き換える |
| 配列そのもの | 置き換える |
| `{ "$add": [...], "$remove": [...] }` | 語の一覧に足す・外す |
| `{ "$replace": ... }` | 明示的に置き換える(`$add` などと区別したいとき) |
| ID の付いた規則の配列 | **同じ ID は中身を重ね、無い ID は末尾に足す**。`"enabled": false` で無効にする。`{ "$remove": "ID" }` で消す。並び順を変えたいときは `"after": "ID"` / `"before": "ID"` |

重ねる順(後のものが勝つ):

1. 同梱の既定値(`builtin`)
2. 利用者の変更(アプリごとの保存領域)

`qoometa rules show` で、重ねた結果の規則を表示できるようにする(どのファイルのどの値が効いているかも)。

## シリーズの規則(`qoometa.series-rules`)

```json
{
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "revision": "2026.09.19",

  "lists": {
    "labelIntroducers": ["side", "part", "episode", "…", "第", "その", "其ノ"],
    "editionWords": ["フルカラー版", "カラー版", "…"],
    "sourceWords": ["初回限定版", "限定版", "…"],
    "compilationWords": ["総集編", "総集篇"],
    "volumePrefixes": ["vol", "volume", "ver", "…", "第", "その"],
    "volumeCounters": ["月号", "月", "巻", "話", "号", "…"],
    "notFirstMarkers": ["総集編", "番外編", "外伝", "…"],
    "notFirstPrefixes": ["ex", "extra", "sp", "…"]
  },

  "compare": {
    "rules": [
      { "id": "nfkc", "type": "unicodeNormalize", "form": "NFKC", "lowercase": true },
      { "id": "drop-decorations", "type": "dropCharacters", "characters": " 　~〜～-‐―・!?.。、…" },
      { "id": "variant-kanji", "type": "mapCharacters", "map": { "凜": "凛", "髙": "高" } }
    ]
  },

  "partition": { "by": ["circle", "genre"] },

  "markers": {
    "rules": [
      { "id": "edition", "type": "titleMarker", "role": "edition", "words": "@list:editionWords",
        "patterns": ["[\\p{Han}\\p{Katakana}ー]{1,6}語版"] },
      { "id": "source", "type": "titleMarker", "role": "source", "words": "@list:sourceWords",
        "patterns": ["[DＤ][LＬ]版"] }
    ]
  },

  "grouping": {
    "rules": [
      { "id": "compilation", "type": "separateCompilation", "words": "@list:compilationWords",
        "singleWhenMainExists": true },
      { "id": "volume-head", "type": "volumeHead", "attachSubtitled": true },
      { "id": "shared-prefix", "type": "sharedPrefix", "minPrefix": 4, "minWholeTitle": 2 },
      { "id": "split-by-relation", "type": "splitByField", "field": "relation", "unlabeled": "joinLargest" },
      { "id": "reject-hiragana-ending", "type": "rejectPrefix", "when": "midWord", "endsWith": "hiragana" },
      { "id": "reject-single-word", "type": "rejectPrefix", "when": "midWord", "singleScript": true },
      { "id": "reject-common-english", "type": "rejectDictionaryTitles",
        "dictionary": "/usr/share/dict/words", "unlessVolume": true },
      { "id": "reject-same-work", "type": "rejectSameWorkOnly" }
    ]
  },

  "naming": {
    "rules": [
      { "id": "close-brackets", "type": "includeClosingBrackets",
        "pairs": { "】": "【", "」": "「", ")": "(" } },
      { "id": "keep-exclamation", "type": "includeFollowing", "characters": "!?！？" },
      { "id": "trim-trailing", "type": "trimTrailing", "characters": "~〜-・:、。「【(_" },
      { "id": "drop-label-word", "type": "dropLastWord", "words": "@list:labelIntroducers" }
    ]
  },

  "volume": {
    "readers": [
      { "id": "magazine-issue", "type": "issueNumber", "mergedSpan": 3 },
      { "id": "ordinal", "type": "ordinal", "prefix": "第", "anyCounter": true, "subParts": true },
      { "id": "number", "type": "number", "prefixes": "@list:volumePrefixes",
        "counters": "@list:volumeCounters", "mergedSpan": 3 },
      { "id": "kanji", "type": "kanjiNumber", "extended": true },
      { "id": "greek", "type": "greekLetter" },
      { "id": "roman", "type": "romanNumeral", "max": 39, "uppercaseOnly": true },
      { "id": "position", "type": "positionWord",
        "first": ["上", "上巻", "前編"], "middle": ["中", "中巻", "中編"], "last": ["下", "下巻", "後編"] }
    ],
    "inference": [
      { "id": "shared-leading-kanji", "type": "sharedLeadingKanji", "minBooks": 2 },
      { "id": "first-volume", "type": "inferFirstVolume",
        "excludeMarkers": "@list:notFirstMarkers", "excludePrefixes": "@list:notFirstPrefixes" }
    ]
  }
}
```

- `rules` / `readers` / `inference` は**並び順が適用の順**。読み手は上から試し、最初に読めたものを採る。
- 各 `type` の意味と引数は、コードの側の「規則の登録簿」に 1 か所で定義し、docs/rules.md と JSON Schema を同じ定義から作る
  (説明と実装がずれないようにする)。
- 新しい振る舞いが要るときは、コードに新しい `type` を 1 つ足し、JSON で有効にする。既存の規則には触れない。

## ファイル名のフォーマット(`qoometa.filename-formats`)

命名の違う蔵書に対応できるよう、フォーマットを**プロファイル**に分ける。

```json
{
  "kind": "qoometa.filename-formats",
  "schemaVersion": 2,
  "revision": "2026.09.19",

  "reservedWords": {
    "@genre":    { "engine": "@mediatype", "field": "genre" },
    "@event":    { "engine": "@event",     "field": "event" },
    "@circle":   { "engine": "@studio",    "field": "circle" },
    "@author":   { "engine": "@author",    "field": "authors", "split": "、,，&＆/／" },
    "@title":    { "engine": "@title",     "field": "title" },
    "@relation": { "engine": "@genre",     "field": "relation" },
    "@keywordA": { "engine": "@keyword",   "field": "keyword" }
  },

  "profiles": [
    {
      "id": "doujinshi",
      "delimiters": [["[", "]"], ["(", ")"]],
      "protectedTokens": ["\\((19[0-9]{2})\\)", "\\((20[0-9]{2})\\)", "\\((結|終|完|完結|完全版)\\)"],
      "formats": [
        "(@genre) [@circle (@author)] @title (@relation) [@keywordA]",
        "…",
        "[@circle] @title"
      ]
    }
  ],

  "fallback": [
    { "id": "simple-brackets", "type": "simpleBrackets" },
    { "id": "whole-name", "type": "wholeNameAsTitle" }
  ]
}
```

- プロファイルは上から試し、最初にどれかのフォーマットが一致したプロファイルを採る。今は同人誌向けの 1 つだけ。
  商業の単行本・雑誌などは、プロファイルを足して広げる。
- 将来、プロファイルに適用の条件(`"when": { "folder": "…" }` のような)を足す余地を残す(足しても版は上げない)。
- 予約語の細かい設定(作者の区切り文字など)は、予約語の側に持たせる。

## 例のファイル(`qoometa.examples`)

```json
{
  "kind": "qoometa.examples",
  "schemaVersion": 2,
  "examples": [
    {
      "id": "compilation-numbered-later",
      "files": [
        "[架空工房] 月の庭 1",
        "[架空工房] 月の庭 2",
        "[架空工房] 月の庭 総集編",
        "[架空工房] 月の庭 総集編2"
      ],
      "expect": [
        { "series": "月の庭", "volume": "1" },
        { "series": "月の庭", "volume": "2" },
        { "series": "月の庭 総集編", "volume": "1", "inferred": true },
        { "series": "月の庭 総集編", "volume": "2" }
      ],
      "covers": ["compilation", "first-volume"]
    }
  ]
}
```

- `files` はファイル名(拡張子なし)。`expect` は同じ順の期待値で、書いた項目だけを確かめる。
- `covers` は、この例が確かめる規則の ID。規則を無効にしたときに壊れる例が分かる。
- **例には架空の名前だけを書く**(公開されるため。コミット時の検査がかかる)。フィードバックで受け取った実例は、
  形を保ったまま架空の名前に置き換えてから足す。
- `qoometa rules test` が例を全部確かめる。CI とテストでも同じものを走らせる。
- 今の単体テスト(合成した名前のもの)の多くは、この例のファイルへ移せる。

## JSON Schema

`schema/` に、3 種類のファイルの JSON Schema を置く。エディタ(VS Code など)での補完と検証、CI での検査に使う。
Schema は規則の登録簿から作り、手で書かない。

## 第 1 版からの移し方

1. 読み込み側に「型なしで読む → 版を移す → 重ねる → 検証 → 組み立て」の流れを作る。第 1 版はこの流れの最初で第 2 版に移す。
2. 規則の登録簿を作り、今のコードの判断(組の作り方・例外・名前の整え方・巻の読み方)を、ID の付いた規則として 1 つずつ移す。
   コードに埋め込んである読み方(ローマ数字・雑誌の号 …)もここで規則にする。
3. 同梱の既定値を第 2 版で書き直す。
4. 各段で、両方の蔵書と公開データの結果が 1 冊も変わらないことを確かめる(第 1 版を JSON に移したときと同じ手順)。
5. 今の単体テストを、例のファイルへ移せるものは移す。
6. docs/rules.md を第 2 版の説明に書き直す(登録簿から作る部分と、手で書く部分に分ける)。

## 決まったこと(2026-09-19)

- 置き場所はアプリごとに分け、形式は共通にして書き出し・読み込みで持ち運べるようにする。
- 書き間違いはエラー、新しい版の規則は飛ばして知らせる(`since` で見分ける)。
- このリポジトリの規則は既定値。利用者の変更は別の JSON に保存して以降それを使い、初期化で既定値に戻す。
- 例のファイルは、実在しない本の名前だけで書いて公開する。

## 残っていること

- 利用者の変更のファイルの名前と、各アプリでの置き場所の細部(実装のときに決める)。
