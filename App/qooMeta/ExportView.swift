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
            Text("Export").font(.headline)
            Picker("Export to", selection: $target) {
                ForEach(ExportTarget.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Form {
                Section("Field mapping (where each field goes)") {
                    ForEach(FieldMapping.Key.allCases, id: \.self) { key in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { mapping.slots[key] },
                                    set: { settings.setMapping(mapping.merging([key: $0])) })) {
                                    Text("Do not pass it on").tag(ExportSlot?.none)
                                    ForEach(target.slots, id: \.self) { Text(key: $0.labelKey(in: target)).tag(ExportSlot?.some($0)) }
                                }
                                .labelsHidden()
                                if let row = preview?.rows.first(where: { $0.key == key }) {
                                    if row.droppedBooks > 0 {
                                        Label("%lld books lose this value".ui(row.droppedBooks), systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if row.truncatedBooks > 0 {
                                        Label("%lld books keep only the first value".ui(row.truncatedBooks), systemImage: "info.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } label: {
                            Text(key: key.labelKey)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to the default") { settings.setMapping(.standard(for: target)) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Close") { dismiss() }
                Button("Export…") { write() }
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
        case .qooViewer: "The qooViewer library JSON, taken in with “Load library data”. It can hold only the title, the authors, the series and the volume as written.".ui
        case .stackNest: "The Stackroom XML that StackNest takes in. It builds a new library rather than adding to one you already have, and its import has no memo field.".ui
        case .shelfRow: "The Stackroom XML that ShelfRow takes in. Its import reads only the title, the authors, keywords A and B and the memo (Neta); the genre, series and volume fields are not read.".ui
        }
    }

    func refresh() async {
        preview = Exporter.preview(await workspace.currentProposals(), mapping: mapping)
    }

    func write() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = target.format == .qooViewerJSON ? [.json] : [.xml]
        panel.nameFieldStringValue = target.format == .qooViewerJSON ? "qooViewer metadata.json".ui : "Stackroom.xml"
        panel.message = "The exported file holds the names of your books. Save it somewhere of your own.".ui
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

extension FieldMapping.Key {
    /// 画面に出す言葉の鍵(英語)。QooMetaExport の `label` は、CLI が使う日本語のままにしてある。
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
        case .volumeSort: "Volume (for sorting)"
        }
    }
}

extension ExportSlot {
    /// 行き先の欄の見出しの鍵。同じ欄でも、取り込む側での呼び名が違うことがある。
    func labelKey(in target: ExportTarget) -> String {
        if self == .neta, target == .shelfRow { return "Memo (Neta)" }
        return switch self {
        case .title: "Title"
        case .author: "Author"
        case .genre: "Genre"
        case .series: "Series"
        case .volume: "Volume (number)"
        case .seriesIndex: "Volume (as written)"
        case .neta: "Neta"
        case .keywordA: "Keyword A"
        case .keywordB: "Keyword B"
        case .keywordC: "Keyword C"
        }
    }
}
