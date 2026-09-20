# 規則ファイルの説明書

qooMeta の規則は、次の 2 つの JSON(形式の第 2 版)に書かれています。どちらもパッケージに同梱された**既定値**です。

| ファイル | 役割 |
|---|---|
| [`Sources/QooMetaRules/Resources/filename-formats.json`](../Sources/QooMetaRules/Resources/filename-formats.json) | ファイル名を**どう区切り、どこが何の欄か**(サークル・作者・タイトル・ネタ …)を決める |
| [`Sources/QooMetaRules/Resources/series-rules.json`](../Sources/QooMetaRules/Resources/series-rules.json) | 読み取ったタイトルから**シリーズ名と巻**を取り出す |

処理の順は「ファイル名 → (filename-formats.json)→ 欄 → (series-rules.json)→ シリーズと巻」です。
形式の設計と、その理由は [rules-format-design.md](rules-format-design.md) にあります。

## 変え方: 既定値に「変更」を重ねる

既定値は書き換えず、**変えたいところだけを書いた別の JSON(差分)**を重ねます。アプリの更新で既定値が良くなったとき、
触っていない部分にはその改善が届きます。

```json
{
  "kind": "qoometa.series-rules",
  "schemaVersion": 2,
  "base": "builtin",
  "lists": { "labelIntroducers": { "$add": ["arc"] } },
  "grouping": { "sharedPrefix": { "minPrefix": 3 } },
  "volume": { "readers": { "roman": { "enabled": false } } },
  "policies": { "subtitled": "separate" }
}
```

```bash
qoometa rules validate 変更.json              # 誤りと警告をすべて出す(位置と、近い綴りの候補)
qoometa rules show --rules 変更.json          # 重ねた結果と、変更が効いている所
qoometa rules test --rules 変更.json          # 例のファイルで確かめる
qoometa scan <フォルダ> --out … --rules 変更.json   # どのコマンドにも --rules を付けられる
```

| 書き方 | 対象 | 意味 |
|---|---|---|
| 値(数・文字列・真偽) | パラメータ・方針 | 置き換える |
| `{ "$add": [...], "$remove": [...] }` | 語・文字の一覧、正規表現の並び | 足す・外す(足した語は先頭に入る。すでにある語は増えない) |
| `{ "$set": {...}, "$unset": [...] }` | 対応表(異体字・括弧の組) | 足す(置き換える)・外す |
| `{ "$replace": ... }` | 一覧・対応表 | 丸ごと置き換える |
| `"規則の ID": { "enabled": false, パラメータ… }` | 規則 | 止める・パラメータを変える |
| `"$order": ["ID", …]` | 巻の読み手だけ | 挙げた読み手を、この順で先頭に寄せる(挙げなかった読み手は既定の順で後ろに続く) |

- 差分では、一覧を配列のまま書けません(既定の語がすべて消えるため)。置き換えるときは `$replace` と書きます。
- 規則のパラメータが一覧を指している(`"@list:labelIntroducers"`)ときは、語は `lists` の側で変えます。
- `rules-bundle`(`"kind": "qoometa.rules-bundle"`)は、2 つの差分を 1 つにまとめて持ち運ぶ形です:
  `{ "kind": "qoometa.rules-bundle", "schemaVersion": 2, "base": "builtin", "seriesRules": {…}, "filenameFormats": {…} }`。
- エディタの補完と検証には `schema/` の JSON Schema を使えます(`"$schema"` に書く)。

### 読み込みの誤りと警告

| 状況 | 扱い |
|---|---|
| JSON として壊れている、書き間違い(知らないキー・値・一覧)、範囲外の値、危ない正規表現 | **エラー**。すべて集めて、位置と近い綴りの候補を出す。変更は使わない |
| 新しい版の qooMeta で足された規則(`"since"` が本体の水準より大きい) | その規則を飛ばして**警告**。`"required": true` の規則なら、ファイル全体を使わず既定値だけで動く |
| 廃止された規則の ID(既定値の `retiredIDs`) | 無視して**警告** |
| 改名された規則の旧 ID(既定値の `aliases`) | 新しい ID として読む |
| すでに無い語の `$remove`、すでにある語の `$add` | 何もしない |
| 規則が指す辞書が無い | その条件を止めて**警告** |

