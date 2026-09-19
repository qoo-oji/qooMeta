# QooFormat

qooLibrary(同じ作者のリポジトリ)の**ファイル名フォーマット処理**を写したもの。2026-09-19、qooLibrary の
`99cb3ae` から写した。qooLibrary の `Sources/` は MIT License(Copyright (c) 2026 Kosuke Nishimura)で、
写したファイルにも同じ条件が及ぶ(このリポジトリの LICENSE を参照)。

## 写したファイル(qooLibrary の `Sources/QooKit/` からの相対パス)

- `Format/`: Delimiters, FieldRef, FilenameParser, FormatCompileError, FormatCompiler, FormatLexer, FormatMatcher,
  FormatNode, ParseInput, ParseResult, ProtectedToken, ProtectedTokenMasker, RegexSafety, VolumeValue
- `Text/`: CharacterCanonicalization, FoldedSubject, NormalizedString, SafeRegex, TextNormalizer, Whitespace, WidthFolding
- `Volume/`: DateMatcher, LegacyVolumeNotation, VolumeMatcher, VolumePattern

## 変えたところ

- `FormatCompileError.swift`: 画面の文言への準拠(`UserPresentableError`)を外した。qooMeta はフォーマットを
  利用者に編集させないので要らない。
- `QooMetaShims.swift`(qooMeta で書いたもの): 写したファイルが参照する qooLibrary 側の型の最小限の代わり
  (`AppLimits.Format` の値、地域化文字列、`LibrarySettingsSnapshot` の照合に要る部分)。
- `FieldRef.swift` と `VolumeMatcher.swift`: コメントの例に出てくる本の種別の名前を `〈本の種別〉` に置き換えた
  (蔵書のフォルダ名と同じ語で、このリポジトリの禁止語の検査に当たるため)。コードは変えていない。
- ほかのファイルは手を入れていない。qooLibrary 側で直したときは、同じファイルを写し直す。

## 写していないもの

プリセットの定義(`Resources/Templates/library-types.json`)。本の種別の名前を含み、それが蔵書のフォルダ名と
同じ語なので、このリポジトリに置けない。フォーマットは `QooMetaKit/QooLibraryNameParser.swift` に写し、
本の種別の語彙は利用者の設定(リポジトリの外の `config.json`)から渡す。
