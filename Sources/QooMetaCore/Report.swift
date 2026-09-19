import CryptoKit
import Foundation

/// 集計だけの報告(名前を含まない)。CLI が標準出力へ出すのはこれだけ。
///
/// 標準出力はターミナルの記録や AI との会話へ写りうるので、名前を出さない
/// (qooViewer の check-private-terms.py と同じ考え方)。名前を見るのは手元で開く HTML の見直し表だけ。
public enum StatsReport {
    public static func lines(_ doc: ProposalDocument, engine: RuleEngine = .builtin) -> [String] {
        let books = doc.books
        let grouped = doc.groups
        let judged = grouped.filter { $0.aiVerdict != nil }
        let accepted = judged.filter { $0.aiVerdict!.isSeries }
        let renamed = accepted.filter {
            engine.text.key($0.aiVerdict!.seriesName) != engine.text.key($0.ruleName)
        }
        let excluded = accepted.reduce(0) { $0 + $1.aiVerdict!.excludedIDs.count }
        let seconds = judged.reduce(0.0) { $0 + $1.aiVerdict!.seconds }
        let confidences = Dictionary(grouping: accepted, by: { $0.aiVerdict!.confidence.rawValue }).mapValues(\.count)
        let withSeries = books.filter { !$0.series.isEmpty }
        let withVolume = books.filter { !$0.volumeText.isEmpty }
        let numericVolume = books.filter { $0.volumeNumber != nil }
        let circles = Set(books.map(\.circleKey)).count
        let sizes = grouped.map(\.memberIDs.count)
        func ratio(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.1f%%", Double(n) * 100 / Double(d)) }
        var lines = [
            "本: \(books.count)(名前の形に当てはまった: \(books.filter(\.parsed.matchedPattern).count)、書き手: \(circles))",
            "シリーズ候補: \(grouped.count) 組 / \(sizes.reduce(0, +)) 冊(組の大きさ 最大 \(sizes.max() ?? 0)、2 冊の組 \(sizes.filter { $0 == 2 }.count))",
            "  語の切れ目で切れている: \(grouped.filter(\.cleanBoundary).count) 組",
            "  前半部分が 3 人以上の書き手に現れる(ありふれた言葉の疑い): \(grouped.filter { $0.circlesSharingPrefix >= 3 }.count) 組",
        ]
        if !judged.isEmpty || grouped.contains(where: { $0.aiError != nil }) {
            lines += [
                "端末内モデルの判定: \(judged.count) 組(判定できなかった: \(grouped.filter { $0.aiError != nil }.count) 組)",
                "  シリーズと判定: \(accepted.count)(\(ratio(accepted.count, judged.count)))、確からしさ \(confidences)",
                "  名前を規則から変えた: \(renamed.count) 組、外した本: \(excluded) 冊",
                String(format: "  所要時間: 合計 %.0f 秒、1 組あたり %.1f 秒", seconds, judged.isEmpty ? 0 : seconds / Double(judged.count)),
            ]
        }
        lines += [
            "最終: シリーズ付き \(withSeries.count) 冊(\(ratio(withSeries.count, books.count)))、巻あり \(withVolume.count) 冊(数値 \(numericVolume.count)、うち 1 巻と推定 \(books.filter { $0.volumeInferred == true }.count))",
            "結果の指紋: \(ResultFingerprint.of(doc))",
        ]
        return lines
    }
}

/// 結果の指紋。規則や処理を「結果を変えないつもりで」移し替えるとき、前後で本と組の中身が 1 冊も変わっていないことを、
/// 名前を出さずに確かめる(docs/roadmap.md「進め方の約束」)。出力するのはハッシュだけ。
///
/// 含めるもの: 本ごとの名前の解析結果・シリーズ・巻と、同じ組に入った本の集まり。組の番号や作った日時のような、
/// 中身が同じでも変わりうる値は含めない。
public enum ResultFingerprint {
    public static func of(_ doc: ProposalDocument) -> String {
        let books = doc.books.sorted { $0.file.relativePath < $1.file.relativePath }
        let pathByID = Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, $0.file.relativePath) })
        var lines = books.map { b in
            let p = b.parsed
            return [b.file.relativePath, p.circle, p.authors.joined(separator: "\u{1}"), p.title, p.trailing,
                    p.mediaType ?? "", p.event ?? "", p.keyword ?? "", (p.editions ?? []).joined(separator: "\u{1}"),
                    (p.sources ?? []).joined(separator: "\u{1}"), b.series, b.volumeText,
                    b.volumeNumber.map { String($0) } ?? "", b.volumeInferred == true ? "推定" : ""]
                .joined(separator: "\u{2}")
        }
        // 組は、入った本のパスの集まりで表す(組の番号には依らない)。
        let members = Dictionary(grouping: doc.books.filter { $0.groupID != nil }, by: { $0.groupID! })
        lines += members.values.map { "組\u{2}" + $0.compactMap { pathByID[$0.id] }.sorted().joined(separator: "\u{1}") }.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// 手元で開く見直し表(HTML)。**蔵書の名前をそのまま含む**ので、リポジトリの外へ書く。