上限: ファイル 1 MB、一覧 5,000 件、語 100 文字、正規表現 500 文字。正規表現は ICU(NSRegularExpression)の書き方で、
量指定子の付いたグループの中に量指定子か選択肢がある形(`(a+)+`)と後方参照は、指数時間になりうるので使えません。

## 共通の注意

- 同梱の既定値を変えたら、ビルドし直してください(`swift build -c release`)。JSON はビルド時にパッケージへ取り込まれます。
  既定値の全体は `qoometa rules validate <ファイル>` で確かめられます(`"base"` の無いファイルは既定値の全体として確かめる)。
- **蔵書の名前(書名・サークル名・フォルダ名)を書かないでください。** 既定値のファイルは公開リポジトリに含まれます。
  書いてよいのは一般的な語と記号だけです。コミット時の検査(`scripts/ci/check-private-terms.sh`)が、手元の禁止語の一覧と照合します。
- 本の種別の名前(ファイル名の先頭の丸括弧に書く分類)は、蔵書のフォルダ名と同じ語であることが多いので、規則ではなく
  リポジトリの外の `~/Library/Application Support/qooMeta-dev/config.json` の `mediaTypes` に書きます。
- 規則ファイルは、ほかのファイルやパスを指しません。辞書も名前(`"english"`)で指すだけです(macOS の `/usr/share/dict/words`)。
- タイトルどうしの比較と、`labelIntroducers`・`notFirstMarkers`・`notFirstPrefixes` の照合は、全角・半角と大文字・小文字を
  そろえてから行います。版・入手経路の印と巻の読み方の語は、書いたとおりの表記で探します
  (全角の `ＤＬ版` は `markers.source.patterns` の正規表現で受けています)。英字の語は大文字・小文字を区別しません。
- 語の一覧は、長い語から先に照合するよう自動で並べ替えます。書く順は気にしなくてかまいません
  (`formats` と巻の読み手だけは、並びが優先順位です)。
- 変えたあとは、次で結果を確かめてください。
  - `qoometa rules test` — 例のファイル(`Sources/QooMetaRules/Resources/examples.json`、架空の名前)。
    規則を変える前に、確かめたい形をここへ足す(CONTRIBUTING.md)
  - `swift test` — 合成した名前での単体テスト(例のファイルも走る)
  - `qoometa scan …` → `qoometa stats …` — 手元の蔵書での集計(名前は出ません)。最後の行の「結果の指紋」は、
    本ごとの解析結果・シリーズ・巻と組の中身から作ったハッシュで、変更の前後で同じなら結果は 1 冊も変わっていません
  - `qoometa evaluate --corpus …` — 公開データでの採点(README「公開データでの検討」)

## 包み(どちらのファイルにも共通)

| キー | 意味 |
|---|---|
| `$schema` | エディタの補完・検証用(任意。読み込みには使わない) |
| `kind` | `qoometa.filename-formats` / `qoometa.series-rules` / `qoometa.examples` / `qoometa.rules-bundle` |
| `schemaVersion` | 形式の版。今は `2` |
| `revision` | 中身の改訂の印(任意。日付など) |
| `base` | 差分にだけ書く。値は `"builtin"` だけ(パスや URL は書けない) |
| `retiredIDs` / `aliases` | 既定値にだけ書く。廃止した規則の ID と、改名した規則の旧 ID → 新 ID |

規則・パラメータ・一覧には `"since": 番号` を書けます(その番号の水準の qooMeta から働く)。今の水準は `1` です。

---

## 1. filename-formats.json(第 5 版)

ファイル名(拡張子を除いたもの)を、**型**に当てはめて欄に分けます。型は上から試し、**名前全体に当てはまった最初の型**で読みます。
フォルダ名は読みません。

```
(種別A) [架空工房 (山田太郎)] 月の庭 2 (作品A) [DL版]
  ↓ "(@genre) [@author (@author)] @title (@source) [@info]"
@genre = 種別A   @author = 架空工房, 山田太郎   @title = 月の庭 2   @source = 作品A   @info = DL版
```

