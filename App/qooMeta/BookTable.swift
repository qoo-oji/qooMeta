import AppKit
import QooMetaKit
import SwiftUI

/// 一覧の表。**AppKit の `NSTableView` をそのまま使う**(SwiftUI の `Table` は使わない)。
///
/// SwiftUI の `Table` は、セル 1 つずつに `NSHostingView` を作り、いちど見せた行を手放さない。1,836 冊の一覧を
/// 眺めただけで、行のビューが 1,202 行ぶん・セルのビューが 1.2 万個残り、メモリは 1.6 GB になった(2026-09-21、
/// 利用者の報告。止まったプロセスを `heap` で数えた)。しかも、どのセルも同じ窓に監視(KVO)を付けるので、付ける・外すが
/// 1 回ごとに「いまある監視の数」に比例し、全体ではセルの数の 2 乗になる ―― 窓を閉じると全部を外すので、そこで固まる。
/// スクロールするほど重くなるのも、列を組み替えると固まるのも同じ根。セルの中身を軽くしても数は減らないので、表ごと替えた。
///
/// `NSTableView` は見えている行のセルだけを持ち、使い回す。1 万冊でもセルは数百のまま。
///
/// 振る舞いは前の表と同じにしてある: 見出しを押して並べ替え、列の並べ替え・幅・表示は利用者が変えられ(覚えておく)、
/// **1 回押しは行を選ぶだけ、2 回押しでそのセルを書き換える**(Return とほかへ移ったときに入り、Esc で元へ戻る)。
///
/// ■ qooViewer へ移した画面で足したものを取り込んだ(2026-09-27)
/// - 巻数(並べ替え用)の列も 2 回押しで直せる。書き換えの最中の Tab / ⇧Tab は、同じ本の次 / 前の直せる欄へ移る。
/// - 右クリックのメニューは画面の側が組む(`contextMenu`)。まとめて直す操作はそこから。
/// - どの型にも合わなかった本は、ファイル名をオレンジで出す(一覧の上にまとめるのは `Workspace` の並べ替え)。
struct BookTable: NSViewRepresentable {
    /// 列。欄の列のほかに、ファイル名と巻数(並べ替え用)がある。
    enum Column: Hashable {
        case fileName
        case field(BookMetadata.Field)
        case volumeSort

