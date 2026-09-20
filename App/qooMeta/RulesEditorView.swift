import QooMetaKit
import SwiftUI
import UniformTypeIdentifiers

/// **シリーズと巻数の規則**の窓(series-rules)。タイトルからシリーズ名と巻数を導く規則を、見て・足して・消して・直す。
///
/// **ファイル名の解析(型の並び)は別の窓**(`FileNameRulesView`)。当たる処理の段が違うので、混ぜない
/// (2026-09-21、利用者の指示)。
///
/// 画面が持つのは**既定値との差分だけ**(`RuleChanges`。アプリの設定に残る)。1 か所変えるたびに組み立て直し、誤りがあれば
/// 変えずに理由をその場で示す。読めた変更は、開いている一覧にすぐ効く(WorkspaceView が規則の内容のハッシュを見ている)。
///
/// 並びは JSON の形に合わせてある: **配列で書いてある所(語の規則・巻の読み手)は並べ替えられ、ほかは書いてある順に働く**
/// (docs/rules-format-design.md「規則の順番と例外」)。
struct SeriesRulesView: View {
    static let windowID = "series-rules"

    @Bindable var settings: AppSettings
    @State private var pane: Pane = .policies
    @State private var editing: RulesEditing
    @State private var confirmsReset = false

    init(settings: AppSettings) {
        self.settings = settings
        _editing = State(initialValue: RulesEditing(settings: settings))
    }

    enum Pane: String, CaseIterable, Identifiable {
        case policies, markers, readers, steps, lists, json
        var id: String { rawValue }

        var title: String {
            switch self {
            case .policies: "How books are treated"
            case .markers: "Words in a title"
            case .readers: "Reading the volume"
            case .steps: "Grouping and naming"
            case .lists: "Word lists"
            case .json: "Diff (JSON)"
            }
        }

        var symbol: String {
            switch self {
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
                Label(LocalizedStringKey(pane.title), systemImage: pane.symbol)
                    .badge(pane.isOrdered ? Text("Ordered") : nil)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                PhaseBanner(title: "Deriving the series and volume",
                            flow: "Title → series name and volume", fileName: "series-rules.json",
                            symbol: "books.vertical")
                Divider()
                Group {
                    switch pane {
                    case .policies: PoliciesPane(editing: editing, catalog: catalog)
                    case .markers: MarkersPane(editing: editing, catalog: catalog)
                    case .readers: ReadersPane(editing: editing, catalog: catalog)
                    case .steps: StepsPane(editing: editing, catalog: catalog)
                    case .lists: ListsPane(editing: editing, catalog: catalog)
                    case .json: DiffPane(editing: editing, half: .series)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(editing: editing, half: .series, confirmsReset: $confirmsReset)
            }
        }
        .navigationTitle("Series and volume extraction")
        .navigationSubtitle(LocalizedStringKey(pane.title))
        .confirmationDialog("Reset every series rule to the default?", isPresented: $confirmsReset) {
            Button("Reset to the default", role: .destructive) { editing.reset(.series) }
        } message: {
            Text("Every change you made to the policies, the word rules and the word lists is lost.")
        }
    }
}

/// どの段の規則を直しているかを、画面の上にいつも出す。
struct PhaseBanner: View {
    var title: LocalizedStringKey
    var flow: LocalizedStringKey
    var fileName: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(flow).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: fileName).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
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

    func reset(_ half: RuleChanges.Half) {
        errors = settings.resetRules(half)
    }
}

// MARK: - 下の帯

struct StatusBar: View {
    @Bindable var editing: RulesEditing
    /// この窓が受け持つ半分。
    var half: RuleChanges.Half
    @Binding var confirmsReset: Bool