| キー | 意味 |
|---|---|
| `defaultPreset` | 本がプリセットを選ばなかったときに使う名前(同梱は `mixed`) |
| `presets` | 名前を付けた型の並び。同梱は `mixed`(総合。26 通り)・`doujinshi`(同人誌。16 通り)・`doujinshi-event`(先頭がイベント。16 通り)・`commercial`(商業誌。10 通り)。差分で新しい名前のプリセットを足せます |
| `separators` | 著者の値を分ける文字列(既定は `,` `，` `、`)。並びの欄は著者だけ |
| `defaults` | 名前に書かれていない欄(ジャンル・イベント・原作・情報)に入れる値 |
| `plain` | **型として読まない文字列**(`words` と `patterns`)。名前の中のこの部分は、括弧でも型の括弧として読まず、値にはそのまま残します。同梱の既定は丸括弧の中の西暦(`月の庭 (2026)` の `(2026)` を原作や巻数にしない)。ファイル全体・プリセット・型に書けて、足し合わさります |

**`separators` と `defaults` は、ファイル全体・プリセット・型の 3 か所に書けて、内側に書いたものが勝ちます**
(型 > プリセット > ファイル全体)。`separators` は書いた所で丸ごと置き換わり(足し合わせません)、`defaults` は欄ごとです。
名前から読めた値は、どの既定よりも強いです。型に添えるときは、型をオブジェクトで書きます:
`{ "format": "@series (@volume) - @author", "separators": ["×"] }`。プリセットには `label`(見出し)と `note`(説明)も書けます(同梱のプリセットは書いていません。アプリが利用者の言語で見出しを出すためです)。
詳しくは [filename-format.md](filename-format.md) の 4。

**本ごとにプリセットを選べます。** 商業誌と同人誌がフォルダで分かれている蔵書のために、利用側(アプリ・CLI)が
フォルダごとに割り当てます(2026-09-20、利用者の指示)。CLI では `--presets <割り当て.json>`:
`{ "default": "commercial", "folders": { "相対パス": "doujinshi" } }`。**蔵書のフォルダ名を含むので、リポジトリの外に置きます。**

### 予約語

| 予約語 | 欄 | 意味 |
|---|---|---|
| `@title` | タイトル | シリーズ名と巻数は、ふつうここから規則で導く |
| `@author` | 著者(並び) | 1 つの型に何度でも書ける。値は `separators` で分ける |
| `@genre` | ジャンル | 先頭の丸括弧に使うことが多い |
| `@event` | イベント | 頒布会の名前。同梱の型は使わない |
| `@source` | 原作 | 二次創作の元の作品。同人誌のプリセットでは末尾の丸括弧 |
| `@info` | 情報 | ほかの欄のどれでもない部分(付記)。同梱の型では末尾の角括弧 |
| `@series` | シリーズ | 名前にはっきり書いてあるときだけ。読んだ値は、利用者が確定した値と同じ扱い |
| `@volume` | 巻数(表示用) | **数字だけの値に当たる**(全角の数字は半角に畳む)。商業誌のプリセットでは末尾の丸括弧 |
| `@ignore` | (捨てる) | 何度でも書ける。同梱の型は使わない |

型の書き方:

- 予約語以外の文字(括弧・空白・その他の文字)は、そのまま照合します。空白は「0 文字以上の空白」です。
- 全角と半角の括弧は同じとみなします(`（）` と `()`、`［］` と `[]`)。全角の数字も `@volume` のために半角に畳みます。
- 括弧の中に書いた欄の値には、その括弧の対の文字は入りません。括弧の外の `@title` には何でも入ります。
- 欄は長く取るほうを先に試します(区切りが何度も現れる名前は、最後のもので分ける)。
- 隣り合う 2 つの欄(`@title @author` のように区切りの文字が無いもの)は書けません。型には `@title` か `@series` が要ります
  (`@title` の無い型で読んだ本のタイトルは、型の `@series (@volume)` の部分に値をはめた「月の庭 (3)」になり、シリーズと巻はタイトルから導かず、読んだ値をそのまま使います)。
- **欄の多い形を先に、少ない形を後に**書いてください(`… @title` を `… @title (@source)` より先に書くと、末尾の丸括弧まで
  タイトルに入ります)。
- 差分では `"presets": { "mixed": { "formats": { "$add": ["@title - @author"], "at": "end" } } }` のように、プリセットの名前で指します。
  同梱に無い名前を書くと新しいプリセットになります(全体を書く: `{ "my-shelf": { "formats": ["…"] } }`)。
- 書き間違い(知らない予約語など)は、読み込みのときに位置付き(`presets.mixed.formats[0]`)の誤りになります。

---

## 2. series-rules.json

