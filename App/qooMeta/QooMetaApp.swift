import SwiftUI

@main
struct QooMetaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}

struct RootView: View {
    /// 段階 5(画面の骨組み)は、架空のデータ(`-demo`)だけを開く。ファイルを開くのは段階 8。
    @State private var workspace: Workspace? = CommandLine.arguments.contains("-demo")
        ? Workspace(files: DemoData.files) : nil

    var body: some View {
        if let workspace {
            WorkspaceView(workspace: workspace)
        } else {
            ContentUnavailableView("開いている一覧はありません", systemImage: "books.vertical",
                                   description: Text("今は起動の引数 -demo で架空のデータだけを開けます。"))
        }
    }
}
