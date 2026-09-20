import QooMetaKit
import SwiftUI

/// ファイル名フォーマットのプリセット(名前を付けた型の並び)を見て、直す。規則の窓の 1 枚。
///
/// 直すのは手元の下書きで、**「保存」か「名前をつけて保存」を押すまで設定には入らない**(型は書きかけのあいだ読めない形に
/// なるので、1 文字ごとに効かせると一覧が読み直しを繰り返す)。
/// - 保存: いまのプリセットを上書きする。同梱のプリセットも直せて、「初期化」で同梱の中身に戻せる。
/// - 名前をつけて保存: 下書きを新しいプリセットにする。**同じ名前のプリセットは 2 つ作れない。**
/// - 削除: 利用者が作ったプリセットだけ消せる。
struct FormatsPane: View {
    var editing: RulesEditing
    var catalog: PresetCatalog

    @State private var selection: String?
    @State private var draft = PresetDraft()
    /// 下書きの元(保存してあるもの)。下書きがこれと違えば、保存していない変更がある。
    @State private var saved = PresetDraft()
    @State private var pendingSelection: String?
    @State private var showsSaveAs = false
    @State private var confirmsReset = false
    @State private var confirmsDelete = false
    @State private var showsSeparators = false
    @State private var showsPlain = false

    private var isDirty: Bool { draft.preset != saved.preset }

