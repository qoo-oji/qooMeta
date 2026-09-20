import Foundation

/// 利用者が書いた正規表現の、走らせずに分かる危うさ。
///
/// 本当の守りは照合の時間の上限(実行時に打ち切る)で、こちらは**書いた時点で気づける**ようにするためのもの。
/// だから拒否ではなく、規則の読み込みの誤り・警告として返す材料にする。
enum PatternSafety {
    enum Finding: Sendable, Hashable {
        /// 量指定子の付いたグループが、中に量指定子か選択肢を含む(`(a+)+`)。指数時間になる必要条件。
        case quantifiedGroup
        /// 後方参照(`\1`)。指数時間になりうるうえ、規則の用途では使い道が無い。
        case backreference
    }

    /// 走らせずに分かることだけを見る。読み込みのたびに呼んでよい。
    static func findings(_ pattern: String) -> [Finding] {
        var findings: [Finding] = []
        if hasQuantifiedGroup(pattern) { findings.append(.quantifiedGroup) }
        if hasBackreference(pattern) { findings.append(.backreference) }
        return findings
    }

    /// 量指定子(`*` `+` `{n,}`)の付いたグループの中に、量指定子か選択肢(`|`)があるか。
    static func hasQuantifiedGroup(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var openings: [Int] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" {  // 文字クラスの中の記号は量指定子ではない。
                i += 1
                while i < chars.count, chars[i] != "]" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == "(" { openings.append(i) }
            if c == ")", let open = openings.popLast() {
                let inner = Array(chars[(open + 1)..<i])
                if quantifierFollows(chars, after: i), containsQuantifierOrAlternation(inner) { return true }
            }
            i += 1
        }
        return false
    }

    /// 閉じ括弧の直後が量指定子か(`?` は指数時間の形にはならないので数えない)。
    static func quantifierFollows(_ chars: [Character], after close: Int) -> Bool {
        let next = close + 1
        guard next < chars.count else { return false }
        switch chars[next] {
        case "*", "+": return true
        case "{":
            // `{n,}` `{n,m}` は繰り返し。`{n}` も入れ子になれば同じ形になる。
            var j = next + 1
            while j < chars.count, chars[j] != "}" { j += 1 }
            return j < chars.count
        default: return false
        }
    }

    static func containsQuantifierOrAlternation(_ inner: [Character]) -> Bool {
        var i = 0
        while i < inner.count {
            let c = inner[i]
            if c == "\\" { i += 2; continue }
            if c == "[" {
                i += 1
                while i < inner.count, inner[i] != "]" {
                    if inner[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == "*" || c == "+" || c == "|" || c == "{" { return true }
            i += 1
        }
        return false
    }

    /// 後方参照(`\1`〜`\9`、`\k<name>`)。
    static func hasBackreference(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var i = 0
        while i < chars.count - 1 {
            if chars[i] == "\\" {
                let next = chars[i + 1]
                if next.isNumber, next != "0" { return true }
                if next == "k" { return true }
                i += 2
                continue
            }
            i += 1
        }
        return false
    }
}
