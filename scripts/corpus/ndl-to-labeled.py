#!/usr/bin/env python3
"""fetch-ndl.py の書誌を、qoometa evaluate の入力(1 行 1 冊: author / title / series)へ変える。

- author: 最初の著者名(「著」「作」「画」などの役割表示を除く)。編者だけの本(アンソロジー)は除く。
- title: ファイル名のタイトル部分に当たる文字列。作品名 + 空白 + 巻次(巻次があれば)。
- series: 正解のシリーズ名 = NDL の作品名(dc:title)。

使い方:
    scripts/corpus/ndl-to-labeled.py [入力.jsonl] [出力.jsonl]
"""
from __future__ import annotations
import json
import os
import re
import sys

BASE = os.path.expanduser("~/Library/Application Support/qooMeta-dev/corpus")
ROLE = re.compile(r"\s*(著|作|画|漫画|作画|原作|まんが|マンガ|絵|作・画|原案|キャラクター原案|構成|脚本|ストーリー|監修|編|編集|編著|訳|翻訳)$")
EDITOR_ONLY = re.compile(r"(編|編集|編著|監修)$")


def author_of(creators: list[str]) -> str | None:
    if not creators:
        return None
    first = creators[0].split(",")[0].split("、")[0].strip()
    if EDITOR_ONLY.search(first):
        return None
    name = ROLE.sub("", first).strip()
    return name or None


def main() -> int:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BASE, "ndl-comics.jsonl")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(BASE, "ndl-labeled.jsonl")
    kept = skipped = 0
    with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as out:
        for line in f:
            rec = json.loads(line)
            author = author_of(rec.get("creators", []))
            series = rec.get("title", "").strip()
            if not author or not series:
                skipped += 1
                continue
            volume = rec.get("volume", "").strip()
            title = f"{series} {volume}" if volume else series
            out.write(json.dumps({"author": author, "title": title, "series": series}, ensure_ascii=False) + "\n")
            kept += 1
    print(f"{kept} 冊を書き出した(除外 {skipped}): {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
