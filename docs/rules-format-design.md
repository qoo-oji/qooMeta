# 規則ファイルの形式の設計(第 2 版)

2026-09-19(同日のレビューを反映)。今の 2 つの規則 JSON(docs/rules.md、以下「第 1 版」)は最初のサンプルにすぎない。
これから利用者のフィードバックを受けて**中身を育て**、その過程で**形式そのものも広げていく**。そのための土台をここで決める。

## 想定する変化

| 変化 | 例 | 第 1 版で起きること |
|---|---|---|
| 語を足す・外す | 区切り語に `arc` を足す、既定の `旧版` を外したい | 利用者が既定の語を外す手段が無い |
| 規則の値を変える・止める | `minPrefix` を 3 に、英単語の例外を止める | 同梱の既定値を書き換えるしかない(次の版で消える) |
| 新しい種類の規則が要る | 「発行年が 10 年以上離れていたら分ける」 | 決まった形の構造体なので、古いアプリは新しいキーを読めずに止まる |
| 命名の違う蔵書に対応する | 商業の単行本、雑誌 | フォーマットは 1 組しか持てない |
| 規則を変えて何かが壊れないか確かめる | 1 語足すたびに | 規則と一緒に持ち運べる確認手段が無い |

## 方針

1. **包みと版を中身から分ける。** 版の番号の役割は下の表のとおり。
2. **処理の段階は固定し、段階の中の規則に ID を付ける。** 利用者が変えられるのは、規則のオン・オフ、パラメータ、語の一覧。
   並べ替えられるのは巻の読み手だけ(下の「段階と規則」)。
3. **既定値と利用者の変更を分けて持つ。** 同梱の既定値は書き換えない。利用者の変更は**別の JSON(差分)**として保存し、
   以降は既定値に重ねて使う。「初期化」は差分を消すこと(利用者の判断)。
4. **語の一覧は名前を付けて `lists` に置き、規則からは `"@list:名前"` で参照する。** 文字の並び(記号の集合)も配列にして `lists` に置く
   (全角空白やタブを目で確かめられ、足す・外すができるように)。
5. **規則ファイルは、ほかのファイルやパスを指さない。** 受け取った規則ファイルが、利用側のファイルを読ませる経路にならないようにする。
   辞書のような外の資源は**名前**で指し、実体は利用側が API で渡す(api.md「辞書」)。
6. **例のファイルを規則と一緒に持ち運ぶ。** 実在しない本の名前だけで書き、公開・同梱する(利用者の判断)。
7. **処理に関係しない説明は入れない**(理由・由来の文は書かない。説明は docs/rules.md)。
8. 規則の中の正規表現は **ICU の正規表現**(NSRegularExpression)とする。どのアプリでも同じ規則ファイルが同じ意味になるように。

## 版の番号

| 番号 | どこに書くか | いつ上がるか | 何に使うか |
|---|---|---|---|
| `schemaVersion` | 規則ファイル | 形式に**互換のない変更**をしたとき(キーの改名・削除・意味の変更) | 読み込み時に古い版を新しい版へ移す(マイグレーション) |
| `engineLevel` | qooMeta 本体が持つ整数。規則の `since` と比べる | 規則の種類(`type`)・パラメータ・一覧を**足した**とき | 古いアプリが、新しい規則を「書き間違い」ではなく「新しい版の規則」と見分ける |
| `revision` | 規則ファイル(作者が書く印。日付など) | 中身を改訂したとき | 不具合の報告に添える。キャッシュの判定には使わない(本体が内容のハッシュを別に計算する) |
| パッケージの版(SemVer) | Git のタグ | Swift の API を変えたとき | 利用側の依存の指定 |

- `schemaVersion` は今 2。`engineLevel` は第 2 版の最初の実装を 1 とする。
- 規則・パラメータ・一覧を足したら `engineLevel` を 1 上げ、足したものに `"since": その番号` を書く。
- 第 1 版(`version: 1`、公開から間もなく利用者がいない)からのマイグレーションは、仕組みだけ用意して後回しにする。

