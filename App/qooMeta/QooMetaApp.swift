import SwiftUI

@main
struct QooMetaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands { EditingCommands() }
    }
}

/// 取り消し・やり直しは一覧への操作単位(1 回のまとめて編集)で戻す。SwiftUI の UndoManager は使わず、
/// 作業ファイル(段階 8)へそのまま持っていける形で Workspace 側に積む。
struct EditingCommands: Commands {
    @FocusedValue(\.workspace) private var workspace: Workspace?

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(workspace?.undoName.map { "「\($0)」を取り消す" } ?? "取り消す") { workspace?.undo() }
                .keyboardShortcut("z")
                .disabled(workspace?.undoName == nil)
            Button(workspace?.redoName.map { "「\($0)」をやり直す" } ?? "やり直す") { workspace?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(workspace?.redoName == nil)
        }
    }
}

/// 前面の窓の一覧(メニューから操作するため)。
struct WorkspaceFocusedValueKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusedValueKey.self] }
        set { self[WorkspaceFocusedValueKey.self] = newValue }
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
