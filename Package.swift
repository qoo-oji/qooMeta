// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "qooMeta",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "qoometa", targets: ["qoometa"]),
        .library(name: "QooMetaCore", targets: ["QooMetaCore"]),
    ],
    targets: [
        // qooLibrary のファイル名フォーマット処理を写したもの(MIT、同じ作者。Sources/QooFormat/README.md)。
        .target(name: "QooFormat"),
        // 名前の解析・シリーズ候補・書き出し。FoundationModels に依存しない(テストはここを見る)。
        .target(name: "QooMetaCore", dependencies: ["QooFormat"]),
        // Apple Intelligence(端末内モデル)による判定。
        .target(name: "QooMetaAI", dependencies: ["QooMetaCore"]),
        .executableTarget(name: "qoometa", dependencies: ["QooMetaCore", "QooMetaAI"]),
        .testTarget(name: "QooMetaCoreTests", dependencies: ["QooMetaCore"]),
    ]
)