        /// 左からの既定の並び(`BookTableView.columns` の説明)。
        static let all: [Column] = [.fileName] + BookTableView.columns.map(Column.field) + [.volumeSort]
            + BookTableView.columnsAfterVolume.map(Column.field)

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .fileName: .init("fileName")
            case .field(let field): .init(field.rawValue)
            case .volumeSort: .init("volumeSort")
            }
        }

        init?(_ identifier: NSUserInterfaceItemIdentifier) {
            guard let column = Self.all.first(where: { $0.identifier == identifier }) else { return nil }
            self = column
        }

        /// 2 回押しで直せる列(直せるかどうかは本ごとに `canEdit` で決める)。ファイル名は名前そのものなので直さない。
        var isEditable: Bool { self != .fileName }

        /// 見出しの言葉の鍵(英語)。
        var titleKey: String {
            switch self {
            case .fileName: "File name"
            case .field(let field): field.labelKey
            case .volumeSort: "Volume (for sorting)"
            }
        }

        var width: (min: CGFloat, ideal: CGFloat, max: CGFloat?) {
            switch self {
            case .fileName: (160, 360, nil)
            case .field(let field): BookTableView.width(field)
            case .volumeSort: (50, 72, 110)
            }
        }

        func text(of book: BookRow) -> String {
            switch self {
            case .fileName: book.fileName
            case .field(let field): book[text: field]
            case .volumeSort: book.volumeSortText
            }
        }

        /// 並べ替えの比べ方(鍵は `BookRow` が 1 冊につき 1 度だけ作ってある)。
        func comparator(_ order: SortOrder) -> KeyPathComparator<BookRow> {
            switch self {
            // 名前そのものではなく、開いたときに決めた順位で比べる(理由は `BookRow.fileRank`)。
            case .fileName: KeyPathComparator(\BookRow.fileRank, order: order)
            case .field(let field): KeyPathComparator(\BookRow[sortKey: field], order: order)
            case .volumeSort: KeyPathComparator(\BookRow[sortKey: .volume], order: order)
            }
        }
    }

    /// 本の全体と、そのうち一覧に出す本の位置(並べ替え・絞り込み済み)。**行の写しは受け取らない**
    /// (全冊ぶんの行をもう 1 組作らないため。`Workspace.visiblePositions`)。
    /// 右クリックのメニューの項目(画面の側が組む)。`children` があればサブメニュー。
    struct MenuItem {
        var title: String
        var isEnabled = true
        var state: NSControl.StateValue = .off
        var children: [MenuItem]?
        var action: (() -> Void)?
        var isSeparator = false

        static var separator: MenuItem { MenuItem(title: "", isSeparator: true) }
    }

    var books: [BookRow]
    var positions: [Int]
    @Binding var selection: Set<BookRow.ID>
    @Binding var sortOrder: [KeyPathComparator<BookRow>]
    var canEdit: (Column, BookRow) -> Bool
    /// 利用者が直した(確定した)欄か。提案のままの値と色で見分ける。
    var isEdited: (Column, BookRow) -> Bool
    var help: (Column, BookRow) -> String
    var commit: (Column, String, BookRow) -> Void
    /// 右クリックのメニュー(右クリックした本、または選んだ本すべてについて)。開いたときに組む(描くたびに作らない)。
    var contextMenu: (Set<BookRow.ID>) -> [MenuItem]
    /// 起点のフォルダ(ファイル名の列の吹き出しに、本の場所を出すため)。
    var rootPath: String

    /// 列の並び・幅・表示を覚えておく名前。
    static let autosaveName = "qooMeta.bookTable"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.all {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let size = column.width
            tableColumn.minWidth = size.min
            tableColumn.width = size.ideal
            if let max = size.max { tableColumn.maxWidth = max }
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        // 列を足してから名前を付ける(覚えてある並び・幅・表示が、ここで戻る)。
        table.autosaveName = Self.autosaveName
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        table.headerView?.menu = menu
        // 行の右クリック。中身は開くときに作る。淡色にするかは画面の側が決める(自動で有効にさせない)。
        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        rowMenu.autoenablesItems = false
        table.menu = rowMenu
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        coordinator.apply(self, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, initial: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // AppKit の部品が画面より長く生きても、画面の閉包(メニューの項目・直した値の入れ先)を握り続けない。
        coordinator.release()
    }

    // MARK: - セル

    /// セル 1 つ(文字だけ)。使い回す。
    final class CellView: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        /// 利用者が直した欄(色を変える)。
        var isEditedValue = false { didSet { updateColor() } }
        /// どの型にも合わなかった本のファイル名(オレンジにする。名前全体を仮のタイトルにしただけで、欄を読めていない)。
        /// 以前は行ごと灰色にしていたが、読めなかった本が目立たず、直した欄の色とも見分けにくかった(qooViewer で変えた)。
        var isUnmatchedName = false { didSet { updateColor() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.cell?.isScrollable = true
            // 切れて見えない名前は、指したときに全体を出す。
            label.allowsExpansionToolTips = true
            addSubview(label)
            textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("コードで組み立てる") }

        /// 選んだ行(強調の地)では、直した欄の色も地に合わせる(色のままだと、選んだ行の上で読めない)。
        override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }

        func updateColor() {
            guard !label.isEditable else { return }
            label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
                : isUnmatchedName ? .systemOrange : isEditedValue ? .controlAccentColor : .labelColor
        }

        /// 書き換えに入る・出るときの見た目(入っているあいだは、ふつうの入力欄の色)。
        func setEditing(_ editing: Bool) {
            label.isEditable = editing
            label.isSelectable = editing
            label.drawsBackground = editing
            label.backgroundColor = editing ? .textBackgroundColor : .clear
            if editing { label.textColor = .textColor } else { updateColor() }
        }
    }

    // MARK: - 仲立ち

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: BookTable?
        weak var table: NSTableView?
        private var books: [BookRow] = []
        private var positions: [Int] = []
        private func book(_ row: Int) -> BookRow { books[positions[row]] }
        private var rowCount: Int { positions.count }
        /// 表のほうを書き換えている最中(その結果として届く知らせで、持ちものを書き戻さない)。
        private var isApplying = false
        /// 書き換えの最中のセル。
        private(set) var editing: (bookID: String, column: Column, original: String, cell: CellView)?
        /// 書き換えの最中に届いた中身(入力を途中で消さないよう、終わってから入れる)。
        private var pendingRows: (books: [BookRow], positions: [Int])?
        /// これまでに作ったセルの数(使い回せているかを確かめるため)。
        private(set) var cellsCreated = 0

        init(_ parent: BookTable) { self.parent = parent }

        /// 画面の閉包を手放す(`dismantleNSView`)。
        func release() {
            parent = nil
            table?.menu = nil
            table?.headerView?.menu = nil
        }

        /// 画面の側の値を表へ入れる。
        func apply(_ parent: BookTable, initial: Bool) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }
            // 見出しは毎回付け直す(言語を変えたときに変わる。10 列なので軽い)。
            for tableColumn in table.tableColumns {
                guard let column = Column(tableColumn.identifier) else { continue }
                let title = column.titleKey.ui
                if tableColumn.title != title { tableColumn.title = title }
            }
            if initial {
                table.sortDescriptors = [NSSortDescriptor(key: Column.fileName.identifier.rawValue, ascending: true)]
            }
            if editing != nil {
                pendingRows = (parent.books, parent.positions)
            } else {
                setRows(parent.books, parent.positions, in: table)
            }
            select(parent.selection, in: table)
        }

        /// 行を入れ替える。**並びが同じなら、変わった行だけを描き直す**(1 冊直すたびに 1 万行を読み直さない)。
        private func setRows(_ newBooks: [BookRow], _ newPositions: [Int], in table: NSTableView) {
            let sameOrder = newPositions == positions
            // 配列の == は、同じ中身を指していればすぐ終わる(選択が変わっただけのとき)。
            guard !(sameOrder && newBooks == books) else { return }
            let oldBooks = books
            books = newBooks
            positions = newPositions
            indexByID = nil
            if sameOrder, oldBooks.count == newBooks.count {
                let changed = IndexSet(newPositions.indices.filter { oldBooks[newPositions[$0]] != newBooks[newPositions[$0]] })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            } else {
                table.reloadData()
            }
        }

        private var indexByID: [String: Int]?

        private func index(of id: String) -> Int? {
            if indexByID == nil {
                indexByID = Dictionary(positions.enumerated().map { (books[$0.element].id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            }
            return indexByID?[id]
        }

        private func select(_ ids: Set<String>, in table: NSTableView) {
            let wanted = IndexSet(ids.compactMap(index(of:)))
            if table.selectedRowIndexes != wanted { table.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        // MARK: 中身

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn, let column = Column(tableColumn.identifier), row >= 0, row < rowCount else { return nil }
            let cell: CellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? CellView {
                cell = reused
            } else {
                cell = CellView(frame: .zero)
                cell.identifier = tableColumn.identifier
                cellsCreated += 1
            }
            let book = book(row)
            cell.isUnmatchedName = column == .fileName && !book.matchedFormat
            cell.setEditing(false)
            cell.label.stringValue = column.text(of: book)
            switch column {
            case .fileName:
                cell.isEditedValue = false
                // どの本かは場所で分かる(同じ名前の本が別のフォルダにあることがある)。
                var tip = (parent.rootPath as NSString).appendingPathComponent(book.id)
                if !book.matchedFormat { tip += "\n" + "This file name matched no format of its rule set".ui }
                cell.toolTip = tip
            case .volumeSort, .field:
                cell.isEditedValue = parent.isEdited(column, book)
                cell.toolTip = parent.help(column, book)
            }
            return cell
        }

        // MARK: 選ぶ・並べ替える

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table, let parent else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rowCount ? book($0).id : nil })
            if parent.selection != ids { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let parent else { return }
            let order = tableView.sortDescriptors.compactMap { descriptor -> KeyPathComparator<BookRow>? in
                guard let key = descriptor.key, let column = Column(.init(key)) else { return nil }
                return column.comparator(descriptor.ascending ? .forward : .reverse)
            }
            if !order.isEmpty { parent.sortOrder = order }
        }

        // MARK: 書き換える

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
            beginEditing(row: table.clickedRow, column: table.clickedColumn)
        }

        /// そのセルの書き換えに入る。読むだけの列(ファイル名)と、いまは直せない欄では何もしない。
        @discardableResult
        func beginEditing(row: Int, column: Int) -> Bool {
            guard let parent, let table, editing == nil, row >= 0, row < rowCount, table.tableColumns.indices.contains(column),
                  let target = Column(table.tableColumns[column].identifier), target.isEditable,
                  parent.canEdit(target, book(row)),
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? CellView else { return false }
            editing = (book(row).id, target, cell.label.stringValue, cell)
            cell.setEditing(true)
            cell.label.delegate = self
            guard table.window?.makeFirstResponder(cell.label) == true else {
                finishEditing(keeping: false)
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            let edited = editing.map { (bookID: $0.bookID, column: $0.column) }
            finishEditing(keeping: true)
            // Return で入れたときは、表へ戻る(矢印で次の行へ行ける)。ほかを押して抜けたときは、押した先を邪魔しない。
            if movement == NSTextMovement.return.rawValue, let table { table.window?.makeFirstResponder(table) }
            // Tab / ⇧Tab は、同じ本の次 / 前の直せる欄へ(表計算・Finder の一覧と同じ。以前は Tab でも書き換えを終えるだけ
            // だった)。並びは見えている列の並び(利用者が並べ替えた順)。入れた値の計算し直しで行が並び直すことがあるので、
            // 本の ID で行を引き直し、書き換えを終えた後の次の回で入る。
            if let edited, movement == NSTextMovement.tab.rawValue || movement == NSTextMovement.backtab.rawValue {
                let forward = movement == NSTextMovement.tab.rawValue
                DispatchQueue.main.async { [weak self] in
                    self?.moveEditing(from: edited.column, of: edited.bookID, forward: forward)
                }
            }
        }

        /// Tab / ⇧Tab の行き先へ書き換えを移す。直せる欄が端まで無ければ表へ戻る。
        private func moveEditing(from column: Column, of bookID: String, forward: Bool) {
            guard let table, editing == nil, let row = index(of: bookID) else { return }
            let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
            guard let current = visible.firstIndex(where: { Column(table.tableColumns[$0].identifier) == column }) else { return }
            var position = current
            while true {
                position += forward ? 1 : -1
                guard visible.indices.contains(position) else { break }
                // 行き先の欄が横にはみ出していれば見える所まで送る(送らないと、見えない欄で書き換えが始まる)。
                table.scrollColumnToVisible(visible[position])
                if beginEditing(row: row, column: visible[position]) { return }
            }
            table.window?.makeFirstResponder(table)
        }

        /// Esc は、元の値へ戻して抜ける。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), editing != nil else { return false }
            control.abortEditing()
            finishEditing(keeping: false)
            if let table { table.window?.makeFirstResponder(table) }
            return true
        }

        private func finishEditing(keeping: Bool) {
            guard let edit = editing else { return }
            editing = nil
            let value = edit.cell.label.stringValue
            edit.cell.label.delegate = nil
            edit.cell.setEditing(false)
            // 表に出すのは、いつも持ちものの値(入れた値は、計算し直しが済んでから行として届く)。
            edit.cell.label.stringValue = edit.original
            if keeping, value.trimmingCharacters(in: .whitespaces) != edit.original,
               let row = index(of: edit.bookID) {
                parent?.commit(edit.column, value, book(row))
            }
            if let pending = pendingRows, let table {
                pendingRows = nil
                isApplying = true
                setRows(pending.books, pending.positions, in: table)
                if let parent { select(parent.selection, in: table) }
                isApplying = false
            }
        }

        // MARK: 列を出す・隠す(見出しの上で右クリック)

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            menu.removeAllItems()
            if menu === table.menu { return fillRowMenu(menu, in: table) }
            // ファイル名の列は隠せない(どの本の行かが分からなくなる)。
            for tableColumn in table.tableColumns {
                guard let column = Column(tableColumn.identifier), column != .fileName else { continue }
                let item = NSMenuItem(title: column.titleKey.ui, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tableColumn
                item.state = tableColumn.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        // MARK: 行の右クリック

        /// 右クリックした行が選んだ本のうちにあれば、選んだ本すべて。なければ、その行の本だけ(Finder と同じ)。
        private func clickedIDs(in table: NSTableView) -> Set<String> {
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < rowCount else { return [] }
            if table.selectedRowIndexes.contains(clicked) {
                return Set(table.selectedRowIndexes.compactMap { $0 < rowCount ? book($0).id : nil })
            }
            return [book(clicked).id]
        }

        private func fillRowMenu(_ menu: NSMenu, in table: NSTableView) {
            let ids = clickedIDs(in: table)
            guard !ids.isEmpty, let parent else { return }
            for item in parent.contextMenu(ids) { menu.addItem(makeItem(item)) }
        }

        private func makeItem(_ item: MenuItem) -> NSMenuItem {
            if item.isSeparator { return .separator() }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.state
            if let children = item.children {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for child in children { submenu.addItem(makeItem(child)) }
                menuItem.submenu = submenu
            } else if let action = item.action {
                menuItem.target = self
                menuItem.action = #selector(runMenuItem(_:))
                menuItem.representedObject = ActionBox(action)
            }
            return menuItem
        }

        /// メニューの項目に持たせる閉包(対象の本は、メニューを開いた時点の選択で決めてある)。
        /// **名前を `perform(_:)` にしない** ―― NSObject の `performSelector:` に化ける。
        private final class ActionBox: NSObject {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }

        @objc func runMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? ActionBox)?.run()
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let tableColumn = sender.representedObject as? NSTableColumn else { return }
            tableColumn.isHidden.toggle()
        }
    }
}
