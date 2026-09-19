import QooMetaKit
import SwiftUI

/// 詳細。1 冊ならファイル名のどこがどの欄か(色分け)と一致した型を、複数ならまとめて書き換える欄を出す。
/// 揃わない欄は「<複数値>」で、入力すると選んだ全冊のその欄を置き換える(StackNest の詳細ペインと同じ)。
struct DetailView: View {
    @Bindable var workspace: Workspace

    /// 利用者が書き換えられる欄。シリーズと巻は中核が導く(シリーズの操作は段階 7)。
    static let editableFields: [BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info]

    var body: some View {
        let books = workspace.selectedBooks
        if books.isEmpty {
            ContentUnavailableView("本を選んでください", systemImage: "book.closed",
                                   description: Text("一覧で選ぶと、ここに詳細が出ます。複数選べば、まとめて書き換えられます。"))
        } else {
            Form {
                Section {
                    if books.count == 1, let book = books.first {
                        FileNameView(book: book, formats: workspace.formats)
                    } else {
                        Text("\(books.count) 冊を選択").font(.headline)
                    }
                }
                Section {
                    ForEach(Self.editableFields, id: \.self) { field in
                        FieldEditor(workspace: workspace, field: field, books: books)
                    }
                }
                Section("シリーズと巻(規則で導いたもの)") {
                    LabeledContent("シリーズ", value: uniform(books, .series) ?? "<複数値>")
                    LabeledContent("巻", value: uniform(books, .volume) ?? "<複数値>")
                }
            }
            .formStyle(.grouped)
            // 選択が変わったら、入力中の値を捨てる。
            .id(books.map(\.id))
        }
    }

    func uniform(_ books: [BookRow], _ field: BookMetadata.Field) -> String? {
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
                ListEditor(values: current, placeholder: field.label) { workspace.set(field, to: $0, for: ids) }
            } else {
                SingleEditor(value: current.map { $0.first ?? "" }) { workspace.set(field, to: [$0], for: ids) }
            }
        } label: {
            Text(field.label)
            if edited {
                HStack(spacing: 4) {
                    Text("直した").font(.caption2).foregroundStyle(.tint)
                    Button("戻す") { workspace.revert(field, for: ids) }
                        .buttonStyle(.link).font(.caption2)
                        .help("ファイル名から読んだ値に戻す")
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
        TextField("", text: $text, prompt: Text(value == nil ? "複数の値" : ""))
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
                    Text("複数の値").foregroundStyle(.secondary)
                    Spacer()
                    Button("書き換える") { replacing = true; items = [""]; focusedIndex = 0 }
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
                            .help("この値を消す")
                    }
                    .contextMenu {
                        Button("上へ") { items.swapAt(i, i - 1); save() }.disabled(i == 0)
                        Button("下へ") { items.swapAt(i, i + 1); save() }.disabled(i == items.count - 1)
                    }
                }
                // 足すボタンは、消すボタン(各行の右端)と同じ列に置く。
                HStack {
                    Spacer()
                    Button { items.append(""); focusedIndex = items.count - 1 } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("値を足す")
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
                Label("型 \(index + 1): \(formats.formats[index].text)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let near = book.reading.nearest {
                Label("どの型にも合わない。最も近いのは型 \(near.formatIndex + 1)(\(formats.formats[near.formatIndex].text))で、"
                      + "\(near.matchedCharacters) 文字目の後で外れた。名前全体を仮のタイトルにした",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("どの型にも合わない(近い型も無い)。名前全体を仮のタイトルにした", systemImage: "exclamationmark.triangle")
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
                    Text(word.field?.label ?? "読まない").font(.caption2).foregroundStyle(.secondary)
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
        case .ignore: .gray
        }
    }
}
