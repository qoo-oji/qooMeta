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
                    Label("Extraction settings", systemImage: "list.bullet.indent")
                }
                // 絵だけでは何の窓が開くか分からない(2026-09-20、利用者の指摘)。名前も出す。
                .labelStyle(.titleAndIcon)
                .help("Look at and correct the rules that derive the series and volume: policies, word rules and word lists")
            }
            ToolbarItem {
                Button { showsDetail.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        // 規則の窓で変えた内容を一覧へ届けるのは FlowView(この段が出ていないあいだの変更も届けるため)。
        .navigationTitle(workspace.hasUnsavedChanges ? "qooMeta (unsaved changes)" : "qooMeta")
        .navigationSubtitle("%1$lld / %2$lld books".ui(workspace.visibleCount, workspace.books.count))
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

/// 1 冊 1 行の一覧。**ファイル名のほかの欄は、セルを 2 回押せばその場で直せる**(右の詳細を開かなくてよい。
/// 2026-09-22、利用者の指示)。1 回押しはこれまでどおり行を選ぶだけなので、選んでまとめて直す道も残る。
/// ファイル名の列と巻数(ソート用)は読むだけ ―― どちらも直に持つ値ではなく、名前と規則から導いたもの。
struct BookTableView: View {
    @Bindable var workspace: Workspace
    /// シリーズ名を直したとき、選んでいない本まで動くなら、入れる前に確かめる(詳細の「1 つにする」と同じ)。
    @State private var pendingSeries: PendingSeries?

    struct PendingSeries: Identifiable {
        let id: String
        let name: String
        let preview: Workspace.SeriesChangePreview
    }

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
                  ruleSets: { workspace.rules.presetCatalog.entries.map { ($0.id, $0.preset.displayName) } },
                  ruleSetOf: { workspace.presetName(for: $0) },
                  reparse: { workspace.reparse($0, with: $1) })
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
