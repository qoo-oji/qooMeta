import QooMetaKit
import QooMetaScan
import SwiftUI
import UniformTypeIdentifiers

@main
struct QooMetaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands { WorkspaceCommands() }
    }
}

/// 窓の中身: 開いていなければ入口、開いていれば一覧。
struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            if let workspace = model.workspace {
                WorkspaceView(workspace: workspace, settings: model.settings)
            } else {
                WelcomeView(model: model)
            }
        }
        .task { await model.openDemoIfAsked() }
        .alert("開けませんでした", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .focusedSceneValue(\.appModel, model)
        .overlay {
            if model.isOpening {
                ProgressView("読み込んでいます…").padding(24).background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }
}

struct WelcomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("開いている一覧はありません", systemImage: "books.vertical")
        } description: {
            Text("書庫ファイルの入ったフォルダを開くと、名前を読んでシリーズと巻を提案します。\n直した内容は作業ファイルに残ります(蔵書は持ちません)。")
        } actions: {
            HStack {
                Button("フォルダを開く…") { model.openFolder() }
                Button("作業ファイルを開く…") { model.openWorkfile() }
            }
        }
    }
}

/// アプリ全体の状態(開いている一覧と、その保存先)。
@MainActor @Observable
final class AppModel {
    var workspace: Workspace?
    var error: String?
    var isOpening = false
    /// アプリの設定(規則の差分・スタンプ・書き出しの対応表)。作業ファイルとは分ける。
    let settings = AppSettings()

    /// 架空のデータ(`-demo`)。実際の蔵書は画面に出さない確かめ方(CLAUDE.md)。
    func openDemoIfAsked() async {
        guard workspace == nil, CommandLine.arguments.contains("-demo") else { return }
        let books = DemoData.files.map { Workfile.Book(id: $0.id, name: $0.name) }
        workspace = await Workspace.open(Workfile(rootPath: "(架空のデータ)", books: books), rules: settings.rules)
    }

    /// フォルダを開いて、書庫ファイルの名前を読み込む。
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(folder: url) }
    }

    private func load(folder url: URL) async {
        isOpening = true
        defer { isOpening = false }
        do {
            let files = try await Task.detached { try FolderScanner.scan(root: url) }.value
            guard !files.isEmpty else {
                error = "書庫ファイルが見つかりませんでした(\(FolderScanner.archiveExtensions.sorted().joined(separator: "・")))"
                return
            }
            let books = files.map { Workfile.Book(id: $0.relativePath, name: $0.baseName) }
            workspace = await Workspace.open(Workfile(rootPath: url.path, books: books), rules: settings.rules)
        } catch {
            self.error = String(describing: error)
        }
    }

    func openWorkfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isOpening = true
            defer { isOpening = false }
            do {
                let file = try Workfile.decoded(Data(contentsOf: url))
                let workspace = await Workspace.open(file, rules: settings.rules)
                workspace.markSaved(to: url)
                self.workspace = workspace
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// 上書き保存(保存先がまだ無ければ、場所を聞く)。
    func save() {
        guard let workspace else { return }
        guard let url = workspace.fileURL else { return saveAs() }
        write(workspace.workfile, to: url)
    }

    func saveAs() {
        guard let workspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "qooMeta 作業ファイル.json"
        panel.message = "作業ファイルには蔵書の名前が入ります。手元の場所へ保存してください。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(workspace.workfile, to: url)
    }

    private func write(_ file: Workfile, to url: URL) {
        do {
            try file.encoded().write(to: url, options: .atomic)
            workspace?.markSaved(to: url)
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// メニュー: ファイル(開く・保存)と、取り消し・やり直し。
/// 取り消しは一覧への操作単位(1 回のまとめて編集)で戻す。SwiftUI の UndoManager は使わず、
/// 作業ファイルへそのまま持っていける形で Workspace 側に積む。
struct WorkspaceCommands: Commands {
    @FocusedValue(\.appModel) private var model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("フォルダを開く…") { model?.openFolder() }
                .keyboardShortcut("o")
            Button("作業ファイルを開く…") { model?.openWorkfile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { model?.save() }
                .keyboardShortcut("s")
                .disabled(model?.workspace == nil)
            Button("別名で保存…") { model?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model?.workspace == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model?.workspace?.undoName.map { "「\($0)」を取り消す" } ?? "取り消す") { model?.workspace?.undo() }
                .keyboardShortcut("z")
                .disabled(model?.workspace?.undoName == nil)
            Button(model?.workspace?.redoName.map { "「\($0)」をやり直す" } ?? "やり直す") { model?.workspace?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model?.workspace?.redoName == nil)
        }
    }
}

/// 前面の窓(メニューから操作するため)。
struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}
