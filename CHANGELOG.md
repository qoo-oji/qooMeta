# Changelog

このプロジェクトの主な変更を記録します。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、版の付け方は
[Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

## [0.2.0] - 2026-09-22

### Added

- 巻数(ソート用)を確定できるようにした(`ConfirmedFields.volumeSort`)。確定した数は、表記から読んだ数・推定した数より優先し、
  シリーズの中の並びにも効く。巻の表記を変える操作(連番・巻を消す)は、確定した数を外す。

### Fixed

- シリーズ名の表記(空白・記号・全角半角など)だけを直した本が、同じ単位のほかの本の表記に戻って提案されていたのを直した。
  名前を確定した本のシリーズ名は、確定した表記のまま出る。

## [0.1.0] - 2026-09-21

### Added

- 初回リリース。

[Unreleased]: https://github.com/qoo-oji/qooMeta/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/qoo-oji/qooMeta/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/qoo-oji/qooMeta/releases/tag/v0.1.0
