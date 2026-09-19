import CryptoKit
import Foundation
import QooMetaKit
import QooMetaScan

/// 集計だけの報告(名前を含まない)。CLI が標準出力へ出すのはこれだけ。
///
/// 標準出力はターミナルの記録や AI との会話へ写りうるので、名前を出さない
/// (qooViewer の check-private-terms.py と同じ考え方)。名前を見るのは手元で開く HTML の見直し表だけ。
enum StatsReport {
    static func lines(_ set: ProposalSet, doc: ScanDocument) -> [String] {
        let books = set.proposals
        func ratio(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.1f%%", Double(n) * 100 / Double(d)) }
        let matched = books.filter { if case .fallback("wholeName") = $0.parsed.format { false } else { true } }
        let formatted = books.filter { if case .format = $0.parsed.format { true } else { false } }
        let writers = Set(books.map { ($0.parsed.circle ?? "").lowercased() }).count
        let sizes = set.series.map(\.memberIDs.count)
        let evidence = Dictionary(grouping: set.series) { s -> String in
            switch s.evidence {
            case .volumeHead: "タイトル + 巻"
            case .sharedPrefix(let clean): clean ? "共通部分(語の切れ目)" : "共通部分(語の途中)"
            case .compilation: "総集編"
            case .confirmed: "確定"
            }
        }.mapValues(\.count)
        let withSeries = books.filter { $0.seriesID != nil }
        let withVolume = books.filter { $0.volume != nil }
        var lines = [
            "本: \(books.count)(名前の形に当てはまった: \(matched.count)、うちフォーマット \(formatted.count)、書き手: \(writers))"
                + (set.rejected.isEmpty ? "" : "、扱わなかった: \(set.rejected.count)"),
            "シリーズ: \(set.series.count) 組 / \(sizes.reduce(0, +)) 冊(組の大きさ 最大 \(sizes.max() ?? 0)、2 冊の組 \(sizes.filter { $0 == 2 }.count))",
            "  組になった理由: " + evidence.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "、"),
        ]
        let judged = doc.judgements.compactMap(\.verdict)
        if !doc.judgements.isEmpty {
            let accepted = judged.filter(\.isSeries)
            let seconds = judged.reduce(0.0) { $0 + $1.seconds }
            lines += [
                "端末内モデルの判定: \(judged.count) 組(判定できなかった: \(doc.judgements.filter { $0.error != nil }.count) 組)",
                "  シリーズと判定: \(accepted.count)(\(ratio(accepted.count, judged.count)))、確からしさ \(Dictionary(grouping: accepted, by: \.confidence.rawValue).mapValues(\.count))",
                "  名前を規則から変えた: \(zip(doc.judgements, doc.judgements.map(\.verdict)).filter { j, v in v.map { $0.isSeries && !$0.seriesName.isEmpty && $0.seriesName != j.ruleName } ?? false }.count) 組、外した本: \(accepted.reduce(0) { $0 + $1.excludedIDs.count }) 冊",
                String(format: "  所要時間: 合計 %.0f 秒、1 組あたり %.1f 秒", seconds, judged.isEmpty ? 0 : seconds / Double(judged.count)),
            ]
        }
        lines += [
            "最終: シリーズ付き \(withSeries.count) 冊(\(ratio(withSeries.count, books.count)))、巻あり \(withVolume.count) 冊(数値 \(withVolume.filter { $0.volume?.sortKey != nil }.count)、うち 1 巻と推定 \(books.filter { $0.volume?.inferred == true }.count))",
            "結果の指紋: \(ResultFingerprint.of(set))",
        ]
        return lines
    }
}

