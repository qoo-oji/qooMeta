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
    var books: [BookRow]
    var positions: [Int]
    @Binding var selection: Set<BookRow.ID>
    @Binding var sortOrder: [KeyPathComparator<BookRow>]
    var canEdit: (BookMetadata.Field, BookRow) -> Bool
    /// 利用者が直した(確定した)欄か。提案のままの値と色で見分ける。
    var isEdited: (BookMetadata.Field, BookRow) -> Bool
    var help: (BookMetadata.Field, BookRow) -> String
    var commit: (BookMetadata.Field, String, BookRow) -> Void
    /// 右クリックで選べるルールセット(ID と見出し。並びの順)。開いたときに聞く(描くたびに作らない)。
    var ruleSets: () -> [(id: String, title: String)]
    /// その本を読んでいるルールセットの ID。
    var ruleSetOf: (String) -> String
    /// 選んだ本の名前を、そのルールセットで読み直す。
    var reparse: (Set<BookRow.ID>, String) -> Void

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
        // 行の右クリック(選んだ本を、ほかのルールセットで読み直す)。中身は開くときに作る。
        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
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

    // MARK: - セル

    /// セル 1 つ(文字だけ)。使い回す。
    final class CellView: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        /// 利用者が直した欄(色を変える)。
        var isEditedValue = false { didSet { updateColor() } }
        /// どの型にも合わなかった本の行(灰色にする。名前全体を仮のタイトルにしただけで、欄を読めていない)。
        var isUnmatched = false { didSet { updateColor() } }

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
                : isEditedValue ? .controlAccentColor : isUnmatched ? .tertiaryLabelColor : .labelColor
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
        var parent: BookTable
        weak var table: NSTableView?
        private var books: [BookRow] = []
        private var positions: [Int] = []
        private func book(_ row: Int) -> BookRow { books[positions[row]] }
        private var rowCount: Int { positions.count }
        /// 表のほうを書き換えている最中(その結果として届く知らせで、持ちものを書き戻さない)。
        private var isApplying = false
        /// 書き換えの最中のセル。
        private(set) var editing: (bookID: String, field: BookMetadata.Field, original: String, cell: CellView)?
        /// 書き換えの最中に届いた中身(入力を途中で消さないよう、終わってから入れる)。
        private var pendingRows: (books: [BookRow], positions: [Int])?
        /// これまでに作ったセルの数(使い回せているかを確かめるため)。
        private(set) var cellsCreated = 0

        init(_ parent: BookTable) { self.parent = parent }

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
            guard let tableColumn, let column = Column(tableColumn.identifier), row >= 0, row < rowCount else { return nil }
            let cell: CellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? CellView {
                cell = reused
            } else {
                cell = CellView(frame: .zero)
                cell.identifier = tableColumn.identifier
                cellsCreated += 1
            }
            let book = book(row)
            cell.isUnmatched = !book.matchedFormat
            cell.setEditing(false)
            cell.label.stringValue = column.text(of: book)
            switch column {
            case .fileName:
                cell.isEditedValue = false
                cell.toolTip = nil
            case .volumeSort:
                cell.isEditedValue = false
                cell.toolTip = "Derived from the volume as written, by the rules for reading a volume".ui
            case .field(let field):
                cell.isEditedValue = parent.isEdited(field, book)
                cell.toolTip = parent.help(field, book)
            }
            return cell
        }

        // MARK: 選ぶ・並べ替える

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rowCount ? book($0).id : nil })
            if parent.selection != ids { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying else { return }
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

        /// そのセルの書き換えに入る。読むだけの列(ファイル名・巻数の並べ替え用)と、いまは直せない欄では何もしない。
        @discardableResult
        func beginEditing(row: Int, column: Int) -> Bool {
            guard let table, editing == nil, row >= 0, row < rowCount, table.tableColumns.indices.contains(column),
                  case .field(let field)? = Column(table.tableColumns[column].identifier),
                  parent.canEdit(field, book(row)),
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? CellView else { return false }
            editing = (book(row).id, field, cell.label.stringValue, cell)
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
            finishEditing(keeping: true)
            // Return で入れたときは、表へ戻る(矢印で次の行へ行ける)。ほかを押して抜けたときは、押した先を邪魔しない。
            if movement == NSTextMovement.return.rawValue, let table { table.window?.makeFirstResponder(table) }
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
                parent.commit(edit.field, value, book(row))
            }
            if let pending = pendingRows, let table {
                pendingRows = nil
                isApplying = true
                setRows(pending.books, pending.positions, in: table)
                select(parent.selection, in: table)
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

        // MARK: 読み直す(行の上で右クリック)

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
            guard !ids.isEmpty else { return }
            let current = Set(ids.map(parent.ruleSetOf))
            let item = NSMenuItem(title: "Parse the File Name Again With".ui, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for ruleSet in parent.ruleSets() {
                let choice = NSMenuItem(title: ruleSet.title, action: #selector(reparse(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = ReparseTarget(ids: ids, ruleSet: ruleSet.id)
                // いまのルールセットに印を付ける(選んだ本で分かれていれば、半分の印)。
                choice.state = current.contains(ruleSet.id) ? (current.count == 1 ? .on : .mixed) : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        /// メニューの項目に持たせる、読み直す本とルールセット(開いた時点の選択で決める)。
        private final class ReparseTarget: NSObject {
            let ids: Set<String>
            let ruleSet: String
            init(ids: Set<String>, ruleSet: String) {
                self.ids = ids
                self.ruleSet = ruleSet
            }
        }

        @objc func reparse(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? ReparseTarget else { return }
            parent.reparse(target.ids, target.ruleSet)
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let tableColumn = sender.representedObject as? NSTableColumn else { return }
            tableColumn.isHidden.toggle()
        }
    }
}
