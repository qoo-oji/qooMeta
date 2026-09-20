import QooMetaKit
import SwiftUI
import UniformTypeIdentifiers

/// 規則の窓: ファイル名の読み方(型の並び。PresetEditorView)と、タイトルからシリーズ名と巻を導く規則(series-rules)を見て、
/// 足し、消し、直す。
///
/// 画面が持つのは**既定値との差分だけ**(`RuleChanges`。アプリの設定に残る)。1 か所変えるたびに組み立て直し、誤りがあれば
/// 変えずに理由をその場で示す。読めた変更は、開いている一覧にすぐ効く(WorkspaceView が規則の内容のハッシュを見ている)。
///
/// 並びは JSON の形に合わせてある: **配列で書いてある所(語の規則・巻の読み手)は並べ替えられ、ほかは書いてある順に働く**
/// (docs/rules-format-design.md「規則の順番と例外」)。
struct RulesEditorView: View {
    static let windowID = "rules"

    @Bindable var settings: AppSettings
    @State private var pane: Pane = .formats
    @State private var editing: RulesEditing
    @State private var confirmsReset = false

    init(settings: AppSettings) {
        self.settings = settings
        _editing = State(initialValue: RulesEditing(settings: settings))
    }

    enum Pane: String, CaseIterable, Identifiable {
        case formats, policies, markers, readers, steps, lists, json
        var id: String { rawValue }

        var title: String {
            switch self {
            case .formats: "型の並び(プリセット)"
            case .policies: "方針"
            case .markers: "語の規則"
            case .readers: "巻の読み手"
            case .steps: "組み方と名前"
            case .lists: "語の一覧"
            case .json: "差分(JSON)"
            }
        }

        var symbol: String {
            switch self {
            case .formats: "textformat.abc"
            case .policies: "slider.horizontal.3"
            case .markers: "list.number"
            case .readers: "textformat.123"
            case .steps: "arrow.triangle.branch"
            case .lists: "text.word.spacing"
            case .json: "curlybraces"
            }
        }

        /// 並び順が優先順位になる所(配列で書いてある段階)。
        var isOrdered: Bool { self == .markers || self == .readers }
    }

    var body: some View {
        let catalog = settings.rules.catalog
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? pane })) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .badge(pane.isOrdered ? Text("順番あり") : nil)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch pane {
                    case .formats: FormatsPane(editing: editing, catalog: settings.rules.presetCatalog)
                    case .policies: PoliciesPane(editing: editing, catalog: catalog)
                    case .markers: MarkersPane(editing: editing, catalog: catalog)
                    case .readers: ReadersPane(editing: editing, catalog: catalog)
                    case .steps: StepsPane(editing: editing, catalog: catalog)
                    case .lists: ListsPane(editing: editing, catalog: catalog)
                    case .json: DiffPane(editing: editing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(editing: editing, confirmsReset: $confirmsReset)
            }
        }
        .navigationTitle("規則")
        .navigationSubtitle(pane.title)
        .confirmationDialog("すべての規則を既定に戻しますか?", isPresented: $confirmsReset) {
            Button("既定に戻す", role: .destructive) { editing.resetAll() }
        } message: {
            Text("方針・語の規則・語の一覧に加えた変更が、すべて消えます。")
        }
    }
}

/// 規則の窓の操作の受け口。変更は設定へ渡し、誤りはここに残して画面が示す。
@MainActor @Observable
final class RulesEditing {
    let settings: AppSettings
    var errors: [String] = []

    init(settings: AppSettings) { self.settings = settings }

    func change(_ body: (inout RuleChanges) -> Void) {
        errors = settings.update(body)
    }

    func resetAll() {
        errors = settings.setRulesDiff("")
    }
}

// MARK: - 下の帯

private struct StatusBar: View {
    @Bindable var editing: RulesEditing
    @Binding var confirmsReset: Bool