`@title` から、シリーズ名と巻を取り出します。処理の段階は固定で、JSON の構造がそのまま段階を表します
(段階の順や、段階をまたぐ規則の移動はできません)。**配列で書いてある所(`markers` と `volume.readers`)は並び順が優先順位で、
並べ替えられます**(上から試し、先に当たった規則が勝つ)。オブジェクトで書いてある所は、書いてある順に働き、並べ替えられません。

1. **比べる単位**: 同じサークル(無ければフォルダ)で、本の種別(`@genre`)が同じ本どうしだけを比べます(方針 `differentGenre`)。
2. **`compare`**: 比べるための形(全角・半角、大文字・小文字、飾りの記号、異体字をそろえる)。
3. **`markers`**: タイトルの中の「役目のある語」(版・入手経路の印、総集編の語)を見つけます。**並び順が優先順位**です。
4. **`grouping`**: 組を作ります。1 段目 `volumeHead`(「タイトル + 巻」を頭でまとめる)、2 段目 `sharedPrefix`(先頭の共通部分)、
   総集編 `compilation`、組にしない例外(`conditions`、ネタ違い、版違いだけ)。
5. **`naming`**: 共通部分を元の表記に戻し、シリーズ名を整えます。
6. **`volume`**: シリーズ名より後ろの部分から巻を読み、1 巻の推定などを行います。

### `lists` — 語と文字の一覧

規則は一覧を `"@list:名前"` で指します。1 つの一覧を複数の規則が使うこともあります(`volumePrefixes` は数字と漢数字の読み手が使う)。

| 一覧 | 中身 | 使うところ |
|---|---|---|
| `ignoredInComparison` | 文字 | 比べるときに無視する文字(空白と、タイトルの飾りによく使う記号)。長音記号「ー」は入れない(語の一部) |
| `variantKanji` | 対応表 | 比べるときに同じ字とみなす異体字(`"凜": "凛"`)。書き出す表記は変えない |
| `boundaryCharacters` | 文字 | 語の切れ目とみなす記号。空白と数字は常に切れ目 |
| `trimTrailing` | 文字 | シリーズ名の**末尾**から落とす記号(先頭は落とさない)。巻の前の区切りとしても使う |
| `keepFollowing` | 文字 | 共通部分のすぐ後ろにあれば、シリーズ名に含める文字(`月の庭！` の `！`) |
| `brackets` | 対応表 | 閉じ括弧 → 開き括弧 |
| `labelIntroducers` | 語 | シリーズ名の最後の 1 語がこの語なら外す(`X side A` と `X side B` のシリーズ名は `X`) |
| `editionWords` / `sourceWords` | 語 | 版の印 / 入手経路の印 |
| `compilationWords` | 語 | 総集編を示す語 |
| `volumePrefixes` | 語 | 巻の番号の前に付く語(`vol` `第` `その` …)。英字の語は後ろの `.` も受け付ける(`Vol.3`) |
| `volumeCounters` | 語 | 巻の番号の後ろに付く単位(`巻` `話` `号` `月号` `弾` `つめ` …) |
| `wholeOnlyCounters` | 語 | 「残りが巻だけか」を見るときにだけ使う単位(既定は `集`) |
| `kanjiCounters` | 語 | 漢数字の後ろに付く単位(`一巻` `三話`) |
| `positionFirst` / `positionMiddle` / `positionLast` | 語 | 上・前編 … / 中・中編 … / 下・後編 … |
| `notFirstMarkers` | 語 | シリーズ名より後ろにこの語がある本は、1 巻の推定の候補にしない |
| `notFirstPrefixes` | 語 | シリーズ名のすぐ後ろにこの語が付く本も、同じく候補にしない(`Xex` `X SP`) |

### `policies` — 方針(好み)

見分けた結果を**どう扱うか**。正解が 1 つあるわけではないので、好みで選びます。太字が既定(今の扱い)。

