import QooMetaKit
import SwiftUI

/// 詳細。1 冊ならファイル名のどこがどの欄か(色分け)と一致した型を、複数ならまとめて書き換える欄を出す。
/// 揃わない欄は「<複数値>」で、入力すると選んだ全冊のその欄を置き換える(StackNest の詳細ペインと同じ)。
struct DetailView: View {
    @Bindable var workspace: Workspace
    @Bindable var settings: AppSettings

    /// 利用者が書き換えられる欄。シリーズと巻は中核が導く(シリーズの操作は段階 7)。
    static let editableFields: [BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info]

    var body: some View {
        let books = workspace.selectedBooks
        if books.isEmpty {
            ContentUnavailableView("Select a book", systemImage: "book.closed",
                                   description: Text("Pick a book in the list and its details appear here. Pick several and you can change them together."))
        } else {
            Form {
                Section {
                    if books.count == 1, let book = books.first {
                        FileNameView(book: book, formats: workspace.formats(for: book.id))
                    } else {
                        Text("%lld books selected".ui(books.count)).font(.headline)
                    }
                }
                Section {
                    ForEach(Self.editableFields, id: \.self) { field in
                        FieldEditor(workspace: workspace, field: field, books: books)
                    }
                }
                StampSection(workspace: workspace, settings: settings, books: books)
                SeriesSection(workspace: workspace, books: books)
            }
            .formStyle(.grouped)
            // 選択が変わったら、入力中の値を捨てる。
            .id(books.map(\.id))
        }
    }

    func uniformSort(_ books: [BookRow]) -> String? {
        let values = Set(books.map(\.volumeSortText))
        return values.count == 1 ? values.first! : nil
    }

    func uniform(_ books: [BookRow], _ field: BookMetadata.Field) -> String? {
        let values = Set(books.map { $0.metadata.values(field) })
        return values.count == 1 ? values.first!.joined(separator: "、") : nil
    }
}

/// スタンプ: よく使う値をまとめて押す。押す先は選んだ本すべて。今の選択から作ることもできる。
struct StampSection: View {
    @Bindable var workspace: Workspace
    @Bindable var settings: AppSettings
    let books: [BookRow]
    @State private var newName = ""
    @State private var showsNew = false

    var ids: Set<BookRow.ID> { Set(books.map(\.id)) }

    var body: some View {
        Section("Stamps") {
            if settings.stamps.isEmpty {
                Text("Turn the values you use often, such as a genre or a source work, into a stamp and apply them to the books you picked in one go.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(settings.stamps) { stamp in
                HStack {
                    Button(stamp.name) { workspace.apply(stamp, to: ids) }
                        .help(stamp.summary)
                    Text(stamp.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { settings.stamps.removeAll { $0.id == stamp.id }; settings.save() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this stamp")
                }
            }
            if showsNew {
                HStack {
                    TextField("Name of the stamp", text: $newName).onSubmit(createStamp)
                    Button("Create") { createStamp() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showsNew = false; newName = "" }
                }
            } else {
                Button("Make a stamp from the current values") { showsNew = true }
                    .help("Makes a stamp of the fields that hold the same value across the books you picked, apart from the title")
            }
        }
    }

    /// 選んだ本で値の揃っている欄を、そのままスタンプにする(タイトルは本ごとに違うので入れない)。
    func createStamp() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var values: [BookMetadata.Field: [String]] = [:]
        for field in DetailView.editableFields where field != .title {
            let all = Set(books.map { $0.metadata.values(field) })
            guard all.count == 1, let value = all.first, !value.isEmpty else { continue }
            values[field] = value
        }
        settings.stamps.append(Stamp(name: name, values: values))
        settings.save()
        showsNew = false
        newName = ""
    }
}

/// シリーズと巻。規則が導いた値を見せ、1 つにする・外す・巻を確かめる・連番を振る、を選んだ本にまとめてかける。
/// **直した値は確定した内容として中核へ戻す**ので、同じ単位のほかの本の提案も変わる(錨)。
struct SeriesSection: View {
    @Bindable var workspace: Workspace
    let books: [BookRow]
    @State private var name = ""
    @State private var start = 1
    @State private var width = 2
    /// 適用前の確かめ(選んでいない本が巻き込まれるとき)。
    @State private var pending: (name: String, preview: Workspace.SeriesChangePreview)?

    var ids: Set<BookRow.ID> { Set(books.map(\.id)) }
    var confirmedCount: Int { books.filter(\.hasConfirmedSeries).count }

    var body: some View {
        Section("Series and volume") {
            if let pending {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Setting “%1$@” also changes %2$lld books you did not pick. %3$lld of the books you picked change: %4$lld gain a series and %5$lld lose one.".ui(pending.name, pending.preview.others, pending.preview.selected,
                                   pending.preview.gained, pending.preview.lost), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    HStack {
                        Button("Apply anyway") {
                            workspace.setSeries(pending.name, for: ids)
                            name = ""
                            self.pending = nil
                        }
                        Button("Cancel") { self.pending = nil }
                    }
                }
            }
            LabeledContent("Series") {
                HStack(spacing: 6) {
                    Text(uniform(.series) ?? "<several values>")
                    if confirmedCount > 0 {
                        Text(confirmedCount == books.count ? "Confirmed" : "Partly confirmed").font(.caption2).foregroundStyle(.tint)
                    }
                }
            }
            LabeledContent("Volume (as written)", value: uniform(.volume) ?? "<several values>")
            LabeledContent("Volume (for sorting)", value: uniformSort() ?? "<several values>")
            HStack {
                TextField("Series name", text: $name, prompt: Text(workspace.suggestedSeriesName(for: ids) ?? "Series name"))
                    .onSubmit(applyName)
                Button("Make one series") { applyName() }
                    .help("Confirms the books you picked as one series. Leave the field empty to use the suggested name")
            }
            HStack {
                Button("Confirm") { workspace.acceptProposedSeries(ids) }
                    .help("Confirms the proposed series and volume as they are")
                Button("Remove") { workspace.removeFromSeries(ids) }
                    .help("Puts the books in no series at all")
                Button("Clear volume") { workspace.clearVolumes(ids) }
                Button("Revert to the proposal") { workspace.revertSeries(ids) }
                    .disabled(confirmedCount == 0)
            }
            HStack {
                Stepper("Start at %lld".ui(start), value: $start, in: 0...9999)
                Stepper("Digits %lld".ui(width), value: $width, in: 0...4)
                Button("Number them") {
                    workspace.numberSequentially(books.map(\.id), start: start, width: width)
                }
                .help("Numbers the books you picked in the order the list shows them")
            }
        }
    }

