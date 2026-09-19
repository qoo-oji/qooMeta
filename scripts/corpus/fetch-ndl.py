#!/usr/bin/env python3
"""国立国会図書館サーチ(NDL サーチ)の SRU API から、日本のコミック(NDC 726.1)の書誌を集める。

用途: シリーズ判定の規則を、**利用者の蔵書ではなく公開データで**検討するための正解付きデータ
(docs/design.md「公開データでの検討」)。NDL の書誌では、作品名(dc:title)と巻次(dcndl:volume)が
分かれて記録されているので、「同じ作品の巻」の正解として使える。

利用条件(https://ndlsearch.ndl.go.jp/help/api、2026-09-19 確認): 収益の無い個人の利用は申請不要。
同時接続は制限され、継続的な大量アクセスは遮断されうる。**ここでは 1 リクエストずつ、間隔を空けて取る。**
集めたデータはリポジトリの外(既定 ~/Library/Application Support/qooMeta-dev/corpus/)に置く
(再配布の条件をまだ確かめていないため)。

問い合わせには一般的な条件(分類・年)しか使わない。**利用者の蔵書の名前を検索語にしない**(外部への送信になる)。

使い方:
    scripts/corpus/fetch-ndl.py --from-year 2018 --until-year 2026
"""
import argparse
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ENDPOINT = "https://ndlsearch.ndl.go.jp/api/sru"
USER_AGENT = "qooMeta-research/0.1 (personal, non-commercial)"
DEFAULT_OUT = os.path.expanduser("~/Library/Application Support/qooMeta-dev/corpus/ndl-comics.jsonl")
NS = {
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "dc": "http://purl.org/dc/elements/1.1/",
    "dcterms": "http://purl.org/dc/terms/",
    "dcndl": "http://ndl.go.jp/dcndl/terms/",
    "foaf": "http://xmlns.com/foaf/0.1/",
}


def fetch(query: str, start: int, count: int) -> str:
    params = {
        "operation": "searchRetrieve", "version": "1.2", "recordSchema": "dcndl",
        "maximumRecords": str(count), "startRecord": str(start), "query": query,
    }
    req = urllib.request.Request(f"{ENDPOINT}?{urllib.parse.urlencode(params)}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


def text(el, path: str) -> str:
    found = el.find(path, NS)
    return (found.text or "").strip() if found is not None and found.text else ""


def parse_records(xml: str) -> list[dict]:
    out = []
    for raw in re.findall(r"<recordData>(.*?)</recordData>", xml, re.S):
        body = html.unescape(raw) if "&lt;" in raw else raw
        try:
            root = ET.fromstring(body.strip())
        except ET.ParseError:
            continue
        bib = root.find("dcndl:BibResource", NS)
        if bib is None:
            continue
        out.append({
            "id": bib.get(f"{{{NS['rdf']}}}about", ""),
            "fullTitle": text(bib, "dcterms:title"),
            "title": text(bib, "dc:title/rdf:Description/rdf:value"),
            "titleKana": text(bib, "dc:title/rdf:Description/dcndl:transcription"),
            "volume": text(bib, "dcndl:volume/rdf:Description/rdf:value"),
            "label": text(bib, "dcndl:seriesTitle/rdf:Description/rdf:value"),
            "creators": [c.text.strip() for c in bib.findall("dc:creator", NS) if c.text],
            "publisher": text(bib, "dcterms:publisher/foaf:Agent/foaf:name"),
            "issued": text(bib, "dcterms:issued"),
        })
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--from-year", type=int, default=2015)
    p.add_argument("--until-year", type=int, default=2026)
    p.add_argument("--interval", type=float, default=2.0, help="リクエストの間隔(秒)")
    p.add_argument("--out", default=DEFAULT_OUT)
    args = p.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    seen = set()
    total = 0
    with open(args.out, "w", encoding="utf-8") as f:
        # SRU は 1 つの問い合わせで先頭 500 件までしか返さない(startRecord > 500 は
        # "illegal startRecord value")。そのため月ごとに分けて、各月の先頭 500 件を取る。
        for year in range(args.from_year, args.until_year + 1):
            got_year = 0
            for month in range(1, 13):
                ym = f"{year}-{month:02d}"
                query = f'ndc="726.1" AND from="{ym}" AND until="{ym}" AND mediatype="books"'
                records = parse_records(fetch(query, 1, 500))
                for rec in records:
                    if rec["id"] in seen or not rec["title"]:
                        continue
                    seen.add(rec["id"])
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    total += 1
                got_year += len(records)
                time.sleep(args.interval)
            print(f"{year}: {got_year} 件", file=sys.stderr)
    print(f"{total} 件を書き出した: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