| 方針 | 値 | 意味 |
|---|---|---|
| `subtitled` | **`attach`** / `separate` | 副題付きの本(`X 〇〇編`)を、巻でまとめた `X` の組に入れる / 入れない |
| `differentRelation` | **`split`** / `keep` | ネタ(`@relation`)が違う本を別のシリーズに分ける(ネタの無い本はいちばん大きい組へ)/ 分けない |
| `differentGenre` | **`split`** / `keep` | 本の種別(`@genre`)が違う本を別のシリーズにする / 同じシリーズにしてよい |
| `unnumberedFirst` | **`inferFirst`** / `leaveEmpty` | 番号の無い 1 冊を 1 巻とみなす / みなさない |
| `editions` | **`sameWork`** / `separateBooks` / `ignore` | 版違いを同じ作品の別の版とみなす / 別の本として数える / 印を見分けない |
| `sources` | **`sameWork`** / `separateBooks` / `ignore` | 入手経路違い。同上 |
| `compilations` | **`ownSeries`** / `inMainSeries` / `notInSeries` | 総集編を `X 総集編` という別のシリーズにする / 本編に含める / どのシリーズにも入れない |
| `compilationVolume` | **`none`** / `afterRange` | (`inMainSeries` のとき)本編の中での総集編の巻 |
| `magazines` | **`perYear`** / `whole` | 雑誌を 1 年ぶんごとのシリーズにする / 雑誌全体で 1 つのシリーズにする |

- どの方針を選んでも、見分けた印(版・入手経路)は本ごとに付きます。
- `editions` / `sources` の `separateBooks`: 印を除かずに比べるので、`X` と `X【フルカラー版】` は `X` のシリーズの 2 冊になります
  (版違いの巻は、元の本と同じ巻)。`ignore` は印を見分けないので、`X【フルカラー版】` はふつうの副題付きの本として扱われます。
- `compilations` の `inMainSeries`: 同じ書き手に本編のシリーズ `X` があれば、総集編をそこへ入れます。本編が無ければ、既定と同じく
  `X 総集編` のシリーズにします。`compilationVolume` の `afterRange` では、収録範囲が読めた総集編の巻を、その最後の巻の直後に
  します(`X1~4総集編` の巻は表記 `総集編 1~4`、数 4.5)。範囲が読めない総集編には巻を付けません(並びは末尾)。
- `magazines` の `whole`: 年と号を巻として読みます(`2025年36-37号` `2011年10・11月号` `2022 Vol.01` `2022-01`)。
  巻の表記は年と号のまま、並べ替え用の数は 年 × 100 + 号(`2025年36-37号` は 202536)。
- 例のファイルでは、例ごとに `"policies": { … }` を書いて、その方針での結果を確かめられます。

### `compare` — 比べ方

| キー | 既定 | 意味 |
|---|---|---|
| `ignored` | `@list:ignoredInComparison` | 比べるときに無視する文字 |
| `variants` | `@list:variantKanji` | 同じ字とみなす異体字 |
| `boundaries` | `@list:boundaryCharacters` | 語の切れ目とみなす記号 |

### `markers` — 語の規則(版・入手経路の印、総集編の語、そのまま読む語)

タイトルの中の「役目のある語」を見つける規則の**並び**です。決まりは 1 つだけです:

> **上の規則から順に語を探し、上の規則が取った所には、下の規則は反応しない。**

ファイアウォールの規則表や `.gitignore`、メールの振り分けと同じ「先に当たった規則が勝つ」仕組みです。だから**例外は、
特別な仕組みではなく「守りたい規則より上に置いた、何もしない規則」**として書きます。

| 規則(同梱の順) | `treat` | 意味 |
|---|---|---|
| `plain` | `keep` | **そのまま読む語**。何もしない(下の規則と、後ろの段階の**巻の読み手**から語を守る。題名が「No.5」の本は、ここに足せば巻 5 になりません)。同梱は「フルカラー総集編」など: 独立した 1 冊で、版違いでも総集編でもない |
| `edition` | `edition` | 版の印(下) |
| `source` | `source` | 入手経路の印(下) |
| `compilationMark` | `compilation` | 総集編の語(`総集編` `番外編` …)。置き場所は方針 `compilations`、組み方は `grouping.compilation` |
| `standalone` | `standalone` | **シリーズに入れない語**。この語のある本は、どのシリーズにも入れません(一覧で「シリーズに入れない」と直した本と同じ扱い)。**同梱の一覧 `standaloneWords` は空**で、使う人が足します |

どの規則も `words`(語の一覧)と `patterns`(正規表現)、`enabled` を持ちます。`treat` は規則の扱いで、`keep` /
`edition` / `source` / `compilation` / `standalone` から選びます。