    /// 「1 つにする」を押したとき。**選んでいない本が巻き込まれるときだけ**、適用前に数を見せて確かめる
    /// (確定した名前は錨なので、同じ単位のほかの本もそのシリーズへ寄る)。
    func applyName() {
        let text = name.isEmpty ? (workspace.suggestedSeriesName(for: ids) ?? "") : name
        guard !text.isEmpty else { return }
        Task {
            let preview = await workspace.previewSetSeries(text, for: ids)
            if preview.others > 0 {
                pending = (text, preview)
            } else {
                workspace.setSeries(text, for: ids)
                name = ""
            }
        }
    }

    func uniformSort() -> String? {
        let values = Set(books.map(\.volumeSortText))
        return values.count == 1 ? values.first! : nil
    }

    func uniform(_ field: BookMetadata.Field) -> String? {
        let values = Set(books.map { $0.metadata.values(field) })
        return values.count == 1 ? values.first!.joined(separator: "、") : nil
    }
}

/// 1 つの欄。書き換えて Return を押すか、ほかへ移ると、選んだ本すべてのその欄がその値になる。
/// 並びの欄(著者だけ)は、値ごとの入力欄を並べ、足す・消す・並べ替えができる。
/// 選んだ本で値が揃わない欄は「複数の値」と出し、書き換えたときだけ、選んだ本すべてをその値にする。
struct FieldEditor: View {
    @Bindable var workspace: Workspace
    let field: BookMetadata.Field
    let books: [BookRow]

    var ids: Set<BookRow.ID> { Set(books.map(\.id)) }
    /// 選んだ本で揃っている値(揃わなければ nil)。
    var current: [String]? {
        let values = Set(books.map { $0.metadata.values(field) })
        return values.count == 1 ? values.first! : nil
    }

    var body: some View {
        let edited = books.contains { $0.edited.contains(field) }
        LabeledContent {
            if field.isList {
                ListEditor(values: current, placeholder: field.labelKey.ui) { workspace.set(field, to: $0, for: ids) }
            } else {
                SingleEditor(value: current.map { $0.first ?? "" }) { workspace.set(field, to: [$0], for: ids) }
            }
        } label: {
            Text(key: field.labelKey)
            if edited {
                HStack(spacing: 4) {
                    Text("Edited").font(.caption2).foregroundStyle(.tint)
                    Button("Revert") { workspace.revert(field, for: ids) }
                        .buttonStyle(.link).font(.caption2)
                        .help("Back to the value read from the file name")
                }
            }
        }
    }
}

