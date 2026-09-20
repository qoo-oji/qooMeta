import QooMetaKit
import SwiftUI

/// 1 つの窓: 一覧が中心で、上に絞り込みの帯、右に詳細(選んだ本のメタデータを直す)。
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var settings: AppSettings
    @State private var showsDetail = true
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
                Button { openWindow(id: SeriesRulesView.windowID) } label: {
                    Label("Series and volume extraction", systemImage: "list.bullet.indent")
                }
                // 絵だけでは何の窓が開くか分からない(2026-09-20、利用者の指摘)。名前も出す。
                .labelStyle(.titleAndIcon)
                .help("Look at and correct the rules that derive the series and volume: policies, word rules and word lists")
            }
            ToolbarItem {
                Button { showsDetail.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        // 規則の窓で変えた内容は、開いている一覧にすぐ効かせる(すべての本を読み直す)。
        .onChange(of: settings.rules.contentHash) { Task { await workspace.setRules(settings.rules) } }
        .navigationTitle(workspace.hasUnsavedChanges ? "qooMeta (unsaved changes)" : "qooMeta")
        .navigationSubtitle("%1$lld / %2$lld books".ui(workspace.visibleBooks.count, workspace.books.count))
    }
}

// MARK: - 絞り込み

/// 一覧の上の絞り込み: ジャンル → 著者(ジャンルで候補が絞られる。値ごとの冊数と「(空)」つき)と、本の状態。
/// **いつも見えている**ので、一覧のどこを見ているかが分かる。
struct FilterBar: View {
    @Bindable var workspace: Workspace

    private var isFiltering: Bool {
        workspace.genreFilter != nil || workspace.authorFilter != nil || workspace.stateFilter != .all
    }