**「この本はシリーズに入れない」を規則で書く**には、`standaloneWords` に語を足します。種類ごと外すなら種類の語
(`設定資料集`)、1 冊だけ外すならその本の題名をそのまま書きます。例外は、ここでも「上に置いたそのまま読む語」です
(`設定資料集つき` を `plainWords` に足せば、その本はシリーズに残ります)。利用者や型(`@series`)がシリーズを決めた本には効きません。

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "lists": { "standaloneWords": { "$add": ["設定資料集"] }, "plainWords": { "$add": ["設定資料集つき"] } } }
```

差分では、規則を ID で指します。**同梱に無い ID を書くと、新しい規則になります**(要るのは `treat`。並びの先頭に入ります)。
位置を変えるなら `$order`(挙げた ID を、この順で先頭に寄せる)。

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "lists": { "plainWords": { "$add": ["完全版ガイド"] } } }
```

↑「完全版ガイド」の「完全版」を版の印にしない(同梱の「そのまま読む語」に足すだけ)。総集編としては読ませたいが、版の印に
だけはしたくない、というように**順番のあいだに入れたい**ときは、新しい規則を足して位置を決めます:

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "markers": {
    "my-exceptions": { "treat": "keep", "words": ["新装版画集"] },
    "$order": ["plain", "compilationMark", "my-exceptions"]
  } }
