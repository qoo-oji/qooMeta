import Foundation

/// 型を決めずに読んだ JSON の値。
///
/// 規則・例のファイルは、決まった形の構造体へ直接読まない(docs/rules-format-design.md「読み込みと誤りの扱い」)。
/// 構造体へ直接読むと、最初の誤りで止まり、知らないキーは黙って読み飛ばされる。書き間違いが「効いているつもりで
/// 効いていない」になるのを防ぐため、いったんこの形で読み、位置を付けた誤りをすべて集めてから組み立てる。
public enum JSONValue: Sendable, Hashable, Decodable {
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
    public static func parse(_ data: Data, source: String) throws(RulesIssue) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            throw RulesIssue(.malformedJSON, source: source, at: "", underlying ?? context.debugDescription)
        } catch {
            throw RulesIssue(.malformedJSON, source: source, at: "", "\(error)")
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

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    /// 整数として読める数。
    public var intValue: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 1e9 { Int(n) } else { nil }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// 読める形の JSON(キーは並べ替える。毎回同じ出力にするため)。
    public func rendered(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return Self.quoted(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            if a.allSatisfy({ $0.objectValue == nil && $0.arrayValue == nil }) {
                return "[" + a.map { $0.rendered() }.joined(separator: ", ") + "]"
            }
            return "[\n" + a.map { pad + "  " + $0.rendered(indent: indent + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.keys.sorted().map { pad + "  " + Self.quoted($0) + ": " + o[$0]!.rendered(indent: indent + 1) }
                .joined(separator: ",\n") + "\n\(pad)}"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// 規則・例のファイルの誤り、または警告。位置は `grouping.sharedPrefix.minPrefx` のような JSON の中の道筋。
///
/// 表示の言葉は `description`(CLI 用)。利用側は `code` と `detail` から自分の言葉で出せる(api.md「方針」の 6)。
public struct RulesIssue: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Code: String, Sendable, Hashable {
        case malformedJSON, wrongKind, unsupportedSchemaVersion, unknownKey, missingKey, invalidValue, duplicateID,
             unresolvedList, unsafePattern, tooLarge, notYetSupported
        /// ここから下は警告(読み込みは続ける)。
        case newerRuleSkipped, requiredRuleUnknown, retiredID, missingDictionary
    }

    public var code: Code
    /// どのファイルか(`builtin` = 同梱の既定値、`user` = 利用者の変更、`examples` = 例のファイル)。
    public var source: String
    public var path: String
    /// 値や理由(言葉ではなく、キー・値・数など)。
    public var detail: String?
    /// 近い綴りの候補(書き間違いのとき)。
    public var suggestion: String?

    public init(_ code: Code, source: String, at path: String, _ detail: String? = nil, suggestion: String? = nil) {
        self.code = code
        self.source = source
        self.path = path
        self.detail = detail
        self.suggestion = suggestion
    }

    public var isWarning: Bool {
        [.newerRuleSkipped, .requiredRuleUnknown, .retiredID, .missingDictionary].contains(code)
    }

    public var description: String {
        let d = detail.map { "(\($0))" } ?? ""
        let message: String = switch code {
        case .malformedJSON: "JSON として読めない" + d
        case .wrongKind: "ファイルの種類が違う" + d
        case .unsupportedSchemaVersion: "この版の qooMeta が読めない形式の版" + d
        case .unknownKey: "知らないキー" + d
        case .missingKey: "必要なキーが無い" + d
        case .invalidValue: "値が正しくない" + d
        case .duplicateID: "同じ ID がほかにある" + d
        case .unresolvedList: "無い一覧を指している" + d
        case .unsafePattern: "正規表現が使えない" + d
        case .tooLarge: "大きすぎる" + d
        case .notYetSupported: "この版の qooMeta ではまだ働かない設定" + d
        case .newerRuleSkipped: "新しい版の qooMeta の規則なので飛ばした" + d
        case .requiredRuleUnknown: "新しい版の qooMeta でしか働かない必須の規則があるので、このファイルは適用しなかった" + d
        case .retiredID: "廃止された規則への参照なので無視した" + d
        case .missingDictionary: "辞書が渡されていないので、この条件は働かない" + d
        }
        let place = path.isEmpty ? "" : "\(path): "
        let hint = suggestion.map { "(「\($0)」の書き間違い?)" } ?? ""
        return "\(isWarning ? "警告" : "エラー")[\(source)] \(place)\(message)\(hint)"
    }
}

/// 読み込みで見つかった誤りの一式(`Error` として投げられるように包む)。
public struct RulesIssues: Error, Sendable, CustomStringConvertible {
    public var issues: [RulesIssue]
    public init(_ issues: [RulesIssue]) { self.issues = issues }
    public var description: String { issues.map(\.description).joined(separator: "\n") }
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
