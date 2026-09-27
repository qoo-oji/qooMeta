import AppKit

/// 確かめのアラートと、開く・保存のパネルを、**操作した窓に付くシート**として出す(macOS の標準)。
///
/// `runModal()` だと、出ているあいだアプリ全体が止まり、ほかの窓(規則の窓など)も触れない。qooViewer へ移した
/// 3 段目の画面で直したものを取り込んだ(2026-09-27)。出す先はキーウインドウで、その窓に既にシートが付いていれば、
/// いちばん上のシートに重ねる ―― `beginSheet` はシートの付いた窓へ出すと、前のシートが閉じるまで待たせるので。
/// 窓が無い・見えていないときは、今までどおりアプリ全体のモーダルで出す。
///
/// 終了の確かめ(`applicationShouldTerminate`)は、アプリ全体の話なので、これを通さず `runModal()` のまま。
@MainActor
enum WindowSheet {
    /// 出す先(nil ならアプリ全体のモーダル)。
    private static func host() -> NSWindow? {
        guard var window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        while let sheet = window.attachedSheet { window = sheet }
        return window.isVisible && !window.isMiniaturized ? window : nil
    }

    static func begin(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let host = host() else { return completion(panel.runModal()) }
        // 同じ窓でパネルがもう出ている(メニューはシートのあいだも押せる)。パネルの上にパネルを重ねない。
        guard !(host is NSSavePanel) else {
            NSSound.beep()
            return completion(.cancel)
        }
        panel.beginSheetModal(for: host) { response in
            // 完了ハンドラの中では、シートはまだ窓に付いている(AppKit は返ってから下ろす)。続きは下りてから。
            Task { @MainActor in completion(response) }
        }
    }

    static func begin(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let host = host(), !(host is NSSavePanel) else { return completion(alert.runModal()) }
        alert.beginSheetModal(for: host) { response in
            Task { @MainActor in completion(response) }
        }
    }
}
