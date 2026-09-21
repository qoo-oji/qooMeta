import Foundation
@testable import QooMetaKit
import QooMetaRules
import Testing

/// 速い道(揃えない・表を引かない)は、**ふつうの道と同じ答え**を返す。速い道へ入る文字の範囲を広げるときは、
/// ここが守る(2026-09-21、計算を軽くしたときに足した)。
@Suite struct FastPathTests {
    /// 基本多言語面と、その先の少し(絵文字など)の文字すべて。
    static let scalars: [Unicode.Scalar] = (0x0000...0x2FFFF).compactMap { Unicode.Scalar(UInt32($0)) }

    /// 「揃えても変わらない」とみなす範囲の符号は、1 つずつ見ても、隣り合わせても、NFC・NFKC で変わらない。
    @Test func textTakenAsNormalizedReallyIs() {
        var stable: [Unicode.Scalar] = []
        for scalar in Self.scalars where String(Character(scalar)).isAlreadyNormalized {
            let s = String(Character(scalar))
            #expect(s.precomposedStringWithCompatibilityMapping.unicodeScalars.elementsEqual(s.unicodeScalars), "NFKC U+\(String(scalar.value, radix: 16))")
            #expect(s.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(s.unicodeScalars), "NFC U+\(String(scalar.value, radix: 16))")
            stable.append(scalar)
        }
        #expect(stable.count > 20_000)
        // 隣り合っても合成しない(範囲に結合文字が無いこと)。全部の組は多すぎるので、種類の違う字をつないで確かめる。
        let sample = stable.enumerated().filter { $0.offset % 97 == 0 }.map(\.element)
        var joined = String.UnicodeScalarView()
        for a in sample { for b in sample.prefix(40) { joined.append(a); joined.append(b) } }
        let text = String(joined)
        #expect(text.precomposedStringWithCompatibilityMapping.unicodeScalars.elementsEqual(text.unicodeScalars))
        // 範囲の外の字が 1 つでもあれば、ふつうの道へ回る。
        for s in ["ｶﾞ", "Ａ", "か\u{3099}", "㈱", "月　庭", "ヿ", "é", "e\u{301}"] { #expect(!s.isAlreadyNormalized, "\(s)") }
    }

    /// 比べる形: 速い道で作った鍵は、1 文字ずつ揃える元の作り方と同じ。
    @Test func comparableTextMatchesTheReferenceFolding() {
        let text = RuleEngine(rules: .builtin, dictionaries: [:]).text
        func reference(_ s: String) -> [Character] {
            s.flatMap { ch in
                String(ch).precomposedStringWithCompatibilityMapping.lowercased()
                    .filter { !text.isIgnoredInComparison($0) }.map { text.variantFolding[$0] ?? $0 }
            }
        }
        for scalar in Self.scalars where scalar.value < 0x10000 {
            let s = String(Character(scalar))
            #expect(text.comparable(s).key == reference(s), "U+\(String(scalar.value, radix: 16))")
        }
        for s in ["月の庭 第3巻", "Moon Garden vol.2", "ＭＯＯＮ　ｶﾞｰﾃﾞﾝ", "か\u{3099}き\u{3099}", "龍と竜", "A-B~C・D!?", "①②③ ㈱"] {
            let made = text.comparable(s)
            #expect(made.key == reference(s), "\(s)")
            #expect(made.originalCharacters == Array(s) && made.originalEnd.count == made.key.count)
        }
    }

    /// 型の照合の小さな判定(畳む・空白か・切れ目か)も、表を引く元の判定と同じ。
    @Test func characterTestsMatchTheUnicodeTables() {
        let text = RuleEngine(rules: .builtin, dictionaries: [:]).text
        func referenceFold(_ c: Character) -> Character {
            switch c {
            case "（": "("
            case "）": ")"
            case "［": "["
            case "］": "]"
            case "０"..."９": Character(UnicodeScalar(c.unicodeScalars.first!.value - 0xFF10 + 0x30)!)
            default: c
            }
        }
        for scalar in Self.scalars where scalar.value < 0x10000 {
            let c = Character(scalar)
            #expect(FilenameFormat.isSpace(c) == c.isWhitespace, "isSpace U+\(String(scalar.value, radix: 16))")
            #expect(FilenameFormat.fold(c) == referenceFold(c), "fold U+\(String(scalar.value, radix: 16))")
            #expect(text.isBoundary(c) == (c.isWhitespace || c.isNumber || text.boundaryCharacters.contains(c)),
                    "isBoundary U+\(String(scalar.value, radix: 16))")
        }
    }
}