public enum ReviewReport {
    public static func html(_ doc: ProposalDocument) -> String {
        let byID = Dictionary(uniqueKeysWithValues: doc.books.map { ($0.id, $0) })
        var rows = ""
        for group in doc.groups {
            let v = group.aiVerdict
            let status: String
            if let v { status = v.isSeries ? "シリーズ(\(v.confidence.rawValue))" : "シリーズではない" }
            else if let e = group.aiError { status = "判定不能: \(e)" }
            else { status = "未判定" }
            let flags = [group.cleanBoundary ? nil : "途中で切れている",
                         group.circlesSharingPrefix >= 3 ? "ありふれた言葉?(\(group.circlesSharingPrefix))" : nil]
                .compactMap { $0 }.joined(separator: " / ")
            rows += """
            <tr class="group"><td colspan="5"><b>#\(group.id)</b> 規則: <b>\(esc(group.ruleName))</b>
            → モデル: <b>\(esc(v?.seriesName ?? "-"))</b> [\(esc(status))] \(esc(flags))</td></tr>
            """
            for id in group.memberIDs {
                guard let b = byID[id] else { continue }
                let out = v?.excludedIDs.contains(id) == true ? " class=\"out\"" : ""
                rows += "<tr\(out)><td>\(esc(b.parsed.circle))</td><td>\(esc(b.parsed.title))</td>"
                    + "<td>\(esc(b.series))</td><td>\(esc(b.volumeText))\(b.volumeInferred == true ? "(推定)" : "")</td><td>\(esc(b.parsed.trailing))</td></tr>\n"
            }
        }
        return """
        <!doctype html><meta charset="utf-8"><title>qooMeta 見直し表</title>
        <style>
        body{font:13px -apple-system,sans-serif;margin:16px;color:#222;background:#fff}
        table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #ddd;padding:3px 6px}
        tr.group td{background:#eef;padding-top:10px}tr.out td{color:#999;text-decoration:line-through}
        @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}tr.group td{background:#2a2a40}td{border-color:#333}}
        </style>
        <h1>シリーズ候補の見直し表</h1>
        <p>\(doc.groups.count) 組。取り消し線はモデルが外した本。列: サークル / タイトル / 最終シリーズ / 巻 / ネタ</p>
        <table>\(rows)</table>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// シリーズが付いた本の一覧(CSV)。**蔵書の名前をそのまま含む**ので、リポジトリの外へ書く。
/// Excel / Numbers でそのまま開けるよう、UTF-8 の BOM を付ける。シリーズ(系列)ごとにまとめ、巻の数値順に並べる。
public enum SeriesListExporter {
    /// - Parameter excludingFileNames: この名前(拡張子付きのファイル名)の本は一覧に出さない。
    ///   シリーズの判定は除外する前の全冊で済んでいる(先に除くと、比べる相手が減って組が崩れる)。
    public static func csv(_ doc: ProposalDocument, excludingFileNames excluded: Set<String> = []) -> String {
        let books = doc.books.filter {
            !$0.series.isEmpty && !excluded.contains(($0.file.relativePath as NSString).lastPathComponent.precomposedStringWithCanonicalMapping)
        }
        let bySeries = Dictionary(grouping: books) { "\($0.groupID ?? -1)" }
        let keys = bySeries.keys.sorted { a, b in
            let x = bySeries[a]![0], y = bySeries[b]![0]
            // 同じサークル・同じシリーズ名の組(本の種別やネタで分けたもの)は組の番号で並べる(毎回同じ順にするため)。
            return (x.parsed.circle, x.series, x.groupID ?? 0) < (y.parsed.circle, y.series, y.groupID ?? 0)
        }
        var lines = ["シリーズ,サークル,作者,冊数,巻,巻の推定,タイトル,ネタ,版,入手元,ファイル"]
        for key in keys {
            let members = bySeries[key]!.sorted { a, b in
                switch (a.volumeNumber, b.volumeNumber) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.parsed.title < b.parsed.title
                }
            }
            for b in members {
                lines.append([b.series, b.parsed.circle, b.parsed.authors.joined(separator: "、"), String(members.count),
                              b.volumeText, b.volumeInferred == true ? "推定" : "", b.parsed.title, b.parsed.trailing,
                              (b.parsed.editions ?? []).joined(separator: "、"), (b.parsed.sources ?? []).joined(separator: "、"), b.file.relativePath].map(field).joined(separator: ","))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { ",\"\r\n".contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension SeriesListExporter {
    /// 以前に書き出した一覧(CSV)の「ファイル」列から、ファイル名(パスの最後)を集める。
    public static func fileNames(inList csv: String) -> Set<String> {
        var names = Set<String>()
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            guard let last = parseCSVLine(String(line)).last, !last.isEmpty else { continue }
            names.insert((last as NSString).lastPathComponent.precomposedStringWithCanonicalMapping)
        }
        return names
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        var chars = Array(line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" { if chars.first == "\"" { current.append("\""); chars.removeFirst() } else { quoted = false } }
                else { current.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { fields.append(current); current = "" }
            else { current.append(c) }
        }
        fields.append(current)
        return fields
    }
}