/// 結果の指紋。規則や処理を「結果を変えないつもりで」移し替えるとき、前後で本と組の中身が 1 冊も変わっていないことを、
/// 名前を出さずに確かめる(docs/roadmap.md「進め方の約束」)。出力するのはハッシュだけ。
///
/// 含めるもの: 本ごとの名前の解析結果・シリーズ・巻と、同じ組に入った本の集まり。組の ID のような、中身が同じでも
/// 変わりうる値は含めない。本の ID は走査の起点からの相対パス。
enum ResultFingerprint {
    static func of(_ set: ProposalSet) -> String {
        var lines = set.proposals.sorted { $0.id < $1.id }.map { b in
            let p = b.parsed
            let series = b.seriesID.flatMap { set.series($0)?.name } ?? ""
            return [b.id, p.circle ?? "", p.authors.joined(separator: "\u{1}"), p.title, p.relation ?? "",
                    p.genre ?? "", p.event ?? "", p.keyword ?? "", p.editions.joined(separator: "\u{1}"),
                    p.sources.joined(separator: "\u{1}"), series, b.volume?.text ?? "",
                    b.volume?.sortKey.map { String($0) } ?? "", b.volume?.inferred == true ? "推定" : ""]
                .joined(separator: "\u{2}")
        }
        // 組は、入った本の ID の集まりで表す(組の ID には依らない)。
        lines += set.series.map { "組\u{2}" + $0.memberIDs.sorted().joined(separator: "\u{1}") }.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// 手元で開く見直し表(HTML)。**蔵書の名前をそのまま含む**ので、リポジトリの外へ書く。
enum ReviewReport {
    static func html(_ set: ProposalSet, doc: ScanDocument, rulesOnly: ProposalSet) -> String {
        let verdicts = Dictionary(doc.judgements.map { ($0.memberIDs, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = ""
        for (n, series) in set.series.enumerated() {
            let evidence: String = switch series.evidence {
            case .volumeHead: "タイトル + 巻"
            case .sharedPrefix(let clean): clean ? "共通部分" : "共通部分(語の途中で切れている)"
            case .compilation: "総集編"
            case .confirmed: "確定"
            }
            // 端末内モデルの判定は、規則のシリーズ(判定した組)の本で引く。
            let ruleSeries = series.memberIDs.first.flatMap { rulesOnly[$0]?.seriesID }.flatMap { rulesOnly.series($0) }
            let judgement = ruleSeries.flatMap { verdicts[$0.memberIDs.sorted()] }
            let status: String
            if let v = judgement?.verdict { status = v.isSeries ? "モデル: シリーズ(\(v.confidence.rawValue))" : "モデル: シリーズではない" }
            else if let e = judgement?.error { status = "モデル: 判定不能 \(e)" }
            else { status = "" }
            rows += """
            <tr class="group"><td colspan="5"><b>#\(n + 1)</b> <b>\(esc(series.name))</b> [\(esc(evidence))] \(esc(status))</td></tr>

            """
            for id in series.memberIDs {
                guard let b = set[id] else { continue }
                rows += "<tr><td>\(esc(b.parsed.circle ?? ""))</td><td>\(esc(b.parsed.title))</td>"
                    + "<td>\(esc(series.name))</td><td>\(esc(b.volume?.text ?? ""))\(b.volume?.inferred == true ? "(推定)" : "")</td>"
                    + "<td>\(esc(b.parsed.relation ?? ""))</td></tr>\n"
            }
        }
        return """
        <!doctype html><meta charset="utf-8"><title>qooMeta 見直し表</title>
        <style>
        body{font:13px -apple-system,sans-serif;margin:16px;color:#222;background:#fff}
        table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #ddd;padding:3px 6px}
        tr.group td{background:#eef;padding-top:10px}
        @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}tr.group td{background:#2a2a40}td{border-color:#333}}
        </style>
        <h1>シリーズの見直し表</h1>
        <p>\(set.series.count) 組。列: サークル / タイトル / シリーズ / 巻 / ネタ</p>
        <table>\(rows)</table>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// シリーズが付いた本の一覧(CSV)。**蔵書の名前をそのまま含む**ので、リポジトリの外へ書く。見直し用(API には含めない)。
/// Excel / Numbers でそのまま開けるよう、UTF-8 の BOM を付ける。シリーズごとにまとめ、巻の順に並べる。
enum SeriesListCSV {
    /// - Parameter excluded: この名前(拡張子付きのファイル名)の本は一覧に出さない。
    ///   シリーズの判定は除外する前の全冊で済んでいる(先に除くと、比べる相手が減って組が崩れる)。
    static func csv(_ set: ProposalSet, files: [String: ScannedFile], excluding excluded: Set<String> = []) -> String {
        func fileName(_ id: String) -> String {
            (id as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        }
        var lines = ["シリーズ,サークル,作者,冊数,巻,巻の推定,タイトル,ネタ,版,入手元,ファイル"]
        for series in set.series {
            let members = series.memberIDs.filter { !excluded.contains(fileName(files[$0]?.relativePath ?? $0)) }
            for id in members {
                guard let b = set[id] else { continue }
                lines.append([series.name, b.parsed.circle ?? "", b.parsed.authors.joined(separator: "、"), String(members.count),
                              b.volume?.text ?? "", b.volume?.inferred == true ? "推定" : "", b.parsed.title,
                              b.parsed.relation ?? "", b.parsed.editions.joined(separator: "、"),
                              b.parsed.sources.joined(separator: "、"), files[id]?.relativePath ?? id].map(field).joined(separator: ","))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { ",\"\r\n".contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 以前に書き出した一覧(CSV)の「ファイル」列から、ファイル名(パスの最後)を集める。
    static func fileNames(inList csv: String) -> Set<String> {
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