## 包み

```json
{
  "$schema": "https://raw.githubusercontent.com/qoo-oji/qooMeta/main/schema/series-rules.schema.json",
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "revision": "2026.09.19",
  "base": "builtin"
}
```

| キー | 意味 |
|---|---|
| `$schema` | エディタの補完・検証用(任意。読み込みには使わない) |
| `kind` | `qoometa.filename-formats` / `qoometa.series-rules` / `qoometa.examples` / `qoometa.rules-bundle` |
| `schemaVersion` | 形式の版 |
| `revision` | 中身の改訂の印(任意) |
| `base` | 差分のファイルにだけ書く。値は `"builtin"` のみ(同梱の既定値に重ねる)。**パスや URL は書けない** |

`qoometa.rules-bundle` は、アプリ間で規則を持ち運ぶための 1 ファイル(フォーマットの差分とシリーズの規則の差分をまとめたもの)。

## 読み込みと誤りの扱い

読み込みの流れ: JSON を型なしで読む → `schemaVersion` を見て移す → 既定値に差分を重ねる → 検証する → 組み立てる。
**誤りは最初の 1 件で止めず、すべて集めて返す**(規則の編集画面で使うため)。

| 状況 | 例 | 扱い |
|---|---|---|
| JSON として壊れている | 括弧の閉じ忘れ | エラー(行・列) |
| 書き間違い | `"minPrefx"`、`"type": "rejectPrefx"`、存在しない一覧への参照 | **エラー**(位置と、近い綴りの候補)。読み飛ばすと「効いているつもりで効いていない」になる |
| 新しい版の規則(`since` > 本体の `engineLevel`) | 新しい qooMeta で作った差分を古い qooViewer で読んだ | その規則(パラメータ・一覧)を飛ばして警告。ただし `"required": true` の規則なら、**そのファイル全体を適用せず**警告(既定値だけで動く) |
| 廃止された ID・別名への参照 | 既定値から消した規則を、利用者の差分が無効にしている | 無視して警告(エラーにしない)。アプリの更新で利用者のファイルが読めなくなるのを防ぐ |
| すでに無い語の `$remove`、すでにある語の `$add` | | 何もしない(警告も出さない) |
| 上限を超える | 巨大なファイル、語数、危険な正規表現 | エラー |

### ID の約束

- 規則の ID は**再利用しない**。消した ID は既定値の `retiredIDs` に残す。改名したら `aliases`(旧 → 新)に書き、旧 ID への参照は新 ID として扱う。
- `"required": true` は、飛ばすと結果が黙って悪くなる規則(組にしない例外など)に付ける。既定値の規則には原則として付け、
  純粋な追加(新しい巻の読み手など)には付けない。

```json
"retiredIDs": ["reject-old-rule"],
"aliases": { "reject-english": "reject-common-english" }
```

## 既定値と利用者の変更(差分)

- **既定値**: このリポジトリの規則。アプリに同梱し、アプリの更新で新しくなる。書き換えない。
- **利用者の変更**: 利用者が規則を変えると、**変えたところだけ**を別の JSON として保存し、以降はそれを使う。
  既定値を丸ごと写さないので、アプリの更新で既定値が良くなったとき、利用者が触っていない部分にはその改善が届く。
- **初期化**: 差分の JSON を退避してから消す。既定値だけの状態に戻る。
- 置き場所はアプリごとに分ける(CLI・GUI アプリ・qooViewer)。形式は共通で、`qoometa.rules-bundle` の書き出し・読み込みで持ち運ぶ。
- 重ねるのは「既定値 → 利用者の変更」の 2 層だけ。