/// 1 つの値の欄。`value` が nil なら、選んだ本で値が揃っていない。
struct SingleEditor: View {
    let value: String?
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(value == nil ? "Several values" : ""))
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onAppear { text = value ?? "" }
    }

    /// 値が変わったときだけ書き換える(揃わない欄を空のまま離れても、何も消さない)。
    func save() {
        if let value, text == value { return }
        if value == nil, text.isEmpty { return }
        commit(text)
    }
}

/// 並びの欄: 値ごとの入力欄。`values` が nil なら、選んだ本で値が揃っていない(書き換えると、全冊をこの並びにする)。
struct ListEditor: View {
    let values: [String]?
    let placeholder: String
    let commit: ([String]) -> Void
    @State private var items: [String] = []
    /// 揃わない欄を書き換え始めたか。
    @State private var replacing = false
    @FocusState private var focusedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if values == nil, !replacing {
                HStack {
                    Text("Several values").foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") { replacing = true; items = [""]; focusedIndex = 0 }
                        .buttonStyle(.link)
                }
            } else {
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        TextField("", text: $items[i], prompt: Text(placeholder))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .focused($focusedIndex, equals: i)
                            .onSubmit(save)
                        Button { items.remove(at: i); save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Delete this value")
                    }
                    .contextMenu {
                        Button("Move up") { items.swapAt(i, i - 1); save() }.disabled(i == 0)
                        Button("Move down") { items.swapAt(i, i + 1); save() }.disabled(i == items.count - 1)
                    }
                }
                // 足すボタンは、消すボタン(各行の右端)と同じ列に置く。
                HStack {
                    Spacer()
                    Button { items.append(""); focusedIndex = items.count - 1 } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a value")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusedIndex) { old, new in if old != nil, new == nil { save() } }
        .onAppear { items = values ?? [] }
    }

    /// 並びが変わったときだけ書き換える(空の値は捨てる)。
    func save() {
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let values, cleaned == values { return }
        if values == nil, cleaned.isEmpty { return }
        commit(cleaned)
    }
}

/// チップを折り返して並べる。
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: Range<Int>, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: Range<Int>, width: CGFloat, height: CGFloat)] = []
        var start = 0, x: CGFloat = 0, height: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if i > start, x + size.width > width {
                rows.append((start..<i, x - spacing, height))
                start = i; x = 0; height = 0
            }
            x += size.width + spacing
            height = max(height, size.height)
        }
        if start < subviews.count { rows.append((start..<subviews.count, x - spacing, height)) }
        return rows
    }
}

// MARK: - ファイル名の色分け

/// ファイル名のどの部分がどの欄になったか(色分け)と、一致した型。
struct FileNameView: View {
    let book: BookRow
    let formats: FilenameFormats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(colored).font(.title3).textSelection(.enabled)
            if let index = book.reading.formatIndex {
                Label("Format %1$lld: %2$@".ui(index + 1, formats.formats[index].text), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let near = book.reading.nearest {
                Label("Matched no format. The closest is format %1$lld (%2$@), which broke after character %3$lld. The whole name became a provisional title.".ui(near.formatIndex + 1, formats.formats[near.formatIndex].text, near.matchedCharacters),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Matched no format, and no format came close. The whole name became a provisional title.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            LegendView(words: Set(book.reading.spans.map(\.word)))
        }
    }

    var colored: AttributedString {
        let chars = Array(book.fileName)
        var word = [FormatWord?](repeating: nil, count: chars.count)
        if book.reading.formatIndex != nil {
            for span in book.reading.spans { for i in span.range { word[i] = span.word } }
        }
        var result = AttributedString()
        var i = 0
        while i < chars.count {
            var j = i
            while j < chars.count, word[j] == word[i] { j += 1 }
            var part = AttributedString(String(chars[i..<j]))
            if let w = word[i] {
                part.backgroundColor = w.color.opacity(0.25)
                if w == .ignore { part.foregroundColor = .secondary }
            }
            result += part
            i = j
        }
        return result
    }
}

struct LegendView: View {
    let words: Set<FormatWord>

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(FormatWord.allCases.filter(words.contains), id: \.self) { word in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(word.color.opacity(0.4)).frame(width: 10, height: 10)
                    Text(key: word.field?.labelKey ?? "Not read").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension FormatWord {
    var color: Color {
        switch self {
        case .title: .blue
        case .author: .green
        case .genre: .orange
        case .event: .pink
        case .source: .purple
        case .info: .teal
        case .series, .volume: .indigo
        case .ignore: .gray
        }
    }
}
