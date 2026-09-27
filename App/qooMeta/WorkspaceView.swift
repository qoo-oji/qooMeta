import AppKit
import QooMetaKit
import SwiftUI

/// 1 つの窓: 一覧が中心で、上に絞り込みの帯、右に詳細(選んだ本のメタデータを直す)。
///
/// 一覧の右クリックからも、選んだ本をまとめて直せる(1 つのシリーズにする・連番・欄をまとめて変える・提案に戻す ほか。
/// qooViewer へ移したこの画面で、右の詳細の代わりに足した操作を取り込んだ。2026-09-27)。
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var settings: AppSettings
    @State private var showsDetail = true
    /// ツールバーの「すべてを提案に戻す」の確かめ(相手の本)。
    @State private var revertingAll: Set<BookRow.ID>?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(workspace: workspace)
            Divider()
            BookTableView(workspace: workspace)
        }
        .inspector(isPresented: $showsDetail) {
            DetailView(workspace: workspace, settings: settings)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        .searchable(text: $workspace.searchText, placement: .toolbar, prompt: "Search fields and file names")
        .toolbar {
            if workspace.isWorking {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
            ToolbarItem {
                Button { workspace.toggleSelectAll() } label: {
                    Label(workspace.isEveryVisibleBookSelected ? "Deselect All" : "Select All",
                          systemImage: "checkmark.rectangle.stack")
                }
                // 絵だけでは何のボタンか分からない(2026-09-20、利用者の指摘)。名前も出す。
                .labelStyle(.titleAndIcon)
                .disabled(workspace.visibleCount == 0)
                .help("Select all the books in the list, or deselect them")
            }
            ToolbarItem {
                Button { revertingAll = workspace.correctedIDs(in: workspace.selection) } label: {
                    Label("Revert to Proposal", systemImage: "arrow.uturn.backward")
                }
                .labelStyle(.titleAndIcon)
                .disabled(workspace.correctedIDs(in: workspace.selection).isEmpty)
                .help("Throws away every correction of the selected books and goes back to what was read from their file names")
            }
            ToolbarItem {
                Button { openParsingSettings() } label: {
                    Label("Parsing settings", systemImage: "textformat.abc")
                }
                .labelStyle(.titleAndIcon)
                .help("Look at and correct the rule sets that read file names. Opens the rule set of the selected book")
            }
            ToolbarItem {
                Button { openWindow(id: SeriesRulesView.windowID) } label: {
                    Label("Extraction settings", systemImage: "list.bullet.indent")
                }
                .labelStyle(.titleAndIcon)
                .help("Look at and correct the rules that derive the series and volume: policies, word rules and word lists")
            }
            ToolbarItem {
                Button { showsDetail.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        .alert("Revert to the proposal?",
               isPresented: Binding(get: { revertingAll != nil }, set: { if !$0 { revertingAll = nil } }),
               presenting: revertingAll) { ids in
            Button("Cancel", role: .cancel) {}
            Button("Revert", role: .destructive) { workspace.revertToProposal(ids) }
        } message: { ids in
            Text(verbatim: "Every correction of %lld books is thrown away, and they go back to what was read from their file names. You can undo this with Undo.".ui(ids.count))
        }
        // 規則の窓で変えた内容を一覧へ届けるのは FlowView(この段が出ていないあいだの変更も届けるため)。
        .navigationTitle(workspace.hasUnsavedChanges ? "qooMeta (unsaved changes)" : "qooMeta")
        .navigationSubtitle(workspace.selection.isEmpty
            ? "%1$lld / %2$lld books".ui(workspace.visibleCount, workspace.books.count)
            : "%1$lld / %2$lld books, %3$lld selected".ui(workspace.visibleCount, workspace.books.count, workspace.selection.count))
    }

    /// 解析の設定の窓を、選んでいる本のルールセットを選んだ状態で開く(選んでいなければ窓の今のまま)。
    private func openParsingSettings() {
        if let first = workspace.selectedBooks.first { PickedForRules.shared.open(ruleSet: workspace.presetName(for: first.id)) }
        openWindow(id: FileNameRulesView.windowID)
    }
}

// MARK: - 絞り込み

/// 一覧の上の絞り込み: ジャンル → 著者(ジャンルで候補が絞られる。値ごとの冊数と「(空)」つき)と、本の状態。
/// **いつも見えている**ので、一覧のどこを見ているかが分かる。どの型にも合わなかった本があれば、その数を右に出し、
/// 押せばそれだけを出す(読めなかった本に気づく入口)。
struct FilterBar: View {
    @Bindable var workspace: Workspace

    private var isFiltering: Bool {
        workspace.genreFilter != nil || workspace.authorFilter != nil || workspace.stateFilter != .all
    }

    var body: some View {
        HStack(spacing: 16) {
            // **値の一覧は、開いたときに作る。** 書き手は千を超えることがあり、Picker だと画面を描くたびに
            // その数だけ項目を組み立てる(2026-09-21、利用者の報告。列を動かすと main が詰まっていた)。
            ValueFilterMenu(title: "Genre", values: workspace.genreValues, selection: workspace.genreFilter) {
                workspace.setGenreFilter($0)
            }
            ValueFilterMenu(title: "Authors", values: workspace.authorValues, selection: workspace.authorFilter) {
                workspace.authorFilter = $0
            }
            Picker("Show", selection: $workspace.stateFilter) {
                ForEach(Workspace.StateFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if isFiltering {
                Button("Clear the filters") {
                    workspace.setGenreFilter(nil)
                    workspace.authorFilter = nil
                    workspace.stateFilter = .all
                }
                .buttonStyle(.link)
            }
            Spacer()
            if workspace.unmatchedCount > 0, workspace.stateFilter != .unmatched {
                Button { workspace.stateFilter = .unmatched } label: {
                    Label("%lld books matched no format".ui(workspace.unmatchedCount), systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("Shows only the books whose file names matched no format of their rule set. Right-click them to read them with another rule set")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 値で絞り込むメニュー(ジャンル・著者)。中身は**押して開いたときに作る** ―― 値が千を超えても、
/// 画面を描くたびに項目を組み立てないため。
struct ValueFilterMenu: View {
    var title: LocalizedStringKey
    var values: [(key: ValueKey, count: Int)]
    var selection: ValueKey?
    var pick: (ValueKey?) -> Void

    var body: some View {
        Menu {
            Button("All") { pick(nil) }
            Divider()
            ForEach(values, id: \.key) { row in
                Button { pick(row.key) } label: {
                    Text(verbatim: "%1$@ (%2$lld)".ui(row.key.label, row.count))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(verbatim: selection?.label ?? "All".ui)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

// MARK: - 一覧

/// 右クリックから開く、値を入れるシート。
enum EditSheet: Identifiable {
    /// 選んだ本を 1 つのシリーズにする(名前を入れる)。
    case series(Set<String>)
    /// 選んだ本に一覧の順で巻を振る。
    case numbering([String])
    /// 選んだ本の欄をまとめて同じ値にする。
    case field(BookMetadata.Field, Set<String>)

    var id: String {
        switch self {
        case .series(let ids): "series-\(ids.sorted().joined(separator: "\u{1}"))"
        case .numbering(let ids): "numbering-\(ids.joined(separator: "\u{1}"))"
        case .field(let field, let ids): "field-\(field.rawValue)-\(ids.sorted().joined(separator: "\u{1}"))"
        }
    }
}

/// 1 冊 1 行の一覧。**ファイル名のほかの欄は、セルを 2 回押せばその場で直せる**(右の詳細を開かなくてよい。
/// 2026-09-22、利用者の指示)。1 回押しはこれまでどおり行を選ぶだけなので、選んでまとめて直す道も残る。
/// 巻数(並べ替え用)も直せる(並びの位置だけを直す)。ファイル名の列は読むだけ。
/// 選んだ本をまとめて直す操作は、右の詳細か、行の右クリックから。
struct BookTableView: View {
    @Bindable var workspace: Workspace
    @State private var sheet: EditSheet?

    /// 列の既定の並び(利用者の指示 2026-09-21)。左から ファイル名・ジャンル・著者・タイトル・シリーズ・
    /// 巻数(表示)・巻数(並べ替え用)・原作・イベント・情報。**書いた順がそのまま画面の順**なので、
    /// 巻数(並べ替え用)を挟むために欄の列を 2 つに分ける。並べ替え・表示する列の選択は利用者が変えられる。
    nonisolated static let columns: [BookMetadata.Field] = [.genre, .authors, .title, .series, .volume]
    nonisolated static let columnsAfterVolume: [BookMetadata.Field] = [.source, .event, .info]

    /// 欄ごとの幅。**中身に合わせた自動調整は Table に無い**ので、欄ごとに決める(2026-09-21、利用者の指摘)。
    /// 短い欄には上限を付ける ―― 上限が無いと、余った幅をどの列も等分に受け取り、3 文字のジャンルの列が
    /// 名前の列と同じくらい広くなる。広がってほしいのは、ファイル名・タイトル・シリーズ・著者だけ。
    nonisolated static func width(_ field: BookMetadata.Field) -> (min: CGFloat, ideal: CGFloat, max: CGFloat?) {
        switch field {
        case .genre: (56, 88, 160)
        case .authors: (80, 160, nil)
        case .title: (120, 240, nil)
        case .series: (100, 180, nil)
        case .volume: (40, 72, 140)
        case .source: (70, 130, 220)
        case .event: (56, 100, 200)
        case .info: (56, 110, 220)
        }
    }

    var body: some View {
        // 表は AppKit の NSTableView(`BookTable`。SwiftUI の Table をやめた理由はそちらに)。
        // 並べ替えた結果は Workspace が作り置きしている(ここで並べ替えると、描くたびに 1 万冊を並べ直すことになる)。
        BookTable(books: workspace.books, positions: workspace.visiblePositions, selection: $workspace.selection, sortOrder: $workspace.sortOrder,
                  canEdit: canEdit, isEdited: isEdited, help: help, commit: commit,
                  contextMenu: contextMenu, rootPath: workspace.rootPath)
        .modifier(HideTopScrollEdgeEffect())
        .sheet(item: $sheet) { sheet in
            EditSheetView(sheet: sheet, workspace: workspace) { name, ids in
                SeriesNaming.apply(name, to: ids, in: workspace)
            }
        }
    }

    /// 巻数(表示・並べ替え用とも)は、シリーズ名の決まっている本にしか入らない(シリーズの中の番号なので)。
    /// 巻数(並べ替え用)は、巻の表記が空の本にも入る。
    private func canEdit(_ column: BookTable.Column, _ book: BookRow) -> Bool {
        switch column {
        case .field(.volume), .volumeSort: !Workspace.currentSeriesName(book).isEmpty
        case .field: true
        case .fileName: false
        }
    }

    private func isEdited(_ column: BookTable.Column, _ book: BookRow) -> Bool {
        switch column {
        case .field(.series), .field(.volume): book.hasConfirmedSeries
        case .field(let field): book.edited.contains(field)
        case .volumeSort: book.hasConfirmedVolumeSort
        case .fileName: false
        }
    }

    private func help(_ column: BookTable.Column, _ book: BookRow) -> String {
        guard canEdit(column, book) else { return "Give the book a series name first".ui }
        guard case .field(let field) = column else {
            return "Double-click to set this book’s position in the series. Empty goes back to the number read from the volume".ui
        }
        switch field {
        case .series: return "Double-click to settle the series for this book. Empty puts it in no series".ui
        case .volume: return "Double-click to settle the volume for this book. Empty clears it".ui
        case .authors: return "Double-click to edit. Several authors are separated by 、".ui
        default: return "Double-click to edit this book’s value".ui
        }
    }

    /// 直した値の入れ先は、詳細の欄と同じ口(取り消しも同じ 1 手)。**押した 1 冊だけ**に入る
    /// ―― まとめて直すのは、選んでから右の詳細か右クリックで(2026-09-22、利用者と決めた分担)。
    private func commit(_ column: BookTable.Column, _ value: String, for book: BookRow) {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard case .field(let field) = column else {
            guard column == .volumeSort else { return }
            guard !text.isEmpty else { return workspace.setVolumeSort(nil, for: [book.id]) }
            // 全角の数字・小数点でも入るように、揃えてから読む。数に読めなければ何もしない(元の値のまま)。
            guard let number = Workspace.volumeSortNumber(text) else { return NSSound.beep() }
            return workspace.setVolumeSort(number, for: [book.id])
        }
        switch field {
        case .series:
            guard !text.isEmpty else { return workspace.removeFromSeries([book.id]) }
            SeriesNaming.apply(text, to: [book.id], in: workspace)
        case .volume:
            if text.isEmpty { workspace.clearVolumes([book.id]) } else { workspace.setVolumes(text, for: [book.id]) }
        case .authors:
            workspace.set(field, to: text.split(whereSeparator: { "、,，".contains($0) }).map(String.init), for: [book.id])
        default:
            workspace.set(field, to: [text], for: [book.id])
        }
    }

    // MARK: 右クリック

    /// 右クリックのメニュー。1 冊だけでも複数でも同じ並び(その場で意味の無い項目は淡色)。
    private func contextMenu(_ ids: Set<String>) -> [BookTable.MenuItem] {
        typealias Item = BookTable.MenuItem
        let books = ids.compactMap(workspace.row)
        // 一覧の順(連番はこの順に振る)。
        let ordered = workspace.rows.map(\.id).filter { ids.contains($0) }
        let withSeries = books.contains { !Workspace.currentSeriesName($0).isEmpty }

        var items: [Item] = []
        // シリーズと巻
        items.append(Item(title: "Make Into One Series…".ui) { sheet = .series(ids) })
        items.append(Item(title: "Number the Volumes…".ui, isEnabled: ordered.count > 1 && withSeries) {
            sheet = .numbering(ordered)
        })
        items.append(Item(title: "Confirm Series and Volume".ui) { workspace.acceptProposedSeries(ids) })
        items.append(Item(title: "Remove From Series".ui) { workspace.removeFromSeries(ids) })
        items.append(Item(title: "Clear Volume".ui, isEnabled: withSeries) { workspace.clearVolumes(ids) })
        items.append(Item(title: "Revert Series to Proposal".ui,
                          isEnabled: books.contains { $0.hasConfirmedSeries || $0.hasConfirmedVolumeSort }) {
            workspace.revertSeries(ids)
        })
        items.append(.separator)
        // 欄。シリーズと巻も並べる(中身は一覧の欄を直に直したときと同じ ―― シリーズは確定した名前、空ならシリーズから外す。
        // 巻はシリーズ名のある本だけ)。
        let fields: [BookMetadata.Field] = [.title, .authors, .series, .volume, .genre, .event, .source, .info]
        items.append(Item(title: "Change a Field".ui, children: fields.map { field in
            Item(title: field.labelKey.ui + "…") { sheet = .field(field, ids) }
        }))
        items.append(Item(title: "Revert to Proposal".ui, isEnabled: !workspace.correctedIDs(in: ids).isEmpty) {
            workspace.revertToProposal(ids)
        })
        items.append(.separator)
        // 読むルールセットを替えて読み直す(型に合わなかった本を、ほかのルールセットで読む入口)。
        let current = Set(ids.map(workspace.presetName))
        items.append(Item(title: "Parse the File Name Again With".ui,
                          children: workspace.rules.presetCatalog.entries.map { entry in
            // いまのルールセットに印を付ける(選んだ本で分かれていれば、半分の印)。
            Item(title: entry.preset.displayName,
                 state: current.contains(entry.id) ? (current.count == 1 ? .on : .mixed) : .off) {
                workspace.reparse(ids, with: entry.id)
            }
        }))
        items.append(.separator)
        // どこにある本かを辿れるように。見つからない本は、残っているいちばん近いフォルダを開く。
        items.append(Item(title: "Show in Finder".ui) { showInFinder(ids) })
        items.append(Item(title: "Copy File Name".ui) {
            let names = ordered.map { (($0 as NSString).lastPathComponent) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        })
        return items
    }

    /// 「Finder で表示」。ある本は Finder で選び、見つからない本(名前を変えた・消した・つながっていないボリューム)は、
    /// 残っているいちばん近いフォルダを開く。
    private func showInFinder(_ ids: Set<String>) {
        let urls = ids.sorted().map { URL(fileURLWithPath: (workspace.rootPath as NSString).appendingPathComponent($0)) }
        let found = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !found.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(found)
            return
        }
        var folders: [URL] = []
        for url in urls {
            var folder = url.deletingLastPathComponent()
            while folder.path != "/" && !FileManager.default.fileExists(atPath: folder.path) {
                folder = folder.deletingLastPathComponent()
            }
            if folder.path != "/", !folders.contains(folder) { folders.append(folder) }
        }
        guard !folders.isEmpty else { return NSSound.beep() }
        for folder in folders { NSWorkspace.shared.open(folder) }
    }
}

/// シリーズ名を入れる口(一覧のセル・右クリックのシート)。**選んでいない本が巻き込まれるときだけ**、入れる前に数を見せて
/// 確かめる(確定した名前は錨なので、同じ単位のほかの本もそのシリーズへ寄る)。
///
/// 確かめは **AppKit の `NSAlert` を窓のシートとして出す**。SwiftUI の `.alert` では、巻のある本のシリーズ名をセルで書き換えて
/// Return を押しても確かめが出ず、名前が元のままだった(qooViewer へ移したこの画面で、利用者が見つけた)。表の書き換え
/// (AppKit)から続く確かめなので、AppKit で出す。
@MainActor
enum SeriesNaming {
    static func apply(_ name: String, to ids: Set<String>, in workspace: Workspace) {
        Task { @MainActor in
            let preview = await workspace.previewSetSeries(name, for: ids)
            guard preview.others > 0 else { return workspace.setSeries(name, for: ids) }
            let alert = NSAlert()
            alert.messageText = "Set the series to “%@”?".ui(name)
            alert.informativeText = "This also changes %1$lld books you did not pick: %2$lld gain a series and %3$lld lose one."
                .ui(preview.others, preview.gained, preview.lost)
            alert.addButton(withTitle: "Apply anyway".ui)
            alert.addButton(withTitle: "Cancel".ui)
            WindowSheet.begin(alert) { response in
                if response == .alertFirstButtonReturn { workspace.setSeries(name, for: ids) }
            }
        }
    }
}

// MARK: - 右クリックから開くシート

/// 右クリックから開く小さなシート(シリーズ名・連番・欄の値)。
struct EditSheetView: View {
    let sheet: EditSheet
    @Bindable var workspace: Workspace
    /// シリーズ名を入れる(巻き込みの確かめは呼び出し側)。
    let applySeries: (String, Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var start = 1
    @State private var width = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.headline)
            content
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // 確定のボタンは、何をするかの動詞(「OK」にしない)。
                Button("Apply") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prepare)
    }

    private var title: String {
        switch sheet {
        case .series(let ids): "Make %lld Books One Series".ui(ids.count)
        case .numbering(let ids): "Number %lld Books".ui(ids.count)
        case .field(let field, let ids): "Change %1$@ of %2$lld Books".ui(field.labelKey.ui, ids.count)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .series(let ids):
            TextField("Series name", text: $text, prompt: Text(verbatim: workspace.suggestedSeriesName(for: ids) ?? ""))
                .textFieldStyle(.roundedBorder)
            Text("Leave it empty to use the suggested name.").font(.caption).foregroundStyle(.secondary)
        case .numbering:
            Stepper(value: $start, in: 0...9999) { Text(verbatim: "Start at %lld".ui(start)) }
            Stepper(value: $width, in: 0...4) { Text(verbatim: "Digits %lld".ui(width)) }
            Text("Numbers the books in the order the list shows them. Books with no series name are left alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .field(let field, _):
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
            switch field {
            case .series:
                Text("Every book you picked is put in this series. Empty removes them from their series.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .volume:
                Text("Every book you picked gets this volume. Books with no series name are left alone. Empty clears the volume.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if field == .authors {
                    Text("Separate several authors with 、").font(.caption).foregroundStyle(.secondary)
                }
                Text("Every book you picked gets this value. Empty clears the field.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canApply: Bool {
        switch sheet {
        case .series(let ids): !text.trimmingCharacters(in: .whitespaces).isEmpty || workspace.suggestedSeriesName(for: ids) != nil
        default: true
        }
    }

    /// 欄の値の初期値は、選んだ本で揃っていればその値。
    private func prepare() {
        guard case .field(let field, let ids) = sheet else { return }
        let values = Set(ids.compactMap { workspace.row($0)?.metadata.values(field) })
        if values.count == 1, let value = values.first { text = value.joined(separator: "、") }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch sheet {
        case .series(let ids):
            let name = trimmed.isEmpty ? (workspace.suggestedSeriesName(for: ids) ?? "") : trimmed
            if !name.isEmpty { applySeries(name, ids) }
        case .numbering(let ids):
            workspace.numberSequentially(ids, start: start, width: width)
        case .field(.series, let ids):
            // 選んでいない本が巻き込まれるときの確かめは、シリーズにまとめるときと同じ(`applySeries`)。
            if trimmed.isEmpty { workspace.removeFromSeries(ids) } else { applySeries(trimmed, ids) }
        case .field(.volume, let ids):
            if trimmed.isEmpty { workspace.clearVolumes(ids) } else { workspace.setVolumes(trimmed, for: ids) }
        case .field(let field, let ids):
            let values = field == .authors
                ? trimmed.split(whereSeparator: { "、,，".contains($0) }).map(String.init) : [trimmed]
            workspace.set(field, to: values, for: ids)
        }
    }
}

/// 表の上の「ふち」の効果(macOS 26 から)を消す。段のバーの下に暗い帯が掛かり、表の見出しが読めなくなる
/// ―― 窓の上に自前の帯(段のバー)を置いているため(2026-09-21、実機で確かめた)。
struct HideTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .top) } else { content }
    }
}

extension BookMetadata.Field {
    /// 画面に出す言葉の鍵(英語)。訳は Localizable.xcstrings。
    var labelKey: String {
        switch self {
        case .title: "Title"
        case .authors: "Authors"
        case .genre: "Genre"
        case .event: "Event"
        case .source: "Source work"
        case .info: "Info"
        case .series: "Series"
        case .volume: "Volume (as written)"
        }
    }
}
