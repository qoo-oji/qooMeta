import AppKit
import QooMetaKit
import QooMetaScan
import SwiftUI
import UniformTypeIdentifiers

@main
struct QooMetaApp: App {
    /// 最後の窓を閉じたときの振る舞いは AppKit が決めるので、代理を 1 つ置いて設定の値を返す。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// 言葉を 1 つでも読む前に、選んだ言語を効かせる(窓の題は画面の外で決まるので、あとからでは間に合わない)。
    init() { AppSettings.shared.language.apply() }

    var body: some Scene {
        WindowGroup {
            RootView().environment(\.locale, AppSettings.shared.language.locale)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { WorkspaceCommands() }

        // 規則はアプリの設定(どの一覧にも共通)なので、一覧の窓とは別の窓で直す。
        // **当たる処理の段ごとに窓を分ける**(2026-09-21、利用者の指示)。
        Window("File name parsing", id: FileNameRulesView.windowID) {
            FileNameRulesView(settings: .shared).environment(\.locale, AppSettings.shared.language.locale)
        }
        // 3 ペインが最初から収まる幅(ルールセットの一覧 + 組の一覧 + 型 1 行が切れない幅)。
        .defaultSize(width: 1240, height: 820)

        Window("Series and volume extraction", id: SeriesRulesView.windowID) {
            SeriesRulesView(settings: .shared).environment(\.locale, AppSettings.shared.language.locale)
        }
        // 左(やりたいこと)と右(設定)が、最初から窮屈でない幅。
        .defaultSize(width: 1080, height: 760)

        // 環境設定(⌘,)。いまは画面の言語だけ。規則とプリセットは中身が大きいので、別の窓のまま。
        Settings {
            GeneralSettingsView(settings: .shared)
        }
    }
}

/// AppKit へ渡す代理。いまのところ持ちごとは 1 つだけ ―― **すべての窓を閉じたときに終わるか**。
/// SwiftUI の `Scene` からは決められないので、ここで環境設定の値を返す(2026-09-20、利用者の指示)。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { AppSettings.shared.quitsWhenLastWindowCloses }
    }

    /// 保存していない修正があれば、終わる前に確かめる。窓を閉じるときの確かめ(`dismissalConfirmationDialog`)は
    /// ⌘Q では出ないので、ここで受ける ―― 確かめないと、直した内容が何も言わずに消える(2026-09-21 の監査)。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.anyHasUnsavedChanges else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit without saving?".ui
            alert.informativeText = "The corrections you have not saved are lost.".ui
            alert.addButton(withTitle: "Cancel".ui)
            alert.addButton(withTitle: "Quit without saving".ui)
            alert.buttons.last?.hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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
        // 保存していない修正があるまま窓を閉じようとしたら、確かめる。取り消せば窓は残り、⌘S で保存できる
        // (「保存して閉じる」は置かない ―― 保存先を選ぶ画面を取り消しても、窓はそのまま閉じてしまうため)。
        .dismissalConfirmationDialog("Close without saving?", shouldPresent: model.workspace?.hasUnsavedChanges == true) {
            // 閉じると決めた窓の修正は、続く終了の確かめでもう一度聞かない(最後の窓を閉じたら終わる設定のとき)。
            Button("Close without saving", role: .destructive) { model.isClosingWithoutSaving = true }
        } message: {
            Text("The corrections you have not saved are lost.")
        }
        // 設定ファイルが読めなかった・保存できなかったことは、黙っていない。1 つの View に alert を 2 つ重ねないよう、背景に付ける。
        .background {
            Color.clear.alert("There is a problem with the settings file",
                              isPresented: Binding(get: { model.settings.storageIssue != nil },
                                                   set: { if !$0 { model.settings.dismissStorageIssue() } })) {
                Button("Close") { model.settings.dismissStorageIssue() }
            } message: {
                Text(model.settings.storageIssueText ?? "")
            }
        }
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

    /// 段 2 に出す、ルールセットごとの当たり具合。
    struct PresetFit: Identifiable {
        var id: String
        var title: String
        /// 説明の鍵。
        var note: String
        /// 読み切れた冊数(型に合い、括弧の読み残しも無い)。
        var read: Int
        /// 型には合ったが、括弧がどの欄にもならず値に残った冊数。
        var leftover: Int
    }

    var step: Step = .choose
    var picked: Picked?
    var presetFits: [PresetFit] = []
    var isFitting = false
    /// 数え直しの回(`computeFits`)。
    private var fitRound = 0
    var chosenPreset: String?
    var workspace: Workspace?
    var error: String?
    var isOpening = false
    /// アプリの設定(規則の差分・スタンプ・書き出しの対応表)。作業ファイルとは分ける。
    let settings = AppSettings.shared

    /// 開いている窓の持ちもの(終了のとき、保存していない修正が残っていないかを見るため)。窓が消えれば一緒に消える。
    private static let open = NSHashTable<AppModel>.weakObjects()

    static var anyHasUnsavedChanges: Bool {
        open.allObjects.contains { !$0.isClosingWithoutSaving && $0.workspace?.hasUnsavedChanges == true }
    }

    /// 利用者が「保存せずに閉じる」と決めた窓。
    var isClosingWithoutSaving = false

    init() { Self.open.add(self) }

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
    /// **段 2 から始める**: 段 1 で選ぶものが無いだけで、流れの残りはそのままなぞれる
    /// (前は段 3 へ直行していて、流れそのものが確かめられなかった)。
    func openDemoIfAsked() async {
        guard picked == nil, workspace == nil, CommandLine.arguments.contains("-demo") else { return }
        let root = "(demo data)".ui
        let files = DemoData.files.map {
            ScannedFile(path: root + "/" + $0.id, relativePath: $0.id, baseName: $0.name, fileExtension: "cbz")
        }
        picked = Picked(root: URL(fileURLWithPath: root), files: files,
                        kinds: [(name: "CBZ", count: files.count)])
        PickedForRules.shared.set(files.map(\.baseName))
        go(to: .parse)
    }

    // MARK: - 段 1: 対象を選ぶ

    /// いまの一覧を捨てることになる操作。保存していない修正があるときは、行う前に確かめる。
    enum Discarding {
        case pick([URL])
        case openWorkfile(URL)
    }

    /// 確かめを待っている操作。決めたら `confirmDiscarding` が走る。
    var pendingDiscard: Discarding?
    /// いま走っている走査。**選び直したら、前の走査は取り消して結果も捨てる** ―― 遅い走査(ネットワークの蔵書)が
    /// 後から終わると、その結果が新しい一覧を押しのけ、直している途中の内容が消えていた(2026-09-21 の監査)。
    private var scanning: Task<Void, Never>?

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose".ui
        guard panel.runModal() == .OK, let url = panel.url else { return }
        offer(.pick([url]))
    }

    /// 本のファイルを直に選ぶ(フォルダの中の一部だけを処理したいとき)。フォルダも混ぜて選べる。
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose".ui
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        offer(.pick(panel.urls))
    }

    /// いまの一覧を捨てる操作を受け取る。保存していない修正があれば、捨ててよいか先に聞く。
    private func offer(_ action: Discarding) {
        if workspace?.hasUnsavedChanges == true { pendingDiscard = action } else { perform(action) }
    }

    func confirmDiscarding() {
        guard let action = pendingDiscard else { return }
        pendingDiscard = nil
        perform(action)
    }

    private func perform(_ action: Discarding) {
        switch action {
        case .pick(let urls):
            scanning?.cancel()
            scanning = Task { await pick(urls) }
        case .openWorkfile(let url):
            scanning?.cancel()
            open(workfileAt: url)
        }
    }

    private func pick(_ urls: [URL]) async {
        isOpening = true
        // 取り消された走査は、あとから来た走査の「読み込み中」を消さない。
        defer { if !Task.isCancelled { isOpening = false } }
        do {
            // 走査そのものも取り消せるように、取り消しを中の Task へ伝える(`Task.detached` は親の取り消しを継がない)。
            let scan = Task.detached { try FolderScanner.scan(items: urls) }
            let found = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            // 待っているあいだに選び直されていたら、この結果は使わない。
            guard !Task.isCancelled else { return }
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
            // 選んだ名前は、ファイル名解析の窓でも使う(直した効果を、その蔵書の名前で見せるため)。
            PickedForRules.shared.set(found.files.map(\.baseName))
            // 選び直したら、前の結果は捨てる(古い一覧が残っていると、どの蔵書の話か分からなくなる)。
            workspace = nil
            presetFits = []
        } catch is CancellationError {
            // 選び直された。何も出さない。
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - 段 2: 解析方法を選ぶ

    /// プリセットごとに、何冊のファイル名が型に合うかを数える。**選ぶ前に結果が見える**ようにするため。
    func computeFits() async {
        guard let picked else { return }
        // 数え直しは重ねて走りうる(段を行き来する、規則を続けて直す)。**いちばん新しい回の結果だけ**を使う
        // ―― 古い回が後から終わると、直す前の数が画面に戻ってしまう。
        fitRound += 1
        let round = fitRound
        isFitting = true
        defer { if round == fitRound { isFitting = false } }
        let entries = settings.rules.presetCatalog.entries
        let names = picked.files.map(\.baseName)
        let formats = settings.rules.formats
        let counts = await Task.detached { () -> [String: (read: Int, leftover: Int)] in
            // ルールセットごとに数えるので、並べて走らせる(蔵書が大きいと 1 本では待たされる)。
            await withTaskGroup(of: (String, Int, Int).self) { group in
                for id in entries.map(\.id) {
                    group.addTask {
                        let set = formats[id]
                        var read = 0, leftover = 0
                        for name in names {
                            switch set.check(name).outcome {
                            case .read: read += 1
                            case .leftover: leftover += 1
                            case .unread: break
                            }
                        }
                        return (id, read, leftover)
                    }
                }
                return await group.reduce(into: [:]) { $0[$1.0] = (read: $1.1, leftover: $1.2) }
            }
        }.value
        guard round == fitRound else { return }
        presetFits = entries.map {
            PresetFit(id: $0.id, title: $0.preset.displayName, note: RuleLabels.preset($0.id).help,
                      read: counts[$0.id]?.read ?? 0, leftover: counts[$0.id]?.leftover ?? 0)
        }
        // 選び直しでなければ、**この蔵書でいちばん読めたもの**を選んでおく(既定を黙って当てない)。
        // 同じ数なら、同梱の並びで先のものを採る。
        if chosenPreset == nil || counts[chosenPreset!] == nil {
            chosenPreset = presetFits.reduce(into: nil as PresetFit?) { best, fit in
                if best == nil || fit.read > best!.read { best = fit }
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
        // 組み立てている最中にもう一度押されても、一覧を 2 つ作らない。
        guard !isOpening else { return }
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
        // 開くと、いまの一覧は入れ替わる。保存していない修正があれば先に確かめる(前は、何も聞かずに入れ替えていた)。
        offer(.openWorkfile(url))
    }

    private func open(workfileAt url: URL) {
        Task {
            isOpening = true
            defer { isOpening = false }
            do {
                // 読むのは main の外で(大きな作業ファイルやネットワークの先のファイルで、画面を止めない)。
                let file = try await Task.detached { try Workfile.decoded(Data(contentsOf: url)) }.value
                let workspace = await Workspace.open(file, rules: settings.rules)
                workspace.markSaved(to: url)
                self.workspace = workspace
                PickedForRules.shared.set(file.books.map(\.name))
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
            Button("File Name Parsing…") {
                // 段 2 で選んでいるルールセットを、窓にも選ばせる(選んでいなければ窓の今のまま)。
                if let preset = model?.chosenPreset { PickedForRules.shared.open(ruleSet: preset) }
                openWindow(id: FileNameRulesView.windowID)
            }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Series and Volume Extraction…") { openWindow(id: SeriesRulesView.windowID) }
                .keyboardShortcut("2", modifiers: [.command, .option])
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