```json
{
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "base": "builtin",
  "lists": {
    "labelIntroducers": { "$add": ["arc"] },
    "editionWords": { "$remove": ["旧版", "新版"] },
    "variantKanji": { "$set": { "﨑": "崎" }, "$unset": ["嶋"] }
  },
  "grouping": {
    "sharedPrefix": { "minPrefix": 3, "conditions": { "reject-common-english": { "enabled": false } } }
  },
  "volume": {
    "readers": { "roman": { "enabled": false }, "$order": ["ordinal", "number"] }
  }
}
```

| 書き方 | 対象 | 意味 |
|---|---|---|
| 値(数・文字列・真偽) | パラメータ | 置き換える |
| `{ "$add": [...], "$remove": [...] }` | 配列の一覧 | 足す・外す |
| `{ "$set": {...}, "$unset": [...] }` | 対応表(異体字・括弧の対) | 足す(置き換える)・外す |
| `{ "$replace": ... }` | 一覧・対応表 | 丸ごと置き換える |
| `"規則の ID": { "enabled": false, パラメータ… }` | 規則 | 止める・パラメータを変える |
| `"$order": ["ID", …]` | **巻の読み手だけ** | 挙げた ID を、この順で先頭に寄せる(挙げなかった読み手は既定の順で後ろに続く) |

## 段階と規則(`qoometa.series-rules`)

処理の段階は固定で、JSON の構造がそのまま段階を表す。**段階の順や、段階をまたぐ規則の移動はできない。**
例外(組にしない条件)は、それが働く規則の `conditions` にぶら下げる(実際の処理でも、その規則の判定の内側で働くため)。

```json
{
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "revision": "2026.09.19",

  "lists": {
    "ignoredInComparison": [" ", "　", "\t", "~", "〜", "-", "・", "!", "?", "…"],
    "boundaryCharacters": ["~", "〜", "-", "・", "!", "?", "(", ")", "_", "…"],
    "trimTrailing": ["~", "〜", "-", "・", ":", "、", "。", "「", "【", "(", "_"],
    "keepFollowing": ["!", "?", "！", "？"],
    "brackets": { "】": "【", "」": "「", ")": "(" },
    "variantKanji": { "凜": "凛", "髙": "高" },
    "labelIntroducers": ["side", "part", "episode", "第", "その", "其ノ"],
    "editionWords": ["フルカラー版", "カラー版", "完全版"],
    "sourceWords": ["初回限定版", "限定版", "特装版", "通常版", "電子版"],
    "compilationWords": ["総集編", "総集篇"],
    "volumePrefixes": ["vol", "volume", "ver", "no", "#", "第", "その", "其ノ"],
    "volumeCounters": ["月号", "月", "巻", "話", "号", "章", "弾", "つめ"],
    "kanjiCounters": ["巻", "話", "号", "章"],
    "positionFirst": ["上", "上巻", "前編"],
    "positionMiddle": ["中", "中巻", "中編"],
    "positionLast": ["下", "下巻", "後編"],
    "notFirstMarkers": ["総集編", "番外編", "外伝"],
    "notFirstPrefixes": ["ex", "extra", "sp"]
  },

  "compare": {
    "ignored": "@list:ignoredInComparison",
    "variants": "@list:variantKanji"
  },

  "partition": { "by": ["circle", "genre"] },

  "markers": {
    "edition": { "words": "@list:editionWords", "patterns": ["[\\p{Han}\\p{Katakana}ー]{1,6}語版"] },
    "source":  { "words": "@list:sourceWords",  "patterns": ["[DＤ][LＬ]版"] }
  },

  "grouping": {
    "compilation":  { "enabled": true, "words": "@list:compilationWords", "singleWhenMainExists": true },
    "volumeHead":   { "enabled": true, "attachSubtitled": true },
    "sharedPrefix": {
      "enabled": true, "minPrefix": 4, "minWholeTitle": 2, "boundaries": "@list:boundaryCharacters",
      "conditions": {
        "reject-hiragana-ending": { "enabled": true },
        "reject-single-script":   { "enabled": true },
        "reject-common-english":  { "enabled": true, "dictionary": "english", "unlessVolume": true }
      }
    },
    "splitByRelation": { "enabled": true, "unlabeled": "joinLargest" },
    "rejectSameWork":  { "enabled": true }
  },

  "naming": {
    "includeClosingBrackets": { "enabled": true, "pairs": "@list:brackets" },
    "includeFollowing":       { "enabled": true, "characters": "@list:keepFollowing" },
    "trimTrailing":           { "enabled": true, "characters": "@list:trimTrailing" },
    "dropLastWord":           { "enabled": true, "words": "@list:labelIntroducers" }
  },

  "volume": {
    "readers": [
      { "id": "ordinal",  "type": "ordinal" },
      { "id": "number",   "type": "number", "prefixes": "@list:volumePrefixes", "counters": "@list:volumeCounters", "mergedSpan": 3 },
      { "id": "kanji",    "type": "kanjiNumber", "counters": "@list:kanjiCounters" },
      { "id": "greek",    "type": "greekLetter" },
      { "id": "roman",    "type": "romanNumeral" },
      { "id": "position", "type": "positionWord", "first": "@list:positionFirst", "middle": "@list:positionMiddle", "last": "@list:positionLast" }
    ],
    "inference": {
      "sharedLeadingKanji": { "enabled": true, "minBooks": 2 },
      "firstVolume": { "enabled": true, "excludeMarkers": "@list:notFirstMarkers", "excludePrefixes": "@list:notFirstPrefixes" }
    }
  },

  "retiredIDs": [],
  "aliases": {}
}
```

