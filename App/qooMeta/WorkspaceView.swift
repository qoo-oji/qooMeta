import QooMetaKit
import SwiftUI

/// 1 つの窓: 一覧が中心で、上に絞り込みの帯、右に詳細(選んだ本のメタデータを直す)。
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var showsDetail = true
    @State private var showsPresets = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(workspace: workspace)
            Divider()
            BookTableView(workspace: workspace)
        }
        .inspector(isPresented: $showsDetail) {
            DetailView(workspace: workspace)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        .searchable(text: $workspace.searchText, placement: .toolbar, prompt: "欄とファイル名を検索")
        .toolbar {
            if workspace.isWorking {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
            ToolbarItem {
                Button { showsPresets = true } label: { Label("型の並び", systemImage: "folder.badge.gearshape") }
                    .help("フォルダごとに、どの型の並びで名前を読むかを決める")
            }
            ToolbarItem {
                Button { showsDetail.toggle() } label: { Label("詳細", systemImage: "sidebar.right") }
            }
        }
        .sheet(isPresented: $showsPresets) { PresetAssignmentView(workspace: workspace) }
        .navigationTitle(workspace.hasUnsavedChanges ? "qooMeta(未保存の変更)" : "qooMeta")
        .navigationSubtitle("\(workspace.visibleBooks.count) / \(workspace.books.count) 冊")
    }
}

// MARK: - フォルダごとの型の並び

/// フォルダごとに、どの型の並び(プリセット)で名前を読むかを決める。
/// 同人誌と商業の本が混ざった蔵書のために、**本ごとにプリセットを選べる**(割り当ては作業ファイルに残る)。
struct PresetAssignmentView: View {
    @Bindable var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("型の並び(プリセット)").font(.headline)
            Text("フォルダごとに、ファイル名をどの型の並びで読むかを決めます。割り当てを変えると、そのフォルダの本を読み直します。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("既定", selection: Binding(get: { workspace.presets.defaultPreset },
                                                 set: { workspace.setPreset($0, forFolder: nil) })) {
                    Text("同梱の既定(\(workspace.formats.defaultName))").tag(String?.none)
                    ForEach(workspace.formats.names, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                if workspace.topLevelFolders.isEmpty {
                    Text("直下のフォルダはありません(すべて既定で読みます)").foregroundStyle(.secondary)
                } else {
                    Section("直下のフォルダ") {
                        ForEach(workspace.topLevelFolders, id: \.folder) { row in
                            Picker("\(row.folder)(\(row.count) 冊)",
                                   selection: Binding(get: { workspace.presets.folders[row.folder] },
                                                      set: { workspace.setPreset($0, forFolder: row.folder) })) {
                                Text("既定に従う").tag(String?.none)
                                ForEach(workspace.formats.names, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }
}

// MARK: - 絞り込み

/// 一覧の上の絞り込み: ジャンル → 著者(ジャンルで候補が絞られる。値ごとの冊数と「(空)」つき)と、本の状態。
struct FilterBar: View {
    @Bindable var workspace: Workspace

    var body: some View {
        HStack(spacing: 16) {
            Picker("ジャンル", selection: Binding(get: { workspace.genreFilter }, set: { workspace.setGenreFilter($0) })) {
                Text("すべて").tag(ValueKey?.none)
                ForEach(workspace.genreValues, id: \.key) { row in
                    Text("\(row.key.label)(\(row.count))").tag(ValueKey?.some(row.key))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("著者", selection: $workspace.authorFilter) {
                Text("すべて").tag(ValueKey?.none)
                ForEach(workspace.authorValues, id: \.key) { row in
                    Text("\(row.key.label)(\(row.count))").tag(ValueKey?.some(row.key))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("表示", selection: $workspace.stateFilter) {
                ForEach(Workspace.StateFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
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
            TableColumn("ファイル名", value: \BookRow.fileName)
                .width(min: 160, ideal: 360)
                .customizationID("fileName")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("巻数(ソート)", value: \BookRow[sortKey: .volume]) { book in
                Text(book.volumeSortText)
            }
            .width(min: 60, ideal: 90)
            .customizationID("volumeSort")
            TableColumnForEach(Self.columns, id: \.self) { field in
                TableColumn(field.label, sortUsing: KeyPathComparator(\BookRow[sortKey: field])) { book in
                    Text(book[text: field])
                }
                .width(min: field == .volume ? 40 : 80, ideal: field == .volume ? 60 : field == .title ? 200 : 140)
                .customizationID(field.rawValue)
            }
        }
    }
}

extension BookMetadata.Field {
    var label: String {
        switch self {
        case .title: "タイトル"
        case .authors: "著者"
        case .genre: "ジャンル"
        case .event: "イベント"
        case .source: "原作"
        case .info: "情報"
        case .series: "シリーズ"
        case .volume: "巻数(表示)"
        }
    }
}
