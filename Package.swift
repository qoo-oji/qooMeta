// swift-tools-version: 6.2
import PackageDescription

// モジュールの分け方は docs/api.md「モジュール」。本体(QooMetaKit)は Foundation だけに依存し、ファイルを読まない・書かない
// (scripts/ci/check-kit-purity.sh が確かめる)。端末内モデル(QooMetaAI)だけが macOS 26 以降。
let package = Package(
    name: "qooMeta",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "qoometa", targets: ["qoometa"]),
        .library(name: "QooMetaKit", targets: ["QooMetaKit"]),
        .library(name: "QooMetaRules", targets: ["QooMetaRules"]),
        .library(name: "QooMetaExport", targets: ["QooMetaExport"]),
        .library(name: "QooMetaScan", targets: ["QooMetaScan"]),
        .library(name: "QooMetaAI", targets: ["QooMetaAI"]),
    ],
    targets: [
        // qooLibrary のファイル名フォーマット処理を写したもの(MIT、同じ作者。Sources/QooFormat/README.md)。本体の内部で使い、公開しない。
        .target(name: "QooFormat", exclude: ["README.md"]),
        // 名前の解析・シリーズ・巻・版・推定、規則の組み立てと検証。純粋な計算(規則・語彙・辞書は値で受け取る)。
        .target(name: "QooMetaKit", dependencies: ["QooFormat"]),
        // 同梱の既定値のデータ、例のファイル、システムの辞書の読み込み口。
        .target(name: "QooMetaRules", dependencies: ["QooMetaKit"], resources: [.copy("Resources")]),
        // Stackroom XML・qooViewer JSON。Data を返す。
        .target(name: "QooMetaExport", dependencies: ["QooMetaKit"]),
        // フォルダの走査(名前と属性だけ)。
        .target(name: "QooMetaScan", dependencies: ["QooMetaKit"]),
        // Apple Intelligence(端末内モデル)による判定。macOS 26 以降。
        .target(name: "QooMetaAI", dependencies: ["QooMetaKit"]),
        .executableTarget(name: "qoometa",
                          dependencies: ["QooMetaKit", "QooMetaRules", "QooMetaExport", "QooMetaScan", "QooMetaAI"]),
        .testTarget(name: "QooMetaKitTests", dependencies: ["QooMetaKit", "QooMetaRules", "QooMetaExport"]),
    ]
)
