import QooMetaKit
import QooMetaScan
import SwiftUI

/// qooMeta は**蔵書を持たない**(docs/concept.md)。使い方は「1 回きりの流れ」で、同じ蔵書を何度も見る道具ではない
/// (2026-09-21、利用者の指摘)。だから画面も、その流れをそのまま段にする:
///
/// 1. 対象を選ぶ → 2. 解析方法を選ぶ → 3. 確認・編集 → 4. 書き出す
///
/// 段 1・2 を通るまで一覧は出さない(前は、フォルダを開いた瞬間にデフォルトのプリセットを黙って当てていた)。
struct FlowView: View {
    @Bindable var model: AppModel

    /// いまの一覧を捨てる前の確かめの言葉(何をしようとしているかで変える)。
    private var discardTitle: LocalizedStringKey {
        if case .openWorkfile = model.pendingDiscard { return "Open another workfile?" }
        return "Start over with other books?"
    }

    private var discardAction: LocalizedStringKey {
        if case .openWorkfile = model.pendingDiscard { return "Discard and open" }
        return "Discard and start over"
    }

    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: model.step, furthest: model.furthestStep) { model.go(to: $0) }
            Divider()
            switch model.step {
            case .choose:
                ChooseBooksStep(model: model)
            case .parse:
                ChoosePresetStep(model: model)
            case .review:
                if let workspace = model.workspace {
                    WorkspaceView(workspace: workspace, settings: model.settings)
                }
            case .export:
                if let workspace = model.workspace {
                    ExportStep(workspace: workspace, settings: model.settings, model: model)
                }
            }
        }
        // 窓のツールバーの背景(すりガラス)が、段のバーより下まで掛かって表の見出しを塗り潰していた。
        // 段のバーが仕切りになるので、ツールバーの背景は隠す(2026-09-21、実機で確かめた)。
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 規則の窓で変えた内容は、開いている一覧にすぐ効かせる(すべての本を読み直す)。**どの段にいても届ける**
        // ―― 段 3 の画面に付けていたときは、段 2 や段 4 にいるあいだの変更が一覧へ届かず、古い規則で読んだ結果を
        // そのまま書き出していた(2026-09-21 の監査)。一覧ができた時点でも 1 度届ける(組み立ての最中に変わった分)。
        .task(id: RulesDelivery(rules: model.settings.rules.contentHash, workspace: model.workspace.map(ObjectIdentifier.init))) {
            // 規則の窓で続けて直しているあいだは、少し待つ(1 つ直すたびに全冊を読み直さない。`task(id:)` は、
            // 待っているあいだに次の変更が来たら、この回を取り消す)。
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.workspace?.setRules(model.settings.rules)
        }
        .confirmationDialog(discardTitle,
                            isPresented: Binding(get: { model.pendingDiscard != nil },
                                                 set: { if !$0 { model.pendingDiscard = nil } })) {
            Button(discardAction, role: .destructive) { model.confirmDiscarding() }
        } message: {
            Text("The corrections you have not saved are lost.")
        }
    }
}

/// 規則を一覧へ届け直すきっかけ(規則の中身か、一覧そのものが替わったとき)。
private struct RulesDelivery: Hashable {
    var rules: String
    var workspace: ObjectIdentifier?
}

// MARK: - 段のバー