    var body: some View {
        let entry = catalog.entries.first { $0.id == selection }
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { selection }, set: { select($0) })) {
                    Section("同梱のプリセット") {
                        ForEach(catalog.entries.filter(\.isBuiltIn)) { PresetRow(entry: $0, isDefault: $0.id == catalog.defaultPreset).tag($0.id) }
                    }
                    let mine = catalog.entries.filter { !$0.isBuiltIn }
                    Section("自分のプリセット") {
                        if mine.isEmpty {
                            Text("プリセットを直して「名前をつけて保存」すると、ここに並びます。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mine) { PresetRow(entry: $0, isDefault: $0.id == catalog.defaultPreset).tag($0.id) }
                    }
                }
                Divider()
                Form {
                    Picker("既定のプリセット", selection: Binding(get: { catalog.defaultPreset }, set: { name in
                        editing.change { $0.setDefaultPreset(name, builtIn: catalog.builtInDefaultPreset) }
                    })) {
                        ForEach(catalog.entries) { Text($0.preset.label.isEmpty ? $0.preset.name : $0.preset.label).tag($0.id) }
                    }
                    .help("フォルダにプリセットを割り当てていない本は、これで読みます")
                    LabeledContent("著者の区切り") {
                        Button(catalog.separators.map(RuleLabels.visible).joined(separator: " ")) { showsSeparators = true }
                            .popover(isPresented: $showsSeparators, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("著者の値を分ける文字(すべてのプリセットの既定)").font(.headline)
                                    Text("プリセットや型に区切りを書くと、そこではそちらが丸ごと勝ちます。").font(.caption).foregroundStyle(.secondary)
                                    InlineArrayEditor(items: catalog.separators, placeholder: "区切り") { items in
                                        editing.change { $0.setSeparators(items, builtIn: catalog.builtInSeparators) }
                                    }
                                    Button("既定に戻す") { editing.change { $0.setSeparators(catalog.builtInSeparators, builtIn: catalog.builtInSeparators) } }
                                        .disabled(catalog.separators == catalog.builtInSeparators)
                                }
                                .padding(14).frame(width: 360)
                            }
                    }
                    LabeledContent("型として読まない文字列") {
                        Button(catalog.plain.isEmpty ? "なし" : "\(catalog.plain.words.count + catalog.plain.patterns.count) 件") { showsPlain = true }
                            .popover(isPresented: $showsPlain, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("型として読まない文字列(すべてのプリセット)").font(.headline)
                                    PlainTextEditor(plain: Binding(get: { catalog.plain }, set: { plain in
                                        editing.change { $0.setPlain(plain, builtIn: catalog.builtInPlain) }
                                    }))
                                    Button("既定に戻す") { editing.change { $0.setPlain(catalog.builtInPlain, builtIn: catalog.builtInPlain) } }
                                        .disabled(catalog.plain == catalog.builtInPlain)
                                }
                                .padding(14).frame(width: 420)
                            }
                    }
                }
                .formStyle(.columns).padding(10)
            }
            .frame(minWidth: 270, idealWidth: 300)

            Group {
                if let entry {
                    VStack(spacing: 0) {
                        PresetDraftEditor(draft: $draft, catalog: catalog)
                        Divider()
                        actions(entry)
                    }
                } else {
                    ContentUnavailableView("プリセットを選んでください", systemImage: "textformat.abc")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { load(catalog.defaultPreset) } }
        // 保存・初期化のあと、保存してある中身が変わったら下書きを取り直す(直している途中の下書きは、そのまま)。
        .onChange(of: entry?.preset) { _, now in
            guard let now, now != saved.preset else { return }
            let wasDirty = isDirty
            saved = PresetDraft(now)
            if !wasDirty { draft = saved }
        }
        .confirmationDialog("保存していない変更があります", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("変更を捨てて移る", role: .destructive) { if let next = pendingSelection { load(next) } }
        } message: {
            Text("「\(draft.preset.label.isEmpty ? draft.preset.name : draft.preset.label)」に加えた変更は、保存するまで効きません。")
        }
    }

    @ViewBuilder private func actions(_ entry: PresetCatalog.Entry) -> some View {
        let problems = draft.problems
        HStack {
            if entry.isBuiltIn {
                Button("初期化…") { confirmsReset = true }
                    .disabled(!entry.isModified)
                    .help("同梱の中身に戻します")
                    .confirmationDialog("「\(entry.preset.label)」を同梱の中身に戻しますか?", isPresented: $confirmsReset) {
                        Button("初期化する", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty, let original = entry.original { saved = PresetDraft(original); draft = saved }
                        }
                    } message: { Text("このプリセットに保存した変更が消えます。名前をつけて保存したプリセットは残ります。") }
            } else {
                Button("削除…", role: .destructive) { confirmsDelete = true }
                    .confirmationDialog("「\(entry.preset.name)」を削除しますか?", isPresented: $confirmsDelete) {
                        Button("削除する", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty { load(catalog.builtInDefaultPreset) }
                        }
                    } message: { Text("このプリセットを割り当てていたフォルダは、既定のプリセットで読むようになります。") }
            }
            if let first = problems.first { Label(first, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            else if isDirty { Text("保存していない変更があります").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("元に戻す") { draft = saved }.disabled(!isDirty)
            Button("名前をつけて保存…") { showsSaveAs = true }
                .disabled(!problems.isEmpty)
                .popover(isPresented: $showsSaveAs, arrowEdge: .top) {
                    SaveAsView(existing: catalog.names) { name, label in
                        showsSaveAs = false
                        var copy = draft.preset
                        copy.name = name
                        copy.label = label
                        editing.change { $0.setPreset(copy, original: nil) }
                        if editing.errors.isEmpty { saved = PresetDraft(copy); draft = saved; selection = name }
                    }
                }
            Button("保存") {
                editing.change { $0.setPreset(draft.preset, original: entry.original) }
                if editing.errors.isEmpty { saved = draft }
            }
            .disabled(!isDirty || !problems.isEmpty)
        }
        .padding(10)
    }

    private func select(_ name: String?) {
        guard let name, name != selection else { return }
        if isDirty { pendingSelection = name } else { load(name) }
    }

    private func load(_ name: String) {
        pendingSelection = nil
        guard let entry = catalog.entries.first(where: { $0.id == name }) ?? catalog.entries.first else { return }
        selection = entry.id
        saved = PresetDraft(entry.preset)
        draft = saved
    }
}

private struct PresetRow: View {
    var entry: PresetCatalog.Entry
    var isDefault: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.preset.label.isEmpty ? entry.preset.name : entry.preset.label)
                Text("\(entry.preset.name) ・ \(entry.preset.formats.count) 通り").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault { Image(systemName: "star.fill").foregroundStyle(.yellow).help("既定のプリセット") }
            ModifiedDot(isModified: entry.isModified)
        }
    }
}