    var body: some View {
        let changed = editing.settings.rules.changedPaths.count
        VStack(alignment: .leading, spacing: 6) {
            if !editing.errors.isEmpty {
                HStack(alignment: .top) {
                    Label("変更できませんでした", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(editing.errors.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("閉じる") { editing.errors = [] }.controlSize(.small)
                }
            }
            if !editing.settings.ruleIssues.isEmpty {
                Label(editing.settings.ruleIssues.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text(changed == 0 ? "既定のままです" : "既定から \(changed) か所を変えています")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("すべて既定に戻す…") { confirmsReset = true }.disabled(changed == 0 && editing.settings.rulesDiff.isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 変えた所に付ける印。
struct ModifiedDot: View {
    var isModified: Bool
    var body: some View {
        Circle().fill(isModified ? Color.accentColor : .clear).frame(width: 7, height: 7)
            .help(isModified ? "既定から変えています" : "")
    }
}

// MARK: - 方針

private struct PoliciesPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog

    private static let groups: [(title: String, ids: [String])] = [
        ("同じ作品の版・入手経路", ["editions", "sources"]),
        ("総集編・番外編", ["compilations", "compilationVolume"]),
        ("シリーズの分け方", ["differentRelation", "differentGenre", "subtitled"]),
        ("巻", ["unnumberedFirst", "magazines"]),
    ]

    var body: some View {
        let known = Set(Self.groups.flatMap(\.ids))
        Form {
            Section {
                Text("見分けた結果を**どう扱うか**の好みです。正解が 1 つあるわけではないので、蔵書に合わせて選びます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Self.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(catalog.policies.filter { group.ids.contains($0.id) }) { PolicyRow(editing: editing, policy: $0) }
                    if group.ids.contains("compilations"), let rule = catalog.entries.first(where: { $0.id == "compilation" }) {
                        // 総集編の設定は、方針(置き場所・巻数)と規則(足す数)に分かれている。画面では 1 か所に見せる。
                        ForEach(rule.parameters, id: \.name) { ParameterRow(editing: editing, entry: rule, parameter: $0) }
                    }
                }
            }
            let others = catalog.policies.filter { !known.contains($0.id) }
            if !others.isEmpty {
                Section("そのほか") { ForEach(others) { PolicyRow(editing: editing, policy: $0) } }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PolicyRow: View {
    var editing: RulesEditing
    var policy: RuleCatalog.Policy

    var body: some View {
        let label = RuleLabels.policies[policy.id] ?? RuleLabels.Text(title: policy.id)
        HStack {
            ModifiedDot(isModified: policy.isModified)
            Picker(selection: Binding(get: { policy.current }, set: { choice in
                editing.change { choice == policy.defaultChoice ? $0.resetPolicy(policy.id) : $0.setPolicy(choice, for: policy.id) }
            })) {
                ForEach(policy.choices, id: \.self) { choice in
                    Text((RuleLabels.choices[policy.id]?[choice] ?? choice) + (choice == policy.defaultChoice ? "(既定)" : "")).tag(choice)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.title)
                    if !label.help.isEmpty { Text(label.help).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: - パラメータ 1 つ

/// 規則のパラメータ 1 つを、値の種類に合った部品で直す。
private struct ParameterRow: View {
    var editing: RulesEditing
    var entry: RuleCatalog.Entry
    var parameter: RuleCatalog.Parameter
    var catalog: RuleCatalog?

    var body: some View {
        let title = RuleLabels.parameter(parameter.name)
        switch parameter.kind {
        case .bool:
            HStack {
                ModifiedDot(isModified: parameter.isModified)
                Toggle(title, isOn: Binding(get: { parameter.current.boolValue ?? false },
                                            set: { value in set(.bool(value)) }))
            }
        case .int(let range):
            HStack {
                ModifiedDot(isModified: parameter.isModified)
                IntField(title: title, value: parameter.current.intValue ?? range.lowerBound, range: range) { set(.number(Double($0))) }
            }
        case .choice(let choices):
            HStack {
                ModifiedDot(isModified: parameter.isModified)
                Picker(title, selection: Binding(get: { parameter.current.stringValue ?? "" }, set: { set(.string($0)) })) {
                    ForEach(choices, id: \.self) { Text(parameter.name == "treat" ? RuleLabels.treatment($0).title : $0).tag($0) }
                }
                // 同梱の規則の扱いは変えない(変えると、規則の名前と中身が食い違う)。足した規則だけ選べる。
                .disabled(parameter.name == "treat" && !entry.isUserAdded)
            }
        case .list, .patterns:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ModifiedDot(isModified: parameter.isModified)
                    Text(title).font(.headline)
                }
                if let reference = parameter.current.stringValue, reference.hasPrefix("@list:"), let catalog,
                   let list = catalog.lists.first(where: { $0.id == String(reference.dropFirst("@list:".count)) }) {
                    Text("一覧「\(RuleLabels.list(list.id).title)」を使っています(「語の一覧」でも同じものを直せます)。")
                        .font(.caption).foregroundStyle(.secondary)
                    RuleListEditor(editing: editing, list: list)
                } else {
                    InlineArrayEditor(items: parameter.current.arrayValue?.compactMap(\.stringValue) ?? [],
                                      placeholder: parameter.kind == .patterns ? "正規表現(ICU)" : "語") { set(.array($0.map(JSONValue.string))) }
                }
            }
        }
    }

    private func set(_ value: JSONValue) {
        editing.change { changes in
            // 既定の値に戻したら、差分からも消す(「変えた所」の数え方が、見た目と合うように)。
            if value == parameter.defaultValue, !entry.isUserAdded {
                changes.resetValue(rule: entry.id, parameter: parameter.name)
            } else {
                changes.setValue(value, rule: entry.id, parameter: parameter.name)
            }
        }
    }
}

/// 整数の欄(入力して確定、または上下のボタン)。
private struct IntField: View {
    var title: String
    var value: Int
    var range: ClosedRange<Int>
    var commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", text: $text).frame(width: 70).multilineTextAlignment(.trailing)
                    .onSubmit { apply() }
                Stepper("", value: Binding(get: { value }, set: { commit(min(max($0, range.lowerBound), range.upperBound)) }), in: range)
                    .labelsHidden()
                Text("\(range.lowerBound)〜\(range.upperBound)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { text = String(value) }
    }

    private func apply() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { text = String(value); return }
        commit(min(max(number, range.lowerBound), range.upperBound))
    }
}

// MARK: - 語の規則(順番あり)

private struct MarkersPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    @State private var selection: String?
    @State private var showsAdd = false

    var body: some View {
        let rules = catalog.entries.filter { $0.stage == "markers" }
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                OrderExplanation(text: "タイトルの中の語を、**上の規則から順に**探します。上の規則が取った所には、下の規則は反応しません。例外は「そのまま読む」の規則を、守りたい規則より**上**に置いて書きます。")
                OrderedRuleList(rules: rules, selection: $selection, subtitle: { RuleLabels.treatment($0.parameter("treat")?.current.stringValue ?? "").title },
                                toggle: { id, on in editing.change { $0.setEnabled(on, rule: id) } },
                                move: { ids in editing.change { $0.setMarkerOrder(ids) } })
                Divider()
                HStack {
                    Button { showsAdd = true } label: { Label("規則を足す", systemImage: "plus") }
                        .popover(isPresented: $showsAdd, arrowEdge: .bottom) {
                            AddMarkerView(existing: Set(rules.map(\.id))) { name, treat in
                                showsAdd = false
                                // 足した規則は先頭に入る(例外は上に置くものだから)。いまの順番の変更があっても先頭にする。
                                editing.change {
                                    $0.addMarker(id: name, treat: treat)
                                    $0.setMarkerOrder([name] + rules.map(\.id))
                                }
                                if editing.errors.isEmpty { selection = name }
                            }
                        }
                    Spacer()
                    Button("順番を既定に戻す") { editing.change { $0.setMarkerOrder(nil) } }
                        .disabled(!editing.settings.rules.changedPaths.contains("markers.$order"))
                }
                .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 340)
            Group {
                if let rule = rules.first(where: { $0.id == selection }) {
                    MarkerDetail(editing: editing, catalog: catalog, rule: rule) { selection = nil }
                } else {
                    ContentUnavailableView("規則を選んでください", systemImage: "list.number",
                                           description: Text("語と正規表現を見て、足したり外したりできます。"))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = rules.first?.id } }
    }
}

private struct OrderExplanation: View {
    var text: LocalizedStringKey
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
    }
}

/// 並べ替えられる規則の並び(語の規則・巻の読み手で同じ)。番号は優先順位。
private struct OrderedRuleList: View {
    var rules: [RuleCatalog.Entry]
    @Binding var selection: String?
    var subtitle: (RuleCatalog.Entry) -> String
    var toggle: (String, Bool) -> Void
    var move: ([String]) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { toggle(rule.id, $0) })).labelsHidden()
                        .toggleStyle(.checkbox).help("この規則を働かせる")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RuleLabels.rule(rule.id).title).foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        let sub = subtitle(rule)
                        if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if rule.isUserAdded { Text("足した規則").font(.caption2).padding(.horizontal, 5).background(.tint.opacity(0.18), in: .capsule) }
                    ModifiedDot(isModified: rule.isModified && !rule.isUserAdded)
                    // ドラッグのほかに、ボタンでも動かせる(キーボードと読み上げのため)。
                    Button { shift(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0).help("優先順位を上げる")
                    Button { shift(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == rules.count - 1).help("優先順位を下げる")
                }
                .tag(rule.id)
            }
            .onMove { from, to in
                var ids = rules.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                move(ids)
            }
        }
    }

    private func shift(_ index: Int, by offset: Int) {
        var ids = rules.map(\.id)
        ids.swapAt(index, index + offset)
        move(ids)
    }
}

private struct AddMarkerView: View {
    var existing: Set<String>
    var add: (String, String) -> Void
    @State private var name = ""
    @State private var treat = "keep"

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let problem: String? = trimmed.isEmpty ? nil
            : existing.contains(trimmed) ? "同じ名前の規則があります"
            : trimmed.hasPrefix("$") ? "「$」で始まる名前は使えません"
            : trimmed.count > 100 ? "名前が長すぎます" : nil
        Form {
            TextField("規則の名前", text: $name, prompt: Text("例: 画集は版にしない"))
            Picker("扱い", selection: $treat) {
                ForEach(RuleChanges.markerTreatments, id: \.self) { Text(RuleLabels.treatment($0).title).tag($0) }
            }
            Text(RuleLabels.treatment(treat).help).font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("足す") { add(trimmed, treat) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(14).frame(width: 340)
    }
}

private struct MarkerDetail: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    var rule: RuleCatalog.Entry
    var deleted: () -> Void

    var body: some View {
        let label = RuleLabels.rule(rule.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label.title).font(.title3.bold())
                        if !label.help.isEmpty { Text(label.help).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if rule.isUserAdded {
                        Button("この規則を消す", role: .destructive) {
                            editing.change { $0.removeMarker(id: rule.id) }
                            if editing.errors.isEmpty { deleted() }
                        }
                    } else {
                        Button("既定に戻す") { editing.change { $0.reset(rule: rule.id) } }.disabled(!rule.isModified)
                    }
                }
                if let treat = rule.parameter("treat") {
                    ParameterRow(editing: editing, entry: rule, parameter: treat)
                    Text(RuleLabels.treatment(treat.current.stringValue ?? "").help).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(rule.parameters.filter { $0.name != "treat" }, id: \.name) {
                    ParameterRow(editing: editing, entry: rule, parameter: $0, catalog: catalog)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 巻の読み手(順番あり)

private struct ReadersPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    @State private var selection: String?

    var body: some View {
        let readers = catalog.entries.filter { $0.stage == "volume.readers" }
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                OrderExplanation(text: "シリーズ名より後ろの部分を、**上の読み手から順に**試し、最初に読めたものを巻にします。")
                OrderedRuleList(rules: readers, selection: $selection, subtitle: { _ in "" },
                                toggle: { id, on in editing.change { $0.setEnabled(on, rule: id) } },
                                move: { ids in editing.change { $0.setReaderOrder(ids) } })
                Divider()
                HStack {
                    Spacer()
                    Button("順番を既定に戻す") { editing.change { $0.resetReaderOrder() } }
                        .disabled(!editing.settings.rules.changedPaths.contains("volume.readers.$order"))
                }
                .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 340)
            Group {
                if let reader = readers.first(where: { $0.id == selection }) {
                    RuleDetail(editing: editing, catalog: catalog, rule: reader)
                } else {
                    ContentUnavailableView("読み手を選んでください", systemImage: "textformat.123")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = readers.first?.id } }
    }
}

/// 規則 1 つの中身(パラメータ)。
private struct RuleDetail: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    var rule: RuleCatalog.Entry

    var body: some View {
        let label = RuleLabels.rule(rule.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label.title).font(.title3.bold())
                        if !label.help.isEmpty { Text(label.help).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("既定に戻す") { editing.change { $0.reset(rule: rule.id) } }.disabled(!rule.isModified)
                }
                if rule.parameters.isEmpty {
                    Text("この規則に、変えられる値はありません(働かせるかどうかだけ)。").foregroundStyle(.secondary)
                }
                ForEach(rule.parameters, id: \.name) { ParameterRow(editing: editing, entry: rule, parameter: $0, catalog: catalog) }
            }
            .padding(16)
        }
    }
}

// MARK: - 組み方と名前(順番の決まった工程)

private struct StepsPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    @State private var selection: String?

    private static let stages = ["grouping", "grouping.sharedPrefix.conditions", "naming", "volume.inference"]

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                OrderExplanation(text: "ここの規則は、前の規則の結果を次の規則が受け取る**工程**です。書いてある順に働き、並べ替えはできません。")
                List(selection: $selection) {
                    ForEach(Self.stages, id: \.self) { stage in
                        let rules = catalog.entries.filter { $0.stage == stage }
                        if !rules.isEmpty {
                            Section(RuleLabels.stages[stage] ?? stage) {
                                ForEach(rules) { rule in
                                    HStack(spacing: 8) {
                                        if rule.canDisable {
                                            Toggle("", isOn: Binding(get: { rule.isEnabled },
                                                                     set: { on in editing.change { $0.setEnabled(on, rule: rule.id) } }))
                                                .labelsHidden().toggleStyle(.checkbox)
                                        } else {
                                            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).frame(width: 16)
                                                .help("働くかどうかは方針で決まります")
                                        }
                                        Text(RuleLabels.rule(rule.id).title).foregroundStyle(rule.isEnabled ? .primary : .secondary)
                                        Spacer()
                                        ModifiedDot(isModified: rule.isModified)
                                    }
                                    .tag(rule.id)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 360)
            Group {
                if let rule = catalog.entries.first(where: { $0.id == selection && Self.stages.contains($0.stage) }) {
                    RuleDetail(editing: editing, catalog: catalog, rule: rule)
                } else {
                    ContentUnavailableView("規則を選んでください", systemImage: "arrow.triangle.branch")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 語の一覧

private struct ListsPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog
    @State private var selection: String?

    var body: some View {
        let known = RuleLabels.listOrder.compactMap { id in catalog.lists.first { $0.id == id } }
        let lists = known + catalog.lists.filter { !RuleLabels.listOrder.contains($0.id) }
        HSplitView {
            List(lists, selection: $selection) { list in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RuleLabels.list(list.id).title)
                        Text(list.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(list.items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    ModifiedDot(isModified: !list.added.isEmpty || !list.removed.isEmpty)
                }
                .tag(list.id)
            }
            .frame(minWidth: 280, idealWidth: 320)
            Group {
                if let list = lists.first(where: { $0.id == selection }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(RuleLabels.list(list.id).title).font(.title3.bold())
                            let help = RuleLabels.list(list.id).help
                            if !help.isEmpty { Text(help).font(.callout).foregroundStyle(.secondary) }
                            RuleListEditor(editing: editing, list: list)
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView("一覧を選んでください", systemImage: "text.word.spacing")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = lists.first?.id } }
    }
}

/// 一覧 1 つを直す(語・文字・対応表)。足した語には印を付け、外した既定の語は下に残して戻せるようにする。
private struct RuleListEditor: View {
    var editing: RulesEditing
    var list: RuleCatalog.ListEntry
    @State private var newItem = ""
    @State private var newValue = ""

    private var isPairs: Bool { list.kind == "pairs" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if list.items.isEmpty {
                Text("まだ何も入っていません。").foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(list.items, id: \.self) { item in
                    Chip(text: RuleLabels.visible(item), isAdded: list.added.contains(item)) { remove(item) }
                }
            }
            HStack {
                TextField(isPairs ? "左の字" : list.kind == "characters" ? "1 文字" : "語", text: $newItem)
                    .frame(maxWidth: isPairs ? 90 : 240).onSubmit(add)
                if isPairs {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("右の字", text: $newValue).frame(maxWidth: 90).onSubmit(add)
                }
                Button("足す", action: add).disabled(newItem.isEmpty || (isPairs && newValue.isEmpty))
                Spacer()
                Button("この一覧を既定に戻す") { editing.change { $0.resetList(list.id) } }
                    .disabled(list.added.isEmpty && list.removed.isEmpty)
            }
            if !list.removed.isEmpty {
                Text("外した既定の語(押すと戻ります)").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(list.removed, id: \.self) { item in
                        Button { restore(item) } label: { Text(RuleLabels.visible(item)).strikethrough() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func key(of item: String) -> String { String(item.prefix { $0 != "→" }) }

    private func add() {
        // 空白そのものを足したいことがある(無視する文字)ので、語の前後の空白は、語の一覧のときだけ落とす。
        let item = list.kind == "words" ? newItem.trimmingCharacters(in: .whitespaces) : newItem
        guard !item.isEmpty else { return }
        editing.change { changes in
            if isPairs { changes.setPair(item, newValue, in: list.id) } else { changes.add([item], to: list.id) }
        }
        if editing.errors.isEmpty { newItem = ""; newValue = "" }
    }

    private func remove(_ item: String) {
        editing.change { changes in
            if isPairs { changes.removePair(key(of: item), from: list.id) } else { changes.remove([item], from: list.id) }
        }
    }

    private func restore(_ item: String) {
        editing.change { changes in
            if isPairs, let value = item.split(separator: "→").last { changes.setPair(key(of: item), String(value), in: list.id) }
            else { changes.add([item], to: list.id) }
        }
    }
}

/// その場に書いた値の並び(正規表現、足した規則の語)。
struct InlineArrayEditor: View {
    var items: [String]
    var placeholder: String
    var commit: ([String]) -> Void
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty { Text("まだ何も入っていません。").foregroundStyle(.secondary) }
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Chip(text: item, isAdded: false) { commit(items.filter { $0 != item }) }
                }
            }
            HStack {
                TextField(placeholder, text: $newItem).frame(maxWidth: 280).onSubmit(add)
                Button("足す", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !items.contains(item) else { return }
        commit(items + [item])
        newItem = ""
    }
}

struct Chip: View {
    var text: String
    var isAdded: Bool
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).textSelection(.enabled)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("外す")
        }
        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 3)
        .background(isAdded ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary), in: .capsule)
        .help(isAdded ? "足した語" : "")
    }
}

// MARK: - 差分(JSON)

/// 画面で変えた内容そのもの(既定値との差分)。手で書き換えたり、ほかの Mac へ持っていったりできる。
private struct DiffPane: View {
    var editing: RulesEditing
    @State private var text = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画面で変えた内容は、同梱の既定値に重ねる**差分**として持っています。ここで直に書き換えることも、ファイルに書き出して持ち運ぶこともできます。足した語に蔵書の名前が入っていれば、書き出したファイルにも入ります。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).border(.separator)
            HStack {
                Button("適用") {
                    editing.errors = editing.settings.setRulesDiff(text)
                    message = editing.errors.isEmpty ? "適用しました" : ""
                }
                Button("いまの設定に戻す") { reload() }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("読み込む…") { importFile() }
                Button("書き出す…") { exportFile() }.disabled(editing.settings.rulesDiff.isEmpty)
            }
        }
        .padding(14)
        .onAppear(perform: reload)
        .onChange(of: editing.settings.rulesDiff) { reload() }
    }

    private func reload() {
        text = editing.settings.rulesDiff
        message = ""
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        text = String(decoding: data, as: UTF8.self)
        message = "読み込みました。「適用」で効かせます"
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "qooMeta の規則の変更.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(editing.settings.rulesDiff.utf8).write(to: url, options: .atomic)
    }
}
