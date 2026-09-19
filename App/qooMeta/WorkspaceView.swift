import QooMetaKit
import SwiftUI

/// 1 つの窓: 一覧が中心で、上に絞り込みの帯、右に詳細(選んだ本のメタデータを直す)。
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var showsDetail = true

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
            ToolbarItem {
                Button { showsDetail.toggle() } label: { Label("詳細", systemImage: "sidebar.right") }
            }
        }
        .navigationTitle("qooMeta")
        .navigationSubtitle("\(workspace.visibleBooks.count) / \(workspace.books.count) 冊")
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
    static let columns: [BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .series, .volume,
                                                .keywordA, .keywordB, .keywordC]

    var body: some View {
        // 列は Group でまとめない(Group に入れた列は見出しを押しても並べ替わらない)。欄の列は TableColumnForEach で作る。
        Table(workspace.visibleBooks.sorted(using: sortOrder), selection: $workspace.selection, sortOrder: $sortOrder,
              columnCustomization: $customization) {
            TableColumn("ファイル名", value: \BookRow.fileName)
                .width(min: 160, ideal: 360)
                .customizationID("fileName")
                .disabledCustomizationBehavior(.visibility)
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
        case .keywordA: "キーワード A"
        case .keywordB: "キーワード B"
        case .keywordC: "キーワード C"
        case .memo: "メモ"
        case .series: "シリーズ"
        case .volume: "巻"
        }
    }
}