/// 下書き。型の行は並べ替えるので、行ごとに変わらない ID を持たせる(中身が同じ行が 2 つあっても区別できるように)。
struct PresetDraft {
    struct Row: Identifiable {
        let id = UUID()
        var format: PresetCatalog.Format
    }

    var name = ""
    var label = ""
    var note = ""
    var separators: [String]?
    var defaults: [String: String] = [:]
    var plain = PlainText.none
    var rows: [Row] = []

    init() {}

    init(_ preset: PresetCatalog.Preset) {
        name = preset.name
        label = preset.label
        note = preset.note
        separators = preset.separators
        defaults = preset.defaults
        plain = preset.plain
        rows = preset.formats.map { Row(format: $0) }
    }

    var preset: PresetCatalog.Preset {
        PresetCatalog.Preset(name: name, label: label.trimmingCharacters(in: .whitespaces), note: note.trimmingCharacters(in: .whitespaces),
                             separators: separators, defaults: defaults.filter { !$0.value.isEmpty }, plain: plain,
                             formats: rows.map(\.format))
    }

    /// 型の書き方の誤り(行の番号つき)。あれば保存できない。
    func problem(of row: Row) -> String? {
        do { _ = try FilenameFormat(row.format.text); return nil } catch { return error.description }
    }

    var problems: [String] {
        var result = rows.enumerated().compactMap { index, row in problem(of: row).map { "\(index + 1) 行目: \($0)" } }
        let texts = rows.map(\.format.text)
        if Set(texts).count != texts.count { result.append("同じ型が 2 つあります") }
        if rows.isEmpty { result.append("型が 1 つもありません") }
        if let separators, separators.isEmpty { result.append("区切りが 1 つもありません") }
        return result
    }
}

