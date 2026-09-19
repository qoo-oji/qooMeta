#!/bin/bash
# scripts/ci/ の検査をすべて走らせる(CI と、手元でコミットの前に)。引数はそれぞれの検査へそのまま渡す
# (手元では `--require-terms --untracked` を付けると、禁止語の一覧でまだ追跡していないファイルも見る)。
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib.sh"

for check in "$script_dir"/check-*.sh; do
    [ "$(basename "$check")" = "check-all.sh" ] && continue
    echo "== $(basename "$check")"
    "$check" "$@" || failures=$((failures + 1))
done

finish
