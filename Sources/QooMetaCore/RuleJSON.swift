import Foundation

/// 型を決めずに読んだ JSON の値。
///
/// 規則・例のファイルは、決まった形の構造体へ直接読まない(docs/rules-format-design.md「読み込みと誤りの扱い」)。
/// 構造体へ直接読むと、最初の誤りで止まり、知らないキーは黙って読み飛ばされる。書き間違いが「効いているつもりで
/// 効いていない」になるのを防ぐため、いったんこの形で読み、位置を付けた誤りをすべて集めてから組み立てる。
public enum JSONValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 真偽を数より先に試す(JSONDecoder は数を真偽としては読まないので、ここで取り違えは起きない)。
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    /// JSON として壊れていれば、行・列を含む説明を付けて投げる。
    public static func parse(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            throw RuleIssue(.error, at: "", "JSON として読めない: \(underlying ?? context.debugDescription)")
        }
    }

    /// 誤りの説明に使う、値の種類の名前。
    var kindName: String {
        switch self {
        case .null: "null"
        case .bool: "真偽"
        case .number: "数"
        case .string: "文字列"
        case .array: "配列"
        case .object: "オブジェクト"
        }
    }
}

/// 規則・例のファイルの誤り(または警告)。位置は `examples[3].expect[1].series` のような JSON の中の道筋。
public struct RuleIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var path: String
    public var message: String
    /// 近い綴りの候補(書き間違いのとき)。
    public var suggestion: String?

    public init(_ severity: Severity, at path: String, _ message: String, suggestion: String? = nil) {
        self.severity = severity
        self.path = path
        self.message = message
        self.suggestion = suggestion
    }

    public var description: String {
        let place = path.isEmpty ? "" : "\(path): "
        let hint = suggestion.map { "(「\($0)」の書き間違い?)" } ?? ""
        return "\(severity == .error ? "エラー" : "警告"): \(place)\(message)\(hint)"
    }
}

/// 書き間違いへの候補。知らないキーに、いちばん近い既知の綴りを添える。
enum Spelling {
    /// 候補とみなす距離の上限。短い語どうしで無関係な語を勧めないよう、長さに応じて絞る。
    static func suggestion(for word: String, among candidates: some Sequence<String>) -> String? {
        let limit = max(1, min(3, word.count / 3))
        let scored = candidates.map { ($0, distance(word.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }), best.1 <= limit else { return nil }
        return best.0
    }

    /// 編集距離(挿入・削除・置換)。
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
