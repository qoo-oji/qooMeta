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
                Button { openWindow(id: RulesEditorView.windowID) } label: { Label("Rules", systemImage: "list.bullet.indent") }
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

/// 1 冊 1 行の一覧。セルでは編集しない(直すのは右の詳細で)。ファイル名の列は隠せない。
struct BookTableView: View {
    @Bindable var workspace: Workspace
    @State private var sortOrder = [KeyPathComparator(\BookRow.fileName)]
    @State private var customization = TableColumnCustomization<BookRow>()

    /// ファイル名のほかの列(どれも見出しで昇順・降順に並べ替えられる)。
    static let columns: [BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info, .series, .volume]

    var body: some View {
        // 列は Group でまとめない(Group に入れた列は見出しを押しても並べ替わらない)。欄の列は TableColumnForEach で作る。
        Table(workspace.visibleBooks.sorted(using: sortOrder), selection: $workspace.selection, sortOrder: $sortOrder,
              columnCustomization: $customization) {
            TableColumn("File name", value: \BookRow.fileName)
                .width(min: 160, ideal: 360)
                .customizationID("fileName")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Volume (for sorting)", value: \BookRow[sortKey: .volume]) { book in
                Text(book.volumeSortText)
            }
            .width(min: 60, ideal: 90)
            .customizationID("volumeSort")
            TableColumnForEach(Self.columns, id: \.self) { field in
                TableColumn(LocalizedStringKey(field.labelKey), sortUsing: KeyPathComparator(\BookRow[sortKey: field])) { book in
                    Text(book[text: field])
                }
                .width(min: field == .volume ? 40 : 80, ideal: field == .volume ? 60 : field == .title ? 200 : 140)
                .customizationID(field.rawValue)
            }
        }
        .modifier(HideTopScrollEdgeEffect())
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
