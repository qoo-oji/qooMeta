import QooMetaKit
import QooMetaScan
import SwiftUI
import UniformTypeIdentifiers

@main
struct QooMetaApp: App {
    /// 言葉を 1 つでも読む前に、選んだ言語を効かせる(窓の題は画面の外で決まるので、あとからでは間に合わない)。
    init() { AppSettings.shared.language.apply() }

    var body: some Scene {
        WindowGroup {
            RootView().environment(\.locale, AppSettings.shared.language.locale)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { WorkspaceCommands() }

        // 規則はアプリの設定(どの一覧にも共通)なので、一覧の窓とは別の窓で直す。
        Window("Rules", id: RulesEditorView.windowID) {
            RulesEditorView(settings: .shared).environment(\.locale, AppSettings.shared.language.locale)
        }
        .defaultSize(width: 980, height: 680)

        // 環境設定(⌘,)。いまは画面の言語だけ。規則とプリセットは中身が大きいので、別の窓のまま。
        Settings {
            GeneralSettingsView(settings: .shared)
        }
    }
}

/// 窓の中身: 1 回きりの流れ(対象 → 解析方法 → 確認 → 書き出し)。
struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        FlowView(model: model)
        .task { await model.openDemoIfAsked() }
        .alert("Could not open", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Close") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .focusedSceneValue(\.appModel, model)
        .overlay {
            if model.isOpening {
                ProgressView("Loading…").padding(24).background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }
}

/// アプリ全体の状態。**1 回きりの流れ**(FlowView)の、いまの段と持ちもの。
@MainActor @Observable
final class AppModel {
    /// 流れの段。番号がそのまま順。
    enum Step: Int, CaseIterable, Identifiable {
        case choose, parse, review, export
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .choose: "Choose the books"
            case .parse: "Choose how to read them"
            case .review: "Check and correct"
            case .export: "Export"
            }
        }
    }

    /// 段 1 で選んだもの。
    struct Picked {
        var root: URL
        var files: [ScannedFile]
        /// 種類ごとの冊数(選んだものが思ったとおりかを、冊数で確かめてもらう)。
        var kinds: [(name: String, count: Int)]
    }

    /// 段 2 に出す、プリセットごとの当たり具合。
    struct PresetFit: Identifiable {
        var id: String
        var title: String
        /// 説明の鍵。
        var note: String
        var matched: Int
    }

    var step: Step = .choose
    var picked: Picked?
    var presetFits: [PresetFit] = []
    var isFitting = false
    var chosenPreset: String?
    var workspace: Workspace?
    var error: String?
    var isOpening = false
    /// アプリの設定(規則の差分・スタンプ・書き出しの対応表)。作業ファイルとは分ける。
    let settings = AppSettings.shared

    /// 行ける先(通り過ぎた段へは戻れる)。
    var furthestStep: Step {
        if workspace != nil { return .export }
        if picked != nil { return .parse }
        return .choose
    }

    func go(to step: Step) {
        guard step.rawValue <= furthestStep.rawValue else { return }
        self.step = step
        if step == .parse { Task { await computeFits() } }
    }

    /// 架空のデータ(`-demo`)。実際の蔵書は画面に出さない確かめ方(CLAUDE.md)。
    func openDemoIfAsked() async {
        guard workspace == nil, CommandLine.arguments.contains("-demo") else { return }
        let books = DemoData.files.map { Workfile.Book(id: $0.id, name: $0.name) }
        workspace = await Workspace.open(Workfile(rootPath: "(demo data)".ui, books: books), rules: settings.rules)
        step = .review
    }

    // MARK: - 段 1: 対象を選ぶ