    var body: some View {
        HStack(spacing: 16) {
            Picker("Genre", selection: Binding(get: { workspace.genreFilter },
                                               set: { workspace.setGenreFilter($0) })) {
                Text("All").tag(ValueKey?.none)
                ForEach(workspace.genreValues, id: \.key) { row in
                    Text(verbatim: "%1$@ (%2$lld)".ui(row.key.label, row.count)).tag(ValueKey?.some(row.key))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Authors", selection: $workspace.authorFilter) {
                Text("All").tag(ValueKey?.none)
                ForEach(workspace.authorValues, id: \.key) { row in
                    Text(verbatim: "%1$@ (%2$lld)".ui(row.key.label, row.count)).tag(ValueKey?.some(row.key))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 一覧

/// 1 冊 1 行の一覧。**ファイル名のほかの欄は、セルを 2 回押せばその場で直せる**(右の詳細を開かなくてよい。
/// 2026-09-22、利用者の指示)。1 回押しはこれまでどおり行を選ぶだけなので、選んでまとめて直す道も残る。
/// ファイル名の列と巻数(ソート用)は読むだけ ―― どちらも直に持つ値ではなく、名前と規則から導いたもの。
struct BookTableView: View {
    @Bindable var workspace: Workspace
    @State private var customization = TableColumnCustomization<BookRow>()
    /// シリーズ名を直したとき、選んでいない本まで動くなら、入れる前に確かめる(詳細の「1 つにする」と同じ)。
    @State private var pendingSeries: PendingSeries?

    struct PendingSeries: Identifiable {
        let id: String
        let name: String
        let preview: Workspace.SeriesChangePreview
    }

    /// ファイル名のほかの列(どれも見出しで昇順・降順に並べ替えられる)。
    static let columns: [BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info, .series, .volume]

    var body: some View {
        // 列は Group でまとめない(Group に入れた列は見出しを押しても並べ替わらない)。欄の列は TableColumnForEach で作る。
        // 並べ替えた結果は Workspace が作り置きしている(ここで並べ替えると、描くたびに 1 万冊を並べ直すことになる)。
        Table(workspace.rows, selection: $workspace.selection, sortOrder: $workspace.sortOrder,
              columnCustomization: $customization) {
            TableColumn("File name", value: \BookRow.fileName)
                .width(min: 160, ideal: 360)
                .customizationID("fileName")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Volume (for sorting)", value: \BookRow[sortKey: .volume]) { book in
                Text(book.volumeSortText)
                    .help("Derived from the volume as written, by the rules for reading a volume")
            }
            .width(min: 60, ideal: 90)
            .customizationID("volumeSort")
            TableColumnForEach(Self.columns, id: \.self) { field in
                TableColumn(LocalizedStringKey(field.labelKey), sortUsing: KeyPathComparator(\BookRow[sortKey: field])) { book in
                    EditableCell(text: book[text: field], isEdited: isEdited(field, book),
                                 canEdit: canEdit(field, book), help: help(field, book)) { value in
                        commit(field, value, for: book)
                    }
                }
                .width(min: field == .volume ? 40 : 80, ideal: field == .volume ? 60 : field == .title ? 200 : 140)
                .customizationID(field.rawValue)
            }
        }
        .modifier(HideTopScrollEdgeEffect())
        .alert(item: $pendingSeries) { pending in
            Alert(title: Text("Set the series to “%@”?".ui(pending.name)),
                  message: Text("This also changes %1$lld books you did not pick: %2$lld gain a series and %3$lld lose one."
                      .ui(pending.preview.others, pending.preview.gained, pending.preview.lost)),
                  primaryButton: .default(Text("Apply anyway")) {
                      workspace.setSeries(pending.name, for: [pending.id])
                  },
                  secondaryButton: .cancel())
        }
    }

    /// 巻数は、シリーズ名の決まっている本にしか入らない(シリーズの中の番号なので)。
    private func canEdit(_ field: BookMetadata.Field, _ book: BookRow) -> Bool {
        field != .volume || !Workspace.currentSeriesName(book).isEmpty
    }

    private func isEdited(_ field: BookMetadata.Field, _ book: BookRow) -> Bool {
        field == .series || field == .volume ? book.hasConfirmedSeries : book.edited.contains(field)
    }

    private func help(_ field: BookMetadata.Field, _ book: BookRow) -> String {
        guard canEdit(field, book) else { return "Give the book a series name first".ui }
        switch field {
        case .series: return "Double-click to settle the series for this book. Empty puts it in no series".ui
        case .volume: return "Double-click to settle the volume for this book. Empty clears it".ui
        case .authors: return "Double-click to edit. Several authors are separated by 、".ui
        default: return "Double-click to edit this book’s value".ui
        }
    }

    /// 直した値の入れ先は、詳細の欄と同じ口(取り消しも同じ 1 手)。**押した 1 冊だけ**に入る
    /// ―― まとめて直すのは、選んでから右の詳細で(2026-09-22、利用者と決めた分担)。
    private func commit(_ field: BookMetadata.Field, _ value: String, for book: BookRow) {
        let text = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .series:
            guard !text.isEmpty else { return workspace.removeFromSeries([book.id]) }
            Task {
                let preview = await workspace.previewSetSeries(text, for: [book.id])
                if preview.others > 0 {
                    pendingSeries = PendingSeries(id: book.id, name: text, preview: preview)
                } else {
                    workspace.setSeries(text, for: [book.id])
                }
            }
        case .volume:
            if text.isEmpty { workspace.clearVolumes([book.id]) } else { workspace.setVolumes(text, for: [book.id]) }
        case .authors:
            workspace.set(field, to: text.split(whereSeparator: { "、,，".contains($0) }).map(String.init), for: [book.id])
        default:
            workspace.set(field, to: [text], for: [book.id])
        }
    }
}

/// 一覧のセル 1 つ。ふだんは文字を出し、**2 回押すと書き換えに入る**(1 回押しは行を選ぶだけ ―― いつでも
/// 書き換えられる欄にすると、行を選ぶのが難しくなる)。Return とほかへ移ったときに入り、Esc で元へ戻る。
private struct EditableCell: View {
    var text: String
    /// 利用者が直した(確定した)欄。提案のままの値と見分ける。
    var isEdited: Bool
    var canEdit: Bool
    var help: String
    var commit: (String) -> Void

    @State private var draft: String?
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if let draft {
                TextField("", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onAppear { editing = true }
                    .onSubmit { finish(keeping: true) }
                    .onExitCommand { finish(keeping: false) }
                    .onChange(of: editing) { _, now in if !now { finish(keeping: true) } }
            } else {
                Text(text)
                    .foregroundStyle(isEdited ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if canEdit { draft = text } }
            }
        }
        .help(help)
    }

    private func finish(keeping: Bool) {
        guard let value = draft else { return }
        draft = nil
        if keeping, value.trimmingCharacters(in: .whitespaces) != text { commit(value) }
    }
}

/// 表の上の「ふち」の効果(macOS 26 から)を消す。段のバーの下に暗い帯が掛かり、表の見出しが読めなくなる
/// ―― 窓の上に自前の帯(段のバー)を置いているため(2026-09-21、実機で確かめた)。
private struct HideTopScrollEdgeEffect: ViewModifier {
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
