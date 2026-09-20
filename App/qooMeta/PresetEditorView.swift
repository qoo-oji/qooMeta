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
    /// 巻数とみなせるかの判定(規則の側が決めたもの)。`@volume` の型を試し読み・一覧で本物どおりに当てるために要る。
    var isVolume: VolumeTest

    @State private var selection: String?
    @State private var draft = PresetDraft()
    /// 下書きの元(保存してあるもの)。下書きがこれと違えば、保存していない変更がある。
    @State private var saved = PresetDraft()
    @State private var pendingSelection: String?
    @State private var showsSaveAs = false
    @State private var confirmsReset = false
    @State private var confirmsDelete = false

    private var isDirty: Bool { draft.preset != saved.preset }

    var body: some View {
        let entry = catalog.entries.first { $0.id == selection }
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { selection }, set: { select($0) })) {
                    Section("Bundled rule sets") {
                        ForEach(catalog.entries.filter(\.isBuiltIn)) { PresetRow(entry: $0).tag($0.id) }
                    }
                    let mine = catalog.entries.filter { !$0.isBuiltIn }
                    Section("Your rule sets") {
                        if mine.isEmpty {
                            Text("Change a rule set and choose “Save As…” and it appears here.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mine) { PresetRow(entry: $0).tag($0.id) }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280)

            Group {
                if let entry {
                    VStack(spacing: 0) {
                        // 下半分は、直したものを**実際に選んだ名前へ当てた結果**(2026-09-21、利用者の指示)。
                        // 直しながら効果が見えるように、編集の場と同じ画面に置く。
                        VSplitView {
                            PresetDraftEditor(draft: $draft, catalog: catalog, isVolume: isVolume)
                                .frame(minHeight: 200, idealHeight: 380)
                            NameCheckPane(draft: draft, saved: saved, isVolume: isVolume)
                                .frame(minHeight: 150, idealHeight: 260)
                        }
                        Divider()
                        actions(entry)
                    }
                } else {
                    ContentUnavailableView("Select a rule set", systemImage: "textformat.abc")
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
        .confirmationDialog("There are unsaved changes", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Discard the changes and move on", role: .destructive) { if let next = pendingSelection { load(next) } }
        } message: {
            Text("The changes you made to “%@” take effect only once you save them.".ui(draft.preset.displayName))
        }
    }

    @ViewBuilder private func actions(_ entry: PresetCatalog.Entry) -> some View {
        let problems = draft.problems
        HStack {
            if entry.isBuiltIn {
                Button("Reset…") { confirmsReset = true }
                    .disabled(!entry.isModified)
                    .help("Puts the bundled contents back")
                    .confirmationDialog("Reset “%@” to the bundled contents?".ui(entry.preset.displayName), isPresented: $confirmsReset) {
                        Button("Reset it", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty, let original = entry.original { saved = PresetDraft(original); draft = saved }
                        }
                    } message: { Text("The changes you saved to this rule set are lost. The ones you saved under a name of your own stay.") }
            } else {
                Button("Delete…", role: .destructive) { confirmsDelete = true }
                    .confirmationDialog("Delete “%@”?".ui(entry.preset.name), isPresented: $confirmsDelete) {
                        Button("Delete it", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty { load(catalog.builtInDefaultPreset) }
                        }
                    } message: { Text("Folders this rule set was assigned to are read with the default one from now on.") }
            }
            if let first = problems.first { Label(first, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            else if isDirty { Text("There are unsaved changes").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Discard changes") { draft = saved }.disabled(!isDirty)
            Button("Save As New Rule Set…") { showsSaveAs = true }
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
            Button("Save") {
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.preset.displayName)
                Text("%1$@ · %2$lld formats".ui(entry.preset.name, entry.preset.formats.count)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
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

    /// 下書きの型の並びを、いま読める形にしたもの。**書きかけで読めない型は飛ばす**(1 文字打つたびに読めなくなるため)。
    /// `lines` は、残った型が下書きの何行目かの並び(画面に出す番号は、下書きの行の番号のまま)。
    ///
    /// 巻数とみなせるかの判定(`isVolume`)は規則の側が決めるので、外から渡す ―― 渡さないと `@volume` の型が
    /// どの名前にも当たらず、試し読みと一覧が本物と食い違う。
    func usable(isVolume: VolumeTest) -> Usable {
        func fields(_ values: [String: String]) -> [BookMetadata.Field: [String]] {
            Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                BookMetadata.Field(rawValue: key).map { ($0, [value]) } })
        }
        var compiled: [FilenameFormat] = []
        var lines: [Int] = []
        var texts: [String] = []
        for (index, row) in rows.enumerated() {
            guard let format = try? FilenameFormat(row.format.text, separators: row.format.separators,
                                                   defaults: fields(row.format.defaults), plain: row.format.plain) else { continue }
            compiled.append(format)
            lines.append(index)
            texts.append(row.format.text)
        }
        return Usable(formats: FilenameFormats(formats: compiled, separators: separators ?? FilenameFormats.defaultSeparators,
                                               defaults: fields(defaults), plain: plain, isVolume: isVolume),
                      lines: lines, texts: texts)
    }

    struct Usable {
        var formats: FilenameFormats
        var lines: [Int]
        var texts: [String]

        /// 型の番号(読めた並びの中)→ 画面に出す行の番号(1 から)。
        func line(_ index: Int?) -> Int { index.map { lines.indices.contains($0) ? lines[$0] + 1 : $0 + 1 } ?? 0 }
        func text(_ index: Int?) -> String { index.flatMap { texts.indices.contains($0) ? texts[$0] : nil } ?? "" }
    }

    /// 型の書き方の誤り(行の番号つき)。あれば保存できない。
    func problem(of row: Row) -> String? {
        do { _ = try FilenameFormat(row.format.text); return nil } catch { return error.description }
    }

    var problems: [String] {
        var result = rows.enumerated().compactMap { index, row in problem(of: row).map { "Line %1$lld: %2$@".ui(index + 1, $0) } }
        let texts = rows.map(\.format.text)
        if Set(texts).count != texts.count { result.append("The same format appears twice".ui) }
        if rows.isEmpty { result.append("There is no format at all".ui) }
        if let separators, separators.isEmpty { result.append("There is no separator at all".ui) }
        return result
    }
}

/// プリセット 1 つの下書きを直す: 見出しと説明、型の並び(並び順が優先順位)、区切り、既定の欄、試し読み。
private struct PresetDraftEditor: View {
    @Binding var draft: PresetDraft
    var catalog: PresetCatalog
    var isVolume: VolumeTest
    @State private var sample = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    TextField("Display name", text: $draft.label, prompt: Text(key: draft.bundledName))
                    TextField("Description", text: $draft.note, prompt: Text(key: draft.bundledNote), axis: .vertical).lineLimit(1...3)
                }
                .formStyle(.columns)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Format list").font(.headline)
                    Text("Formats are tried **from the top down**, and the first one that matches the whole name reads it. Put the shapes with more fields above the ones with fewer.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Reserved words: @title @author @genre @event @source @info @series @volume @ignore. @author and @ignore may appear any number of times; a format needs either @title or @series.")
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
                    Button { draft.rows.append(.init(format: .init(text: "[@author] @title"))) } label: { Label("Add a format", systemImage: "plus") }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Author separators").font(.headline)
                    Text("The characters that split the authors read from a name. A format can set its own instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    InlineArrayEditor(items: draft.separators ?? FilenameFormats.defaultSeparators,
                                      placeholder: "Separator") { draft.separators = $0 }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Values for fields the name does not carry").font(.headline)
                    Text("A field read from the name is never overwritten. These also go into names that matched no format.").font(.caption).foregroundStyle(.secondary)
                    DefaultsFields(defaults: $draft.defaults)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Text excluded while parsing").font(.headline)
                    PlainTextEditor(plain: $draft.plain)
                }

                SampleReading(sample: $sample, draft: draft, catalog: catalog, isVolume: isVolume)
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
                TextField(LocalizedStringKey(BookMetadata.Field(rawValue: field)?.labelKey ?? field),
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
            Text(verbatim: "\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            TextField("Format", text: $row.format.text).font(.body.monospaced()).textFieldStyle(.roundedBorder)
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(problem)
            }
            Button { showsOptions = true } label: { Image(systemName: hasOptions ? "slider.horizontal.3" : "ellipsis.circle") }
                .buttonStyle(.borderless).foregroundStyle(hasOptions ? Color.accentColor : .secondary)
                .help("Separators and default fields for this format alone")
                .popover(isPresented: $showsOptions, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Acts only on books read with this format").font(.headline)
                        Text("What a format sets beats what the rule set sets.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Set separators for this format alone", isOn: Binding(get: { row.format.separators != nil },
                                                                 set: { row.format.separators = $0 ? [","] : nil }))
                        if let separators = row.format.separators {
                            InlineArrayEditor(items: separators, placeholder: "Separator") { row.format.separators = $0.isEmpty ? nil : $0 }
                        }
                        Text("Values for fields the name does not carry").font(.subheadline)
                        DefaultsFields(defaults: $row.format.defaults)
                        Text("Text excluded while parsing (added by this format)").font(.subheadline)
                        PlainTextEditor(plain: $row.format.plain, showsHelp: false)
                    }
                    .padding(14).frame(width: 420)
                }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0).help("Raise its priority")
            Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == count - 1).help("Lower its priority")
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete this format")
        }
    }
}

/// 試し読み: 名前を打つと、下書きの型の並びでどう読めるかをその場で見せる(保存する前に確かめられる)。
private struct SampleReading: View {
    @Binding var sample: String
    var draft: PresetDraft
    var catalog: PresetCatalog
    var isVolume: VolumeTest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try a name").font(.headline)
            TextField("File name, without the extension", text: $sample, prompt: Text("For example: (Genre) [Studio] Garden of the Moon 3"))
                .textFieldStyle(.roundedBorder)
            let name = sample.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let usable = draft.usable(isVolume: isVolume)
                let reading = usable.formats.read(name)
                if let matched = reading.formatIndex {
                    Label("Read with the format on line %1$lld: %2$@".ui(usable.line(matched), usable.text(matched)), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Label("Matches no format; the whole name becomes a provisional title", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    if let nearest = reading.nearest {
                        Text("The closest is the format on line %1$lld, which matched the first %2$lld characters.".ui(usable.line(nearest.formatIndex), nearest.matchedCharacters))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(BookMetadata.Field.allCases, id: \.self) { field in
                        let values = reading.metadata.values(field)
                        if !values.isEmpty {
                            GridRow {
                                Text(key: field.labelKey).foregroundStyle(.secondary)
                                ValueChips(items: values)
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
                Text("This part of a name is **not read as a format bracket**, even when it is one: it does not divide fields, and it stays in the title or whatever value holds it. Use it so that the “(2026)” of “Garden of the Moon (2026)” becomes neither a source work nor a volume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Words, matched exactly as written").font(.caption.bold())
            InlineArrayEditor(items: plain.words, placeholder: "For example: (draft)") { plain = PlainText(words: $0, patterns: plain.patterns) }
            Text("Regular expressions").font(.caption.bold())
            InlineArrayEditor(items: plain.patterns, placeholder: "Regular expression (ICU)") { plain = PlainText(words: plain.words, patterns: $0) }
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
            : existing.contains(trimmed) ? "A rule set of that name already exists".ui
            : trimmed.hasPrefix("$") ? "A name cannot start with “$”".ui
            : trimmed.count > 100 ? "That name is too long".ui : nil
        Form {
            TextField("Name of the rule set", text: $name, prompt: Text("For example: My shelf"))
            Text("Saves what you have on screen as a new rule set. The one you started from is left alone.").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                // 見出しは名前と同じにする(あとで直せる)。元の見出しのままだと、一覧で見分けが付かない。
                Button("Save") { save(trimmed, trimmed) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(14).frame(width: 340)
    }
}

extension PresetCatalog.Preset {
    /// 画面に出す名前(の鍵)。見出しを付けていなければ、同梱のプリセットの訳。利用者の見出しは、その言葉のまま。
    /// 見出しを付けていなければ、同梱のプリセットの訳。**利用者が付けた見出しは、その言葉のまま**(訳さない)。
    var displayName: String { label.isEmpty ? RuleLabels.preset(name).title.ui : label }
}

extension PresetDraft {
    /// 見出しと説明を空にしたときに、代わりに出る言葉の鍵(同梱のプリセットだけが持つ)。
    var bundledName: String { RuleLabels.preset(name).title }
    var bundledNote: String { RuleLabels.preset(name).help }
}

extension FormatPresets {
    /// 画面に出す名前。`title(of:)` は見出しか名前を返すので、同梱のプリセットはここで訳す。
    func displayName(of name: String) -> String {
        let label = presets[name]?.label ?? ""
        return label.isEmpty ? RuleLabels.preset(name).title.ui : label
    }
}