/// プリセット 1 つの下書きを直す: 見出しと説明、型の並び(並び順が優先順位)、区切り、既定の欄、試し読み。
private struct PresetDraftEditor: View {
    @Binding var draft: PresetDraft
    var catalog: PresetCatalog
    @State private var sample = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    TextField("見出し", text: $draft.label, prompt: Text(draft.name))
                    TextField("説明", text: $draft.note, axis: .vertical).lineLimit(1...3)
                }
                .formStyle(.columns)

                VStack(alignment: .leading, spacing: 6) {
                    Text("型の並び").font(.headline)
                    Text("**上から順に**試し、名前全体に合った最初の型で読みます。欄の多い形を上に、少ない形を下に置いてください。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("予約語: @title @author @genre @event @source @info @series @volume @ignore(@author と @ignore は何度でも書けます。型には @title か @series が要ります)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    VStack(spacing: 4) {
                        // 行は ID で指す(番号で指すと、消した直後に無い番号を読んで落ちる)。
                        ForEach($draft.rows) { $row in
                            let index = draft.rows.firstIndex { $0.id == row.id } ?? 0
                            FormatRowView(index: index, count: draft.rows.count, row: $row, problem: draft.problem(of: row),
                                          move: { offset in
                                              guard let i = draft.rows.firstIndex(where: { $0.id == row.id }),
                                                    draft.rows.indices.contains(i + offset) else { return }
                                              draft.rows.swapAt(i, i + offset)
                                          },
                                          remove: { draft.rows.removeAll { $0.id == row.id } })
                        }
                    }
                    Button { draft.rows.append(.init(format: .init(text: "[@author] @title"))) } label: { Label("型を足す", systemImage: "plus") }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("著者の区切り").font(.headline)
                    Toggle("このプリセットだけの区切りを決める", isOn: Binding(get: { draft.separators != nil },
                                                                 set: { draft.separators = $0 ? catalog.separators : nil }))
                    if let separators = draft.separators {
                        InlineArrayEditor(items: separators, placeholder: "区切り") { draft.separators = $0 }
                    } else {
                        Text("すべてのプリセットの既定(\(catalog.separators.map(RuleLabels.visible).joined(separator: " ")))で分けます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("名前に書かれていない欄に入れる値").font(.headline)
                    Text("名前から読めた欄は上書きしません。どの型にも合わなかった名前にも入ります。").font(.caption).foregroundStyle(.secondary)
                    DefaultsFields(defaults: $draft.defaults)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("型として読まない文字列(このプリセットで足す分)").font(.headline)
                    PlainTextEditor(plain: $draft.plain)
                    if !catalog.plain.isEmpty {
                        Text("すべてのプリセットの分(\((catalog.plain.words + catalog.plain.patterns).joined(separator: "  ")))に足されます。")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                SampleReading(sample: $sample, draft: draft, catalog: catalog)
            }
            .padding(16)
        }
    }
}

private struct DefaultsFields: View {
    @Binding var defaults: [String: String]

    var body: some View {
        Form {
            ForEach(PresetCatalog.defaultFields, id: \.self) { field in
                TextField(BookMetadata.Field(rawValue: field)?.label ?? field,
                          text: Binding(get: { defaults[field] ?? "" }, set: { defaults[field] = $0.isEmpty ? nil : $0 }))
            }
        }
        .formStyle(.columns)
    }
}

/// 型 1 行。番号(優先順位)、型の文字列、その型だけの区切りと既定の欄、上下、削除。
private struct FormatRowView: View {
    var index: Int
    var count: Int
    @Binding var row: PresetDraft.Row
    var problem: String?
    var move: (Int) -> Void
    var remove: () -> Void
    @State private var showsOptions = false

    private var hasOptions: Bool { row.format.separators != nil || !row.format.defaults.isEmpty || !row.format.plain.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            TextField("型", text: $row.format.text).font(.body.monospaced()).textFieldStyle(.roundedBorder)
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(problem)
            }
            Button { showsOptions = true } label: { Image(systemName: hasOptions ? "slider.horizontal.3" : "ellipsis.circle") }
                .buttonStyle(.borderless).foregroundStyle(hasOptions ? Color.accentColor : .secondary)
                .help("この型だけの区切りと、既定の欄")
                .popover(isPresented: $showsOptions, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("この型で読んだ本にだけ効きます").font(.headline)
                        Text("型 > プリセット > すべてのプリセットの既定 の順に、内側に書いたものが勝ちます。").font(.caption).foregroundStyle(.secondary)
                        Toggle("この型だけの区切りを決める", isOn: Binding(get: { row.format.separators != nil },
                                                                 set: { row.format.separators = $0 ? [","] : nil }))
                        if let separators = row.format.separators {
                            InlineArrayEditor(items: separators, placeholder: "区切り") { row.format.separators = $0.isEmpty ? nil : $0 }
                        }
                        Text("名前に書かれていない欄に入れる値").font(.subheadline)
                        DefaultsFields(defaults: $row.format.defaults)
                        Text("型として読まない文字列(この型で足す分)").font(.subheadline)
                        PlainTextEditor(plain: $row.format.plain, showsHelp: false)
                    }
                    .padding(14).frame(width: 420)
                }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0).help("優先順位を上げる")
            Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == count - 1).help("優先順位を下げる")
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("この型を消す")
        }
    }
}