    var body: some View {
        let changed = editing.settings.changedCount(half)
        VStack(alignment: .leading, spacing: 6) {
            if !editing.errors.isEmpty {
                HStack(alignment: .top) {
                    Label("The change could not be made", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(editing.errors.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Close") { editing.errors = [] }.controlSize(.small)
                }
            }
            if !editing.settings.ruleIssues.isEmpty {
                Label(editing.settings.ruleIssues.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text(changed == 0 ? "Unchanged from the defaults".ui : "Changed in %lld places".ui(changed))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Everything…") { confirmsReset = true }
                    .disabled(changed == 0 && editing.settings.changes.isEmpty(half))
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
            .help(isModified ? "Changed from the default" : "")
    }
}

// MARK: - 方針

private struct PoliciesPane: View {
    var editing: RulesEditing
    var catalog: RuleCatalog

    private static let groups: [(title: String, ids: [String])] = [
        ("Editions and publication forms of the same work", ["editions", "sources"]),
        ("Compilations and side stories", ["compilations", "compilationVolume"]),
        ("How series are split", ["differentRelation", "differentGenre", "subtitled"]),
        ("Volumes", ["unnumberedFirst", "magazines"]),
    ]

    var body: some View {
        let known = Set(Self.groups.flatMap(\.ids))
        Form {
            Section {
                Text("These settle **what to do** with what qooMeta found. There is no single right answer, so choose what suits your books.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Self.groups, id: \.title) { group in
                // 見出しは**鍵として**渡す。`Section(String)` の口に渡すと、訳を引かずにそのまま出る
                // (画面に英語のまま出ていた。2026-09-20、利用者の指摘)。
                Section(LocalizedStringKey(group.title)) {
                    let rule = catalog.entries.first { $0.id == "compilation" }
                    ForEach(catalog.policies.filter { group.ids.contains($0.id) }) { policy in
                        // 総集編の置き場所は、敷居(1 冊でもシリーズにするか)と 1 つにまとめて出す。
                        if policy.id == "compilations", let rule, let single = rule.parameters.first(where: { $0.name == CompilationPlacementRow.single }) {
                            CompilationPlacementRow(editing: editing, policy: policy, rule: rule, single: single)
                        } else {
                            PolicyRow(editing: editing, policy: policy)
                        }
                    }
                    if group.ids.contains("compilations"), let rule {
                        // 総集編の設定は、方針(置き場所・巻数)と規則(足す数)に分かれている。画面では 1 か所に見せる。
                        // 敷居は置き場所と 1 つにまとめたので、ここでは出さない。
                        ForEach(rule.parameters.filter { $0.name != CompilationPlacementRow.single }, id: \.name) {
                            ParameterRow(editing: editing, entry: rule, parameter: $0)
                        }
                    }
                }
            }
            let others = catalog.policies.filter { !known.contains($0.id) }
            if !others.isEmpty {
                Section("Other") { ForEach(others) { PolicyRow(editing: editing, policy: $0) } }
            }
        }
        .formStyle(.grouped)
    }
}

/// 総集編・番外編の置き場所。**方針(置き場所)と規則(1 冊でもシリーズにするか)を 1 つの選択に見せる**。
///
/// 2 つに分かれていると、どちらがどちらの条件なのか読み取れなかった(2026-09-20、利用者の指摘)。
/// 敷居が効くのは「別のシリーズにする」ときなので、その選択肢を 2 つに割る。
private struct CompilationPlacementRow: View {
    static let single = "singleWhenMainExists"

    var editing: RulesEditing
    var policy: RuleCatalog.Policy
    var rule: RuleCatalog.Entry
    var single: RuleCatalog.Parameter

    /// 画面に出す 1 つの選択。置き場所と敷居の組。
    private enum Choice: String, CaseIterable, Identifiable {
        case ownSeriesFromTwo, ownSeriesFromOne, inMainSeries, notInSeries
        var id: String { rawValue }

        var placement: String {
            switch self {
            case .ownSeriesFromTwo, .ownSeriesFromOne: "ownSeries"
            case .inMainSeries: "inMainSeries"
            case .notInSeries: "notInSeries"
            }
        }

        /// 敷居を決める選択か(「別のシリーズ」のときだけ)。
        var single: Bool? {
            switch self {
            case .ownSeriesFromTwo: false
            case .ownSeriesFromOne: true
            default: nil
            }
        }

        var title: String {
            switch self {
            case .ownSeriesFromTwo: "In a series of their own, “X Compilation” (two or more)"
            case .ownSeriesFromOne: "In a series of their own, “X Compilation” (one is enough when the main series exists)"
            case .inMainSeries: "In the main series"
            case .notInSeries: "In no series at all"
            }
        }
    }

    private var current: Choice {
        switch policy.current {
        case "inMainSeries": .inMainSeries
        case "notInSeries": .notInSeries
        default: single.current.boolValue ?? true ? .ownSeriesFromOne : .ownSeriesFromTwo
        }
    }

    private var isDefault: Choice {
        switch policy.defaultChoice {
        case "inMainSeries": .inMainSeries
        case "notInSeries": .notInSeries
        default: single.defaultValue.boolValue ?? true ? .ownSeriesFromOne : .ownSeriesFromTwo
        }
    }

    var body: some View {
        let label = RuleLabels.policies["compilations"] ?? RuleLabels.Item(title: "compilations")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ModifiedDot(isModified: policy.isModified || single.isModified)
                Picker(selection: Binding(get: { current }, set: { choose($0) })) {
                    ForEach(Choice.allCases) { choice in
                        Text(verbatim: choice == isDefault ? "%@ (default)".ui(choice.title.ui) : choice.title.ui).tag(choice)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key: label.title)
                        if !label.help.isEmpty { Text(key: label.help).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Text("A book put in the main series falls back to “X Compilation” when no main series was found — with one compilation enough to make it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose(_ choice: Choice) {
        editing.change { changes in
            if choice.placement == policy.defaultChoice { changes.resetPolicy(policy.id) }
            else { changes.setPolicy(choice.placement, for: policy.id) }
            guard let wanted = choice.single else { return }
            if JSONValue.bool(wanted) == single.defaultValue { changes.resetValue(rule: rule.id, parameter: single.name) }
            else { _ = changes.setValue(.bool(wanted), rule: rule.id, parameter: single.name) }
        }
    }
}

private struct PolicyRow: View {
    var editing: RulesEditing
    var policy: RuleCatalog.Policy

    var body: some View {
        let label = RuleLabels.policies[policy.id] ?? RuleLabels.Item(title: policy.id)
        HStack {
            ModifiedDot(isModified: policy.isModified)
            Picker(selection: Binding(get: { policy.current }, set: { choice in
                editing.change { choice == policy.defaultChoice ? $0.resetPolicy(policy.id) : $0.setPolicy(choice, for: policy.id) }
            })) {
                ForEach(policy.choices, id: \.self) { choice in
                    Text(verbatim: {
                        let text = (RuleLabels.choices[policy.id]?[choice] ?? choice).ui
                        return choice == policy.defaultChoice ? "%@ (default)".ui(text) : text
                    }()).tag(choice)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key: label.title)
                    if !label.help.isEmpty { Text(key: label.help).font(.caption).foregroundStyle(.secondary) }
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
        let title = LocalizedStringKey(RuleLabels.parameter(parameter.name))
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
                    ForEach(choices, id: \.self) { Text(key: parameter.name == "treat" ? RuleLabels.treatment($0).title : $0).tag($0) }
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
                    Text("Uses the list “%@”, which you can also edit under “Word lists”.".ui(RuleLabels.list(list.id).title.ui))
                        .font(.caption).foregroundStyle(.secondary)
                    RuleListEditor(editing: editing, list: list)
                } else {
                    InlineArrayEditor(items: parameter.current.arrayValue?.compactMap(\.stringValue) ?? [],
                                      placeholder: parameter.kind == .patterns ? "Regular expression (ICU)".ui : "Word".ui) { set(.array($0.map(JSONValue.string))) }
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
    var title: LocalizedStringKey
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
                Text("%1$lld to %2$lld".ui(range.lowerBound, range.upperBound)).font(.caption).foregroundStyle(.tertiary)
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
                OrderExplanation(text: "Words in a title are looked for **from the top rule down**. A word an upper rule has taken is invisible to the rules below. An exception is written as a “read as it is” rule placed **above** the rule you want to hold back.")
                OrderedRuleList(rules: rules, selection: $selection, subtitle: { RuleLabels.treatment($0.parameter("treat")?.current.stringValue ?? "").title },
                                toggle: { id, on in editing.change { $0.setEnabled(on, rule: id) } },
                                move: { ids in editing.change { $0.setMarkerOrder(ids) } })
                Divider()
                HStack {
                    Button { showsAdd = true } label: { Label("Add a rule", systemImage: "plus") }
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
                    Button("Reset the order") { editing.change { $0.setMarkerOrder(nil) } }
                        .disabled(!editing.settings.rules.changedPaths.contains("markers.$order"))
                }
                .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 340)
            Group {
                if let rule = rules.first(where: { $0.id == selection }) {
                    MarkerDetail(editing: editing, catalog: catalog, rule: rule) { selection = nil }
                } else {
                    ContentUnavailableView("Select a rule", systemImage: "list.number",
                                           description: Text("You can look at the words and the regular expressions, and add or remove them."))
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
                    Text(verbatim: "\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { toggle(rule.id, $0) })).labelsHidden()
                        .toggleStyle(.checkbox).help("Let this rule act")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: RuleLabels.title(ofRule: rule.id)).foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        let sub = subtitle(rule)
                        if !sub.isEmpty { Text(key: sub).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if rule.isUserAdded { Text("Added rule").font(.caption2).padding(.horizontal, 5).background(.tint.opacity(0.18), in: .capsule) }
                    ModifiedDot(isModified: rule.isModified && !rule.isUserAdded)
                    // ドラッグのほかに、ボタンでも動かせる(キーボードと読み上げのため)。
                    Button { shift(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0).help("Raise its priority")
                    Button { shift(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == rules.count - 1).help("Lower its priority")
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
            : existing.contains(trimmed) ? "A rule of that name already exists".ui
            : trimmed.hasPrefix("$") ? "A name cannot start with “$”".ui
            : trimmed.count > 100 ? "That name is too long".ui : nil
        Form {
            TextField("Name of the rule", text: $name, prompt: Text("For example: art books are not editions"))
            Picker("Treatment", selection: $treat) {
                ForEach(RuleChanges.markerTreatments, id: \.self) { Text(key: RuleLabels.treatment($0).title).tag($0) }
            }
            Text(key: RuleLabels.treatment(treat).help).font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Add") { add(trimmed, treat) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
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
                        Text(verbatim: RuleLabels.title(ofRule: rule.id)).font(.title3.bold())
                        if !label.help.isEmpty { Text(key: label.help).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if rule.isUserAdded {
                        Button("Delete this rule", role: .destructive) {
                            editing.change { $0.removeMarker(id: rule.id) }
                            if editing.errors.isEmpty { deleted() }
                        }
                    } else {
                        Button("Reset to the default") { editing.change { $0.reset(rule: rule.id) } }.disabled(!rule.isModified)
                    }
                }
                if let treat = rule.parameter("treat") {
                    ParameterRow(editing: editing, entry: rule, parameter: treat)
                    Text(key: RuleLabels.treatment(treat.current.stringValue ?? "").help).font(.caption).foregroundStyle(.secondary)
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
                OrderExplanation(text: "The part after the series name is tried **from the top reader down**, and the first reader that can read it settles the volume.")
                OrderedRuleList(rules: readers, selection: $selection, subtitle: { _ in "" },
                                toggle: { id, on in editing.change { $0.setEnabled(on, rule: id) } },
                                move: { ids in editing.change { $0.setReaderOrder(ids) } })
                Divider()
                HStack {
                    Spacer()
                    Button("Reset the order") { editing.change { $0.resetReaderOrder() } }
                        .disabled(!editing.settings.rules.changedPaths.contains("volume.readers.$order"))
                }
                .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 340)
            Group {
                if let reader = readers.first(where: { $0.id == selection }) {
                    RuleDetail(editing: editing, catalog: catalog, rule: reader)
                } else {
                    ContentUnavailableView("Select a way to read the volume", systemImage: "textformat.123")
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
                        Text(verbatim: RuleLabels.title(ofRule: rule.id)).font(.title3.bold())
                        if !label.help.isEmpty { Text(key: label.help).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Reset to the default") { editing.change { $0.reset(rule: rule.id) } }.disabled(!rule.isModified)
                }
                if rule.parameters.isEmpty {
                    Text("This rule has no values to change; you can only let it act or hold it back.").foregroundStyle(.secondary)
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
                OrderExplanation(text: "These rules are **stages**: each one takes what the one before it produced. They act in the order written and cannot be reordered.")
                List(selection: $selection) {
                    ForEach(Self.stages, id: \.self) { stage in
                        let rules = catalog.entries.filter { $0.stage == stage }
                        if !rules.isEmpty {
                            Section(LocalizedStringKey(RuleLabels.stages[stage] ?? stage)) {
                                ForEach(rules) { rule in
                                    HStack(spacing: 8) {
                                        if rule.canDisable {
                                            Toggle("", isOn: Binding(get: { rule.isEnabled },
                                                                     set: { on in editing.change { $0.setEnabled(on, rule: rule.id) } }))
                                                .labelsHidden().toggleStyle(.checkbox)
                                        } else {
                                            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).frame(width: 16)
                                                .help("Whether it acts is settled by a policy")
                                        }
                                        Text(verbatim: RuleLabels.title(ofRule: rule.id)).foregroundStyle(rule.isEnabled ? .primary : .secondary)
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
                    ContentUnavailableView("Select a rule", systemImage: "arrow.triangle.branch")
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
                        Text(key: RuleLabels.list(list.id).title)
                        Text(list.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(verbatim: "\(list.items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    ModifiedDot(isModified: !list.added.isEmpty || !list.removed.isEmpty)
                }
                .tag(list.id)
            }
            .frame(minWidth: 280, idealWidth: 320)
            Group {
                if let list = lists.first(where: { $0.id == selection }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(key: RuleLabels.list(list.id).title).font(.title3.bold())
                            let help = RuleLabels.list(list.id).help
                            if !help.isEmpty { Text(key: help).font(.callout).foregroundStyle(.secondary) }
                            RuleListEditor(editing: editing, list: list)
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView("Select a list", systemImage: "text.word.spacing")
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
                Text("Nothing in here yet.").foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(list.items, id: \.self) { item in
                    Chip(text: RuleLabels.visible(item), isAdded: list.added.contains(item)) { remove(item) }
                }
            }
            HStack {
                TextField(isPairs ? "Left character".ui : list.kind == "characters" ? "One character".ui : "Word".ui, text: $newItem)
                    .frame(maxWidth: isPairs ? 90 : 240).onSubmit(add)
                if isPairs {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Right character".ui, text: $newValue).frame(maxWidth: 90).onSubmit(add)
                }
                Button("Add", action: add).disabled(newItem.isEmpty || (isPairs && newValue.isEmpty))
                Spacer()
                Button("Reset this list") { editing.change { $0.resetList(list.id) } }
                    .disabled(list.added.isEmpty && list.removed.isEmpty)
            }
            if !list.removed.isEmpty {
                Text("Bundled words you removed. Click one to put it back").font(.caption).foregroundStyle(.secondary)
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
            if items.isEmpty { Text("Nothing in here yet.").foregroundStyle(.secondary) }
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Chip(text: item, isAdded: false) { commit(items.filter { $0 != item }) }
                }
            }
            HStack {
                TextField(placeholder, text: $newItem).frame(maxWidth: 280).onSubmit(add)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
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

/// 決まっている値を、1 つずつの札で見せる(読むだけ)。**区切り文字でつないだ 1 本の文字列にしない**
/// ―― どこまでが 1 つの値か分からなくなる(2026-09-21、利用者の指摘)。
struct ValueChips: View {
    var items: [String]
    /// 1 つも無いときに出す言葉。
    var empty: LocalizedStringKey = "None"

    var body: some View {
        if items.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 4) {
                // 同じ値が 2 つあってもよいので、値ではなく位置で見分ける。
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(verbatim: item)
                        .textSelection(.enabled)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
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
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
        }
        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 3)
        .background(isAdded ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary), in: .capsule)
        .help(isAdded ? "Added word" : "")
    }
}

// MARK: - 差分(JSON)

/// 画面で変えた内容そのもの(既定値との差分)。手で書き換えたり、ほかの Mac へ持っていったりできる。
struct DiffPane: View {
    var editing: RulesEditing
    /// この窓が受け持つ半分。書き換えても、もう片方の設定には触らない。
    var half: RuleChanges.Half
    @State private var text = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you change on screen is kept as a **diff** laid over the bundled defaults. You can edit it here directly, or write it to a file and carry it elsewhere. If a word you added holds the name of one of your books, the written file holds it too.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).border(.separator)
            HStack {
                Button("Apply") {
                    editing.errors = editing.settings.setRulesDiff(text, for: half)
                    message = editing.errors.isEmpty ? "Applied" : ""
                }
                Button("Back to the current settings") { reload() }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Load…") { importFile() }
                Button("Write…") { exportFile() }.disabled(editing.settings.changes.isEmpty(half))
            }
        }
        .padding(14)
        .onAppear(perform: reload)
        .onChange(of: editing.settings.rulesDiff) { reload() }
    }

    private func reload() {
        text = editing.settings.changes.isEmpty(half) ? ""
            : String(decoding: editing.settings.changes.data(half), as: UTF8.self)
        message = ""
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        text = String(decoding: data, as: UTF8.self)
        message = "Loaded. Press “Apply” to put it to work"
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "qooMeta rule changes.json".ui
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? editing.settings.changes.data(half).write(to: url, options: .atomic)
    }
}