```

#### 版と入手経路の印

タイトルの中の印です。**比べるときは印を除いたタイトルを使い、印を除いて同じタイトルになる本は同じ作品とみなします。
同じ作品だけの組はシリーズにしません**(規則 `grouping.rejectSameWork`)。シリーズの中の版違い(`X 3【フルカラー版】`)は、
元の本と同じ巻になります。

| 規則 | パラメータ | 意味 |
|---|---|---|
| `edition` | `words`、`patterns`(既定は `〇〇語版`) | **版**: 内容(色・収録内容・修正・言語など)が違う同じ作品。CSV の「版」、Stackroom XML の `Keyword C` |
| `source` | `words`、`patterns`(既定は `DL版`。全角も) | **入手経路**: 内容は同一で、手に入れた経路だけが違う。CSV の「入手元」 |

印は、`【】` `[]` `()` に入っていても、空白の後ろに付いていても見つけます。ただし、ファイル名の末尾の丸括弧・角括弧は
先にネタ・キーワードとして読まれるので、そこにある印は見分けられません。特装版・通常版は、付録の違いだけで本体は同じなので
入手経路に入れています。規則を止める(`"enabled": false`)と、その印を見分けません。

### `grouping` — 組の作り方と例外

| 規則 | パラメータ(既定) | 意味 |
|---|---|---|
| `compilation` | `singleWhenMainExists`(true)、`volumeOffset`(100) | 総集編(語は `markers` の `compilationMark`)を本編とは別の `X 総集編` のシリーズにする。2 冊以上か、同じ書き手に本編のシリーズ `X` があれば(`singleWhenMainExists`)1 冊でもシリーズにする |
| `volumeHead` | — | 1 段目: 「タイトル + 巻」の形の本を、巻を除いた頭でまとめる。後ろが巻だけなので頭は 1 文字でもよい |
| `sharedPrefix` | `minPrefix`(4)、`minWholeTitle`(2) | 2 段目: 残りを先頭の共通部分でまとめる。共通部分が**語の途中で**切れるときは `minPrefix` 文字以上、片方のタイトル全体がもう片方の先頭と一致するとき(`XY` と `XY2`)は `minWholeTitle` 文字以上 |
| `sharedPrefix.conditions.reject-hiragana-ending` | — | 語の途中で切れる共通部分が、ひらがな(助詞など)で終わるなら組にしない |
| `sharedPrefix.conditions.reject-single-script` | — | 語の途中で切れる共通部分が 1 種類の文字だけ(カタカナだけ、漢字だけ …)なら組にしない |
| `sharedPrefix.conditions.reject-common-english` | `dictionary`(`english`)、`unlessVolume`(true) | 2 冊とも一般的な英単語だけでできたタイトルなら組にしない。`unlessVolume` なら、後ろに巻があれば組にする |
| `splitByRelation` | — | ネタが違う本を分ける(働くかどうかは方針 `differentRelation`) |
| `rejectSameWork` | — | 版違い・入手経路違いだけの組はシリーズにしない |

- 総集編は番号の有無で分け方を変えません(番号の無い最初の総集編のあとに `総集編2` が出ることがあるため)。
  総集編の語の前に書かれた範囲(`X1~4総集編`)は、`X 総集編` の巻 `1~4` として読みます。
- 規則を 1 つずつ止めて(`"enabled": false`)、`qoometa evaluate` や手元の集計で効き目を比べられます。

### `naming` — シリーズ名の整え方

| 規則 | パラメータ | 意味 |
|---|---|---|
| `includeClosingBrackets` | `pairs` | シリーズ名に開いたままの括弧があれば、すぐ後ろの閉じ括弧まで含める(`【X】`) |
| `includeFollowing` | `characters` | 共通部分のすぐ後ろの `!` `?` をシリーズ名に含める |
| `trimTrailing` | `characters` | シリーズ名の末尾の区切り記号を落とす |
| `dropLastWord` | `words` | シリーズ名の最後の 1 語が、後ろに付く名前を導く語(`side` `part` …)なら外す |

### `volume` — 巻の読み方

巻は、表記(文字列。`36-37` や `上` もそのまま)と、並べ替え用の数に分けて持ちます。

#### `readers` — 巻の読み手

**並びが優先順位**です(上から試し、最初に読めたものを採る)。差分では ID で指して止め(`"enabled": false`)、`$order` で並べ替えます。

| ID | 種類 | パラメータ | 読む形 |
|---|---|---|---|
| `ordinal` | `ordinal` | — | `第` + 数字 + 任意の漢字 1 字(`第1幕` `第三部`)、分冊(`第04-1章` → 4.1) |
| `number` | `number` | `prefixes`、`counters`、`wholeOnlyCounters`、`mergedSpan`(3) | 数字(`2` `Vol.3` `第5話` `2つめ`)。`36-37` は、後ろの数が前より大きく差が `mergedSpan` 以下のときだけ合併号(範囲)として読む(`2021-01` のような年月は範囲にならない) |
| `kanji` | `kanjiNumber` | `prefixes`、`counters` | 漢数字(`その二` `第三話`)。大字(壱弐参 …)と百・千も。`counters` の単位か、`prefixes` のうち日本語の語(`第` `その` …)が前に付くときだけ |
| `greek` | `greekLetter` | — | ギリシャ文字(`α` = 1) |
| `roman` | `romanNumeral` | — | ローマ数字(大文字、1〜39) |
| `position` | `positionWord` | `first`、`middle`、`last` | 上・中・下、前編・中編・後編。シリーズに `middle` の語があれば 上1・中2・下3、無ければ 上1・下2。`後編1` のような番号付きは 3.1 |

このほか、次の読み方は処理に組み込まれています。

- 雑誌の号(`2025年36-37号` `2011年03月号` `2022 Vol.01`)。年はシリーズ名に残し、1 年ぶんを 1 シリーズにする(方針 `magazines`)
- 末尾の丸括弧が数字だけ(`X (12)`)なら、ネタではなく巻として読む

#### `inference` — 推定

| 規則 | パラメータ(既定) | 意味 |
|---|---|---|
| `sharedLeadingKanji` | `minBooks`(2) | 漢数字で始まるだけの形(`二〇` `三〇`)は、同じシリーズで巻の読めない本が `minBooks` 冊以上、違う漢数字で始まるときだけ読む |
| `firstVolume` | `excludeMarkers`、`excludePrefixes` | 番号の無い 1 冊を 1 巻とみなす(方針 `unnumberedFirst`)。この語がある本は候補にしない |

---

## 変更の例

**区切り語を足す**(`X arc A` と `X arc B` を `X` にまとめたい):

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "lists": { "labelIntroducers": { "$add": ["arc"] } } }
```

**版の印を足し、既定の印を外す**:

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "lists": { "editionWords": { "$add": ["初版"], "$remove": ["旧版", "新版"] } } }
```

**ローマ数字を巻として読まない**:

```json
{ "kind": "qoometa.series-rules", "schemaVersion": 2, "base": "builtin",
  "volume": { "readers": { "roman": { "enabled": false } } } }
```

**フォーマットを足す**(利用者の形を先に試す。この型だけ `×` でも著者を分ける):

```json
{ "kind": "qoometa.filename-formats", "schemaVersion": 5, "base": "builtin",
  "presets": { "commercial": { "formats": { "$add": [
    { "format": "@title 第@volume巻 - @author", "separators": [",", "×"] }
  ] } } } }
```