- 段階(`compare` → `partition` → `markers` → `grouping` → `naming` → `volume`)と、`grouping`・`naming`・`inference` の中の規則の順は固定。
  キーの名前が規則の ID を兼ねる。
- **`volume.readers` だけは並び順が優先順位**(上から試し、最初に読めたものを採る)。差分の `$order` で並べ替えられ、新しい読み手を足せる。
- 最初の実装では、処理に埋め込んである読み方(`ordinal`・`roman`・`greek` など)は**オン・オフだけ**を外に出す。細かいパラメータは、
  必要になったときに `since` を付けて足す。
- 新しい振る舞いが要るときは、コードに規則を足して `engineLevel` を上げ、既定値に `since` 付きで足す。
- `"dictionary": "english"` は辞書の**名前**。実体は利用側が渡す。渡されていなければ、その条件は働かない(警告)。

## ファイル名のフォーマット(`qoometa.filename-formats`)

```json
{
  "kind": "qoometa.filename-formats",
  "schemaVersion": 2,
  "reservedWords": {
    "@genre":    { "engine": "@mediatype", "field": "genre" },
    "@event":    { "engine": "@event",     "field": "event" },
    "@circle":   { "engine": "@studio",    "field": "circle" },
    "@author":   { "engine": "@author",    "field": "authors", "split": ["、", ",", "，", "&", "＆", "/", "／"] },
    "@title":    { "engine": "@title",     "field": "title" },
    "@relation": { "engine": "@genre",     "field": "relation" },
    "@keywordA": { "engine": "@keyword",   "field": "keyword" }
  },
  "profiles": [
    {
      "id": "doujinshi",
      "delimiters": [["[", "]"], ["(", ")"]],
      "protectedTokens": ["\\((19[0-9]{2})\\)", "\\((20[0-9]{2})\\)", "\\((結|終|完|完結|完全版)\\)"],
      "formats": ["(@genre) [@circle (@author)] @title (@relation) [@keywordA]", "[@circle] @title"]
    }
  ],
  "fallback": { "simpleBrackets": { "enabled": true }, "wholeNameAsTitle": { "enabled": true } }
}
```

- プロファイルは上から試し、最初にどれかのフォーマットが一致したプロファイルを採る。今は同人誌向けの 1 つ。
  商業の単行本・雑誌向けのプロファイルは、規則の中身の課題として足していく(roadmap.md)。
