import QooMetaExport
import QooMetaKit
import SwiftUI
import UniformTypeIdentifiers

/// 書き出しの画面。書き出し先を選び、**どの欄がどこへ行き、どこで落ちるか**を見てから書く。
///
/// 読み方は 1 つで、書き出し先ごとの違いは対応表で振り分ける(docs/metadata.md)。対応表はアプリの設定に残る。
struct ExportView: View {
    @Bindable var workspace: Workspace
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var target: ExportTarget = .stackNest
    @State private var preview: ExportPreview?
    @State private var error: String?

    var mapping: FieldMapping { settings.mapping(for: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("書き出し").font(.headline)
            Picker("書き出し先", selection: $target) {
                ForEach(ExportTarget.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Form {
                Section("欄の対応(どこへ渡すか)") {
                    ForEach(FieldMapping.Key.allCases, id: \.self) { key in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { mapping.slots[key] },
                                    set: { settings.setMapping(mapping.merging([key: $0])) })) {
                                    Text("渡さない").tag(ExportSlot?.none)
                                    ForEach(target.slots, id: \.self) { Text($0.label).tag(ExportSlot?.some($0)) }
                                }
                                .labelsHidden()
                                if let row = preview?.rows.first(where: { $0.key == key }) {
                                    if row.droppedBooks > 0 {
                                        Label("\(row.droppedBooks) 冊の値が落ちる", systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if row.truncatedBooks > 0 {
                                        Label("\(row.truncatedBooks) 冊は先頭だけ", systemImage: "info.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } label: {
                            Text(key.label)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("既定に戻す") { settings.setMapping(.standard(for: target)) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("閉じる") { dismiss() }
                Button("書き出す…") { write() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.books.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .task(id: "\(target.rawValue)\(mapping.slots.map(\.value.rawValue).sorted().joined())\(workspace.books.count)") {
            await refresh()
        }
    }

    var note: String {
        switch target {
        case .qooViewer: "qooViewer の保存データ JSON(「保存データの読み込み」で取り込む)。持てる欄はタイトル・著者・シリーズ・巻数の表記だけ。"
        case .stackNest: "StackNest が取り込む Stackroom XML。**新しいライブラリを作る**形式で、既存のライブラリへは足せない。"
        case .shelfRow: "ShelfRow が取り込む Stackroom XML。シリーズと巻の欄が無いので、巻数の表記は空いている欄へ回す。"
        }
    }

    func refresh() async {
        preview = Exporter.preview(await workspace.currentProposals(), mapping: mapping)
    }

    func write() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = target.format == .qooViewerJSON ? [.json] : [.xml]
        panel.nameFieldStringValue = target.format == .qooViewerJSON ? "qooViewer メタデータ.json" : "Stackroom.xml"
        panel.message = "書き出したファイルには蔵書の名前が入ります。手元の場所へ保存してください。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let set = await workspace.currentProposals()
                let data: Data = switch target.format {
                case .stackroomXML:
                    try Exporter.stackroomXML(set, files: workspace.fileFacts, mapping: mapping)
                case .qooViewerJSON:
                    try Exporter.qooViewerJSON(set, identities: workspace.fileIdentities, mapping: mapping)
                }
                try data.write(to: url, options: .atomic)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
