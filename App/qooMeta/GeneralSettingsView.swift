import SwiftUI

/// 環境設定(⌘,)。アプリ全体の好み。**規則とプリセットは別の窓**(中身が大きく、一覧を見ながら直すため)。
struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { settings.language }, set: { settings.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { Text(key: $0.key).tag($0) }
                } label: {
                    Text("Language")
                }
                Text("Applies to this app only. Your macOS settings are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Display")
            }

            Section {
                Toggle(isOn: Binding(get: { settings.quitsWhenLastWindowCloses },
                                     set: { settings.setQuitsWhenLastWindowCloses($0) })) {
                    Text("Quit when the last window closes")
                }
                Text("Off by default, as macOS expects: closing every window leaves the app running, so you can open the next list from the Dock. Turning it on takes effect the next time you close a window.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Windows")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