/// いまどの段にいて、次に何をするのかを、いつも上に出す。通り過ぎた段へは戻れる。
private struct StepBar: View {
    var current: AppModel.Step
    var furthest: AppModel.Step
    var go: (AppModel.Step) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Step.allCases) { step in
                let reachable = step.rawValue <= furthest.rawValue
                Button { go(step) } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().fill(step == current ? AnyShapeStyle(.tint)
                                          : reachable ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                                .frame(width: 22, height: 22)
                            if step.rawValue < current.rawValue {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: "\(step.rawValue + 1)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(step == current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            }
                        }
                        Text(key: step.title)
                            .font(step == current ? .headline : .body)
                            .foregroundStyle(step == current ? .primary : reachable ? .secondary : .tertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!reachable || step == current)
                if step != AppModel.Step.allCases.last {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).padding(.horizontal, 10)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// 段の下に置く、進む・戻るの帯。
private struct StepFooter<Trailing: View>: View {
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Divider()
        HStack {
            if let back { Button("Back") { back() } }
            Spacer()
            trailing
        }
        .padding(14)
    }
}

// MARK: - 段 1: 対象を選ぶ

private struct ChooseBooksStep: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Image(systemName: "books.vertical").font(.system(size: 42)).foregroundStyle(.tint)
                        Text("Which books shall qooMeta work on?").font(.title2.bold())
                        Text("Pick a folder, or pick the files yourself. qooMeta reads only the names; it never opens the books and keeps no library of its own.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    HStack(spacing: 12) {
                        Button { model.chooseFolder() } label: {
                            Label("Choose a Folder…", systemImage: "folder")
                        }
                        Button { model.chooseFiles() } label: {
                            Label("Choose Files…", systemImage: "doc.on.doc")
                        }
                    }
                    .controlSize(.large)

                    if let picked = model.picked {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("%lld books found".ui(picked.files.count)).font(.headline)
                                Text(verbatim: picked.root.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                Divider()
                                FlowLayout(spacing: 8) {
                                    ForEach(picked.kinds, id: \.name) { kind in
                                        Text(verbatim: "\(kind.name) \(kind.count)")
                                            .font(.callout)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(.quaternary, in: .capsule)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 520)
                    }

                    Divider().frame(maxWidth: 520)
                    VStack(spacing: 6) {
                        Text("Carrying on with work you saved earlier?").font(.callout).foregroundStyle(.secondary)
                        Button("Open Workfile…") { model.openWorkfile() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .containerRelativeFrame(.vertical, alignment: .center)
            }
            StepFooter {
                Button("Next") { model.go(to: .parse) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.picked == nil)
            }
        }
    }
}

// MARK: - 段 2: 解析方法を選ぶ

private struct ChoosePresetStep: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How should the file names be read?").font(.title2.bold())
                        Text("A rule set is a list of name shapes. qooMeta tries them from the top and reads the name with the first shape that fits the whole of it. The count shows how many of your names it read in full — a name whose brackets ended up inside a field is not counted.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.isFitting { ProgressView().controlSize(.small) }
                    ForEach(model.presetFits) { fit in
                        PresetFitRow(fit: fit, total: model.picked?.files.count ?? 0,
                                     selected: model.chosenPreset == fit.id) { model.chosenPreset = fit.id }
                    }
                    Text("Books that fit no shape keep their whole name as a provisional title. You can fix them in the next step, or change how the names are read.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            // いまここで選んでいるルールセットを、窓にも選ばせる。
                            if let preset = model.chosenPreset { PickedForRules.shared.open(ruleSet: preset) }
                            openWindow(id: FileNameRulesView.windowID)
                        } label: {
                            Label("Look at and edit the rule sets…", systemImage: "textformat.abc")
                        }
                        Text("A rule set you save there appears here at once.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(24)
                .containerRelativeFrame(.vertical, alignment: .center)
            }
            // プリセットの窓で足した・直したものを、すぐこの並びに出す(数も取り直す)。
            .onChange(of: model.settings.rules.contentHash) { Task { await model.computeFits() } }
            StepFooter(back: { model.go(to: .choose) }) {
                Button("Next") { model.startReview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosenPreset == nil || model.isFitting)
            }
        }
    }
}

private struct PresetFitRow: View {
    var fit: AppModel.PresetFit
    var total: Int
    var selected: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: fit.title).font(.headline)
                    if !fit.note.isEmpty { Text(key: fit.note).font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        ProgressView(value: total == 0 ? 0 : Double(fit.read) / Double(total))
                            .frame(width: 130)
                        Text("%1$lld of %2$lld names read in full".ui(fit.read, total))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if fit.leftover > 0 {
                        Label("%lld names keep a bracket that became no field".ui(fit.leftover),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 段 4: 書き出す

private struct ExportStep: View {
    var workspace: Workspace
    var settings: AppSettings
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ExportView(workspace: workspace, settings: settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StepFooter(back: { model.go(to: .review) }) { EmptyView() }
        }
    }
}