/// 試し読み: 名前を打つと、下書きの型の並びでどう読めるかをその場で見せる(保存する前に確かめられる)。
private struct SampleReading: View {
    @Binding var sample: String
    var draft: PresetDraft
    var catalog: PresetCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("試し読み").font(.headline)
            TextField("ファイル名(拡張子なし)", text: $sample, prompt: Text("例: (架空の分類) [架空工房] 月の庭 3"))
                .textFieldStyle(.roundedBorder)
            let name = sample.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                // 書きかけで読めない型は飛ばして試す(番号は下書きの行の番号のまま)。
                let usable = draft.rows.enumerated().compactMap { index, row -> (Int, FilenameFormat)? in
                    let defaults = Dictionary(uniqueKeysWithValues: row.format.defaults.compactMap { key, value in
                        BookMetadata.Field(rawValue: key).map { ($0, [value]) } })
                    return (try? FilenameFormat(row.format.text, separators: row.format.separators, defaults: defaults,
                                                plain: row.format.plain)).map { (index, $0) }
                }
                let fileDefaults = catalog.defaults.merging(draft.defaults) { _, inner in inner }
                let formats = FilenameFormats(
                    formats: usable.map(\.1), separators: draft.separators ?? catalog.separators,
                    defaults: Dictionary(uniqueKeysWithValues: fileDefaults.compactMap { key, value in
                        BookMetadata.Field(rawValue: key).map { ($0, [value]) } }),
                    plain: catalog.plain.adding(draft.plain))
                let reading = formats.read(name)
                if let matched = reading.formatIndex {
                    Label("\(usable[matched].0 + 1) 行目の型で読めました: \(usable[matched].1.text)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Label("どの型にも合いません(名前の全体が仮のタイトルになります)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    if let nearest = reading.nearest {
                        Text("いちばん近いのは \(usable[nearest.formatIndex].0 + 1) 行目の型で、頭から \(nearest.matchedCharacters) 文字まで合いました。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(BookMetadata.Field.allCases, id: \.self) { field in
                        let values = reading.metadata.values(field)
                        if !values.isEmpty {
                            GridRow {
                                Text(field.label).foregroundStyle(.secondary)
                                Text(values.joined(separator: " / ")).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}

/// 型として読まない文字列(語と正規表現)。名前の中のこの部分は、型の照合のあいだだけただの文字として扱い、値には残す。
private struct PlainTextEditor: View {
    @Binding var plain: PlainText
    var showsHelp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHelp {
                Text("名前の中のこの部分は、括弧であっても**型の括弧として読みません**(欄の区切りにならず、タイトルなどの値にそのまま残ります)。「月の庭 (2026)」の「(2026)」を原作や巻数にしないために使います。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("語(書いたとおりの文字列)").font(.caption.bold())
            InlineArrayEditor(items: plain.words, placeholder: "例: (仮)") { plain = PlainText(words: $0, patterns: plain.patterns) }
            Text("正規表現").font(.caption.bold())
            InlineArrayEditor(items: plain.patterns, placeholder: "正規表現(ICU)") { plain = PlainText(words: plain.words, patterns: $0) }
        }
    }
}

/// 名前をつけて保存。同じ名前のプリセットは作れない。
private struct SaveAsView: View {
    var existing: Set<String>
    var save: (String, String) -> Void
    @State private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let problem: String? = trimmed.isEmpty ? nil
            : existing.contains(trimmed) ? "同じ名前のプリセットがあります"
            : trimmed.hasPrefix("$") ? "「$」で始まる名前は使えません"
            : trimmed.count > 100 ? "名前が長すぎます" : nil
        Form {
            TextField("プリセットの名前", text: $name, prompt: Text("例: 自分の棚"))
            Text("いまの下書きを、新しいプリセットとして保存します。元のプリセットは変わりません。").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                // 見出しは名前と同じにする(あとで直せる)。元の見出しのままだと、一覧で見分けが付かない。
                Button("保存") { save(trimmed, trimmed) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(14).frame(width: 340)
    }
}
