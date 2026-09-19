//
//  フォーマットの検証エラー [FF-15〜FF-19][TY-05]。
//
import Foundation

/// 検証エラーは**保存を拒否する** [FF-15][VD-01]。編集画面では該当位置に
/// 下線とメッセージを表示する [HP-04]。
public enum FormatCompileError: Error, Equatable, Sendable {
    /// 括弧の対応が取れない。`at` はフォーマット文字列内の文字位置。
    case unbalancedDelimiter(at: Int)
    case duplicateTitle
    case duplicateField(FieldRef)
    // `@labelgroupN` の撤去（v3 ステージ 5）で 3 つの失敗様式が消えた:
    // 番号の重複・範囲外・意味予約語との衝突 [旧 FF-16 の一部][旧 LG-01][旧 RW-15]。
    // フィールドを指す道が意味予約語 1 本になり、同じ軸を 2 通りで書けなくなった。
    case adjacentFreeFields(first: FieldRef, second: FieldRef)  // [FF-18][TY-05]
    case unknownReservedWord(String, at: Int)
    case emptyFormat
    /// 照合しても何も抽出できない（フィールドが 1 つも無い）。
    case noFieldAtAll

    /// エラーが指すフォーマット文字列内の位置（分かる場合）[HP-04]。
    public var sourceOffset: Int? {
        switch self {
        case .unbalancedDelimiter(let at), .unknownReservedWord(_, let at): return at
        default: return nil
        }
    }
}

// qooMeta: qooLibrary の `UserPresentableError` への準拠(画面の文言)は写していない。qooMeta はフォーマットを
// 利用者に編集させないので、エラーの文言は要らない。