- 差分では、プロファイルを ID で指して `formats` に `$add` / `$remove` / `$replace` を書く。`formats` は順序が意味を持つので、
  `$add` は `{ "$add": [...], "at": "start" | "end" }`(既定は `start`。利用者の形を先に試す)。
- プロファイルに適用の条件を付ける拡張(フォルダごとなど)は後回し。

## 例のファイル(`qoometa.examples`)

```json
{
  "kind": "qoometa.examples",
  "schemaVersion": 2,
  "vocabulary": { "genres": ["種別A", "種別B"] },
  "examples": [
    {
      "id": "compilation-numbered-later",
      "files": ["[架空工房] 月の庭 1", "[架空工房] 月の庭 2", "[架空工房] 月の庭 総集編", "[架空工房] 月の庭 総集編2"],
      "expect": [
        { "series": "月の庭", "volume": "1" },
        { "series": "月の庭", "volume": "2" },
        { "series": "月の庭 総集編", "volume": "1", "inferred": true },
        { "series": "月の庭 総集編", "volume": "2" }
      ],
      "covers": ["compilation", "firstVolume"]
    },
    {
      "id": "same-first-word-is-not-a-series",
      "files": ["(種別A) [架空工房] NEON 夜の街 (作品A)", "(種別A) [架空工房] NEON 朝の港 (作品B)"],
      "expect": [{ "series": null }, { "series": null, "relation": "作品B", "genre": "種別A" }],
      "covers": ["splitByRelation"]
    }
  ]
}
```

- `files` は拡張子を除いたファイル名。フォルダが要る例は `{ "name": "…", "folders": ["…"] }` の形でも書ける。
- `expect` は同じ順の期待値で、**書いた項目だけ**を確かめる。確かめられる項目: `series`・`volume`・`volumeSort`・`inferred`・
  `circle`・`authors`・`title`・`relation`・`genre`・`event`・`editions`・`sources`。
- **`"series": null` は「シリーズに入ってはいけない」**。フィードバックの多くはこの形。
- `vocabulary` はファイル全体の既定で、例ごとに上書きできる(本の種別に依る規則を確かめるため)。
- `covers` は、この例が確かめる規則の ID。規則を止めたときに壊れる例が分かる。
- **例には架空の名前だけを書く。** フィードバックの実例は、api.md「フィードバック」の置き換えの規則に従って架空の名前にしてから足す。
  他人からの寄稿にも同じ約束を求める(CONTRIBUTING に書く)。

## 最初の実装に入れるもの・後回しにするもの

| 入れる | 後回し |
|---|---|
| 包みと `schemaVersion`・`engineLevel`・`since`・`required` | 第 1 版からのマイグレーション(仕組みだけ) |
| 固定の段階と、ID の付いた規則のオン・オフ・パラメータ | 埋め込みの読み方の細かいパラメータ |
| `lists` と `$add`/`$remove`/`$set`/`$unset`/`$replace`、読み手の `$order` | プロファイルの適用の条件 |
| 誤りをすべて集める厳密な検証(近い綴りの候補、`retiredIDs`・`aliases`) | JSON Schema を登録簿から自動で作ること(最初は手で書く) |
| 例のファイルと `rules test` | `rules-bundle` 以外の持ち運びの形 |
| 規則の上限と正規表現の安全性の検査 | |

## 決まったこと(2026-09-19)

- 置き場所はアプリごとに分け、形式は共通にして `rules-bundle` で持ち運べるようにする。
- 書き間違いはエラー、新しい版の規則は飛ばして知らせる(`since` と `engineLevel` で見分ける。`required` なら適用しない)。
- このリポジトリの規則は既定値。利用者の変更は別の JSON(差分)に保存して以降それを使い、初期化で既定値に戻す。
- 例のファイルは、実在しない本の名前だけで書いて公開する。
- 段階は固定。並べ替えられるのは巻の読み手だけ。
- 規則ファイルはパスを指さない。辞書は名前で指し、利用側が渡す。