    /// 選び直す前に確かめる(保存していない修正があるとき)。決めたら `confirmedPick` が走る。
    var pendingPick: [URL]?

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose".ui
        guard panel.runModal() == .OK, let url = panel.url else { return }
        offer([url])
    }

    /// 本のファイルを直に選ぶ(フォルダの中の一部だけを処理したいとき)。フォルダも混ぜて選べる。
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose".ui
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        offer(panel.urls)
    }

    /// 選んだものを受け取る。保存していない修正があれば、捨ててよいか先に聞く。
    private func offer(_ urls: [URL]) {
        if workspace?.hasUnsavedChanges == true { pendingPick = urls } else { Task { await pick(urls) } }
    }

    func confirmPendingPick() {
        guard let urls = pendingPick else { return }
        pendingPick = nil
        Task { await pick(urls) }
    }

    private func pick(_ urls: [URL]) async {
        isOpening = true
        defer { isOpening = false }
        do {
            let found = try await Task.detached { try FolderScanner.scan(items: urls) }.value
            guard !found.files.isEmpty else {
                error = "No books found. qooMeta reads %@, and folders that hold images.".ui(
                    FolderScanner.bookFileExtensions.sorted().joined(separator: ", "))
                return
            }
            var counts: [String: Int] = [:]
            for file in found.files { counts[file.isFolder ? "Folders".ui : file.fileExtension.uppercased(), default: 0] += 1 }
            picked = Picked(root: found.root, files: found.files,
                            kinds: counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                                .map { (name: $0.key, count: $0.value) })
            // 選び直したら、前の結果は捨てる(古い一覧が残っていると、どの蔵書の話か分からなくなる)。
            workspace = nil
            presetFits = []
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - 段 2: 解析方法を選ぶ

    /// プリセットごとに、何冊のファイル名が型に合うかを数える。**選ぶ前に結果が見える**ようにするため。
    func computeFits() async {
        guard let picked else { return }
        isFitting = true
        defer { isFitting = false }
        let entries = settings.rules.presetCatalog.entries
        let names = picked.files.map(\.baseName)
        let formats = settings.rules.formats
        let counts = await Task.detached { () -> [String: Int] in
            // プリセットごとに数えるので、並べて走らせる(蔵書が大きいと 1 本では待たされる)。
            await withTaskGroup(of: (String, Int).self) { group in
                for id in entries.map(\.id) {
                    group.addTask {
                        let set = formats[id]
                        return (id, names.reduce(0) { $0 + (set.read($1).formatIndex != nil ? 1 : 0) })
                    }
                }
                return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
        }.value
        presetFits = entries.map {
            PresetFit(id: $0.id, title: $0.preset.displayName, note: RuleLabels.preset($0.id).help,
                      matched: counts[$0.id] ?? 0)
        }
        // 選び直しでなければ、**この蔵書でいちばん読めたもの**を選んでおく(既定を黙って当てない)。
        // 同じ数なら、同梱の並びで先のものを採る。
        if chosenPreset == nil || counts[chosenPreset!] == nil {
            chosenPreset = presetFits.reduce(into: nil as PresetFit?) { best, fit in
                if best == nil || fit.matched > best!.matched { best = fit }
            }?.id ?? settings.rules.formats.defaultName
        }
    }

    /// 段 2 を抜けて、選んだプリセットで一覧を組み立てる。
    ///
    /// すでに一覧があるとき(段 3 から戻ってきたとき)は**作り直さない**。割り当てだけ替えて名前を読み直す
    /// ―― 作り直すと、利用者がそこまでに直した内容が黙って消えてしまう。
    func startReview() {
        guard let picked, let preset = chosenPreset else { return }
        if let workspace {
            if workspace.presets.defaultPreset != preset { workspace.setPreset(preset, forFolder: nil) }
            step = .review
            return
        }
        Task {
            isOpening = true
            defer { isOpening = false }
            let books = picked.files.map { Workfile.Book(id: $0.relativePath, name: $0.baseName, isFolder: $0.isFolder) }
            let file = Workfile(rootPath: picked.root.path, books: books,
                                presets: .init(defaultPreset: preset))
            workspace = await Workspace.open(file, rules: settings.rules)
            step = .review
        }
    }

    func openWorkfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Open".ui
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isOpening = true
            defer { isOpening = false }
            do {
                let file = try Workfile.decoded(Data(contentsOf: url))
                let workspace = await Workspace.open(file, rules: settings.rules)
                workspace.markSaved(to: url)
                self.workspace = workspace
                picked = nil                 // 作業ファイルは、対象と解析方法を自分で持っている
                step = .review
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
        panel.nameFieldStringValue = "qooMeta workfile.json".ui
        panel.message = "A workfile holds the names of your books. Save it somewhere of your own.".ui
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Rules…") { openWindow(id: RulesEditorView.windowID) }
                .keyboardShortcut(",", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("Choose Books…") { model?.go(to: .choose) }
                .keyboardShortcut("o")
            Button("Open Workfile…") { model?.openWorkfile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.save() }
                .keyboardShortcut("s")
                .disabled(model?.workspace == nil)
            Button("Save As…") { model?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model?.workspace == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model?.workspace?.undoName.map { "Undo “%@”".ui($0) } ?? "Undo".ui) { model?.workspace?.undo() }
                .keyboardShortcut("z")
                .disabled(model?.workspace?.undoName == nil)
            Button(model?.workspace?.redoName.map { "Redo “%@”".ui($0) } ?? "Redo".ui) { model?.workspace?.redo() }
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
