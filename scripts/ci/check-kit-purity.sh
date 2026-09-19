#!/bin/bash
# 本体(QooMetaKit と、その内部の QooFormat)が純粋な計算であることを確かめる(docs/api.md「方針」の 1)。
#
# 本体はファイルを読まない・書かない、通信しない、ログを出さない。規則・語彙・辞書は利用側が値で渡す。
# 名前の流出を防ぐ守りでもある(本体が蔵書の名前をどこかへ書く経路を作らない)。ファイルやシステムの資源に
# 触れる処理は QooMetaRules・QooMetaScan・CLI に置く。
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib.sh"

# 見つけたら失敗にする書き方(正規表現。コメントの行は見ない)。
forbidden=(
    'FileManager'
    'FileHandle'
    'URLSession'
    'URLRequest'
    'Bundle\.'
    'Data\(contentsOf'
    'String\(contentsOf'
    'contentsOfFile'
    '\.write\(to'
    'writeToURL'
    '(^|[^A-Za-z_.])print\('
    'debugPrint\('
    'NSLog\('
    'os_log'
    'Logger\('
    'import os($|\.)'
    'import OSLog'
    'import Network'
    'UserDefaults'
    'ProcessInfo'
    'Process\('
)

found=0
for pattern in "${forbidden[@]}"; do
    hits=$(grep -rnE "$pattern" Sources/QooMetaKit Sources/QooFormat --include='*.swift' \
        | grep -vE '^[^:]+:[0-9]+:\s*//' || true)
    if [ -n "$hits" ]; then
        fail "本体に使ってはいけない書き方($pattern):"
        printf '%s\n' "$hits" >&2
        found=1
    fi
done
[ "$found" -eq 0 ] && ok "本体(QooMetaKit・QooFormat)はファイル・通信・ログに触れていない"

finish
