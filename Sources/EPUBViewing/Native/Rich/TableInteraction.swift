import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One thing an assistive technology can do with what a table's cell shows.
struct ReaderTableAction {
    var name: String
    /// Performing it changes what the cell's item says of itself and offers. VoiceOver holds
    /// both as it found them when its cursor came to the item, and is to be told.
    var changesItem = false
    var perform: @MainActor () -> Bool
}

/// Only laid-out, visible rows receive native text surfaces. Their transparent glyphs use
/// the attachment's exact TextKit 1 metrics; table decoration and ink stay in the row drawing.
@MainActor final class ReaderTableInteraction {
    struct Key: Hashable { var location: Int; var cell: Int; var lower: Int; var upper: Int }
    weak var owner: ReaderTextView?
    private(set) var cells: [Key: TableCellTextView] = [:]
    private var updating = false
    private var sourceText: NSAttributedString?
    private var projectedSelections: [Key: NSRange] = [:]
    /// The place of a row off screen whose cells stand all the same (`keepRow`).
    private(set) var keptRow: Int?

    init(owner: ReaderTextView) { self.owner = owner }

    /// Has the row at `location` keep its cells while it is off screen, in place of the row
    /// kept before. On Mac the row after the screen that holds the book's next link is one an
    /// assistive client is given that link from (`ReaderTextView.linkChildrenWithCells`), and
    /// a link's element is its cell's.
    func keepRow(at location: Int?) {
        guard keptRow != location else { return }
        #if os(macOS)
        owner?.probe("KEEPROW \(location.map(String.init) ?? "none") was \(keptRow.map(String.init) ?? "none")")
        #endif
        keptRow = location
        refresh()
    }

    func removeViews() {
        for cell in cells.values { cell.removeFromSuperview() }
        cells.removeAll()
    }

    func hasCells(at location: Int) -> Bool { cells.keys.contains { $0.location == location } }

    func accessibilityCells(at location: Int) -> [TableCellTextView] { shown(at: location) }

    /// The cells on screen in reading order, each with its row's place in the text.
    var accessibilityCellsInOrder: [(location: Int, cell: TableCellTextView)] {
        cells.sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }
            .map { ($0.key.location, $0.value) }
    }

    /// The text views of one cell of the row at `location`, in the order of the lines they hold.
    func accessibilityCells(at location: Int, cell index: Int) -> [TableCellTextView] {
        cells.filter { $0.key.location == location && $0.key.cell == index }.sorted { $0.key.lower < $1.key.lower }.map(\.value)
    }

    func selectionPosition(at point: CGPoint) -> ReaderTextPosition? {
        guard let owner, let canvas = owner.canvas, let storage = owner.contentStorage.textStorage else { return nil }
        for (key, cell) in cells {
            let local = cell.convert(point, from: owner)
            guard cell.bounds.contains(local), let anchor = canvas.position(at: key.location, in: owner),
                  let row = storage.attribute(.attachment, at: key.location, effectiveRange: nil) as? TableRowAttachment else { continue }
            return ReaderTextPosition(section: anchor.section, offset: row.table.sourceRowOffsets[row.table.cells[key.cell].row] ?? anchor.offset,
                tableCell: ReaderTablePosition(table: row.table.sourceOrder, cell: key.cell,
                    offset: cell.cellCharacterOffset(at: local)))
        }
        return nil
    }

    /// What an assistive technology can do with the words `cell` shows: select them and, once
    /// words of the cell are selected, take the selection away, copy it, or give it to the
    /// host's selection action. The last two are what the edit menu offers a selection made
    /// by touch; VoiceOver is given a row's or a cell's actions and never meets that menu.
    /// `label` names the cell where a row holds several, and `uses` is false for a row's
    /// later cells: a passage selected through several is one selection, to copy once.
    private func selectionActions(of cell: TableCellTextView, named label: String?, uses: Bool = true) -> [ReaderTableAction] {
        let words = cell.cellText.readerPlainText(in: cell.shownCharacters)
        // A cell without words, a picture alone, has none to select or to name the action by.
        guard !words.allSatisfy(\.isWhitespace) else { return [] }
        let subject = label.map { "Table Text: " + $0 } ?? "Cell Text"
        guard cell.cellSelection.length > 0 else {
            return [ReaderTableAction(name: "Select " + subject, changesItem: true) { [weak cell] in
                guard let cell else { return false }
                cell.cellSelection = cell.shownCharacters
                cell.onSelection?(cell.shownCharacters)
                return true
            }]
        }
        var result = [ReaderTableAction(name: "Deselect " + subject, changesItem: true) { [weak self] in
            guard let canvas = self?.owner?.canvas else { return false }
            canvas.clearSelection()
            return true
        }]
        guard uses else { return result }
        // VoiceOver may still hold these from before the selection went another way.
        result.append(ReaderTableAction(name: "Copy") { [weak self, weak cell] in
            guard let cell, cell.cellSelection.length > 0 else { return false }
            cell.copy(nil)
            // Nothing a listener can tell changes when the words are copied.
            #if os(iOS)
            self?.owner?.canvas?.announce("Copied")
            #endif
            return true
        })
        if let title = owner?.canvas?.configuration.selectionActionTitle {
            result.append(ReaderTableAction(name: title) { [weak cell] in
                guard let cell, cell.cellSelection.length > 0 else { return false }
                cell.onAction?()
                return true
            })
        }
        return result
    }

    private func links(of cell: TableCellTextView, prefix: String) -> [ReaderTableAction] {
        var result: [ReaderTableAction] = []
        cell.cellText.enumerateAttribute(.link, in: cell.shownCharacters) { value, range, _ in
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return }
            result.append(ReaderTableAction(name: prefix + cell.cellText.readerPlainText(in: range)) { [weak cell] in
                cell?.onLink?(url, range); return cell != nil
            })
        }
        return result
    }

    private func shown(at location: Int, cell index: Int? = nil) -> [TableCellTextView] {
        cells.filter { $0.key.location == location && (index == nil || $0.key.cell == index) }
            .sorted { ($0.key.cell, $0.key.lower) < ($1.key.cell, $1.key.lower) }.map(\.value)
    }

    /// Words are selected in a cell shown of the row at `location`, or in the one cell named.
    func holdsSelection(at location: Int, cell index: Int? = nil) -> Bool {
        shown(at: location, cell: index).contains { $0.cellSelection.length > 0 }
    }

    /// What an assistive technology can do with the cells shown of the row at `location`.
    func accessibilityActions(at location: Int) -> [ReaderTableAction] {
        var result: [ReaderTableAction] = [], selected = false
        for cell in shown(at: location) {
            result += selectionActions(of: cell, named: String(cell.cellText.readerPlainText(in: cell.shownCharacters).prefix(60)), uses: !selected)
            selected = selected || cell.cellSelection.length > 0
            result += links(of: cell, prefix: "Follow Table Link: ")
        }
        return result
    }

    /// What an assistive technology can do with one cell of the row at `location`: select the
    /// words it shows there or act on those selected, and follow each link among them, named
    /// by its words. `selected` says that the first are for a selection the cell holds.
    func accessibilityActions(at location: Int, cell index: Int) -> (selection: [ReaderTableAction], selected: Bool, links: [ReaderTableAction]) {
        var selection: [ReaderTableAction] = [], selected = false, found: [ReaderTableAction] = []
        for cell in shown(at: location, cell: index) {
            // A cell shown in several pieces is one item: a piece that holds a selection answers for it.
            if selection.isEmpty || (cell.cellSelection.length > 0 && !selected) {
                let offered = selectionActions(of: cell, named: nil)
                if !offered.isEmpty { (selection, selected) = (offered, cell.cellSelection.length > 0) }
            }
            found += links(of: cell, prefix: "")
        }
        return (selection, selected, found)
    }

    func refresh() {
        guard !updating, let owner, let storage = owner.contentStorage.textStorage else { return }
        #if os(macOS)
        // The rows on screen are read off the layout, which stands where the view draws it
        // only once the view has been held to it.
        owner.holdScrollPlace()
        #endif
        updating = true
        defer { updating = false }
        if sourceText !== owner.flowSourceText {
            for cell in cells.values { cell.removeFromSuperview() }
            cells.removeAll()
            projectedSelections.removeAll()
            sourceText = owner.flowSourceText
            keptRow = nil
        }
        var retained: Set<Key> = []
        #if os(macOS)
        let visible = owner.visibleRect
        #else
        let visible = owner.bounds
        #endif
        let origin = owner.containerOrigin
        var ranges: [NSRange] = []
        #if os(macOS)
        // TRIAL, not for main.
        let probing = ReaderProbe.isOn && !owner.isPageColumn
        let probeCaret = owner.selectedRange.location
        var probeFragment = "none", probeRows: [String] = []
        #endif
        owner.readerLayoutManager.enumerateTextLayoutFragments(from: owner.contentStorage.documentRange.location, options: []) { fragment in
            #if os(macOS)
            if probing {
                let lower = owner.offset(of: fragment.rangeInElement.location), upper = owner.offset(of: fragment.rangeInElement.endLocation)
                if lower <= probeCaret, probeCaret < upper {
                    probeFragment = "state \(fragment.state.rawValue) y \(Int(fragment.layoutFragmentFrame.minY + origin.y))+\(Int(fragment.layoutFragmentFrame.height))"
                }
            }
            #endif
            guard fragment.state == .layoutAvailable,
                  !fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y).intersection(visible).isEmpty else { return true }
            let lower = owner.offset(of: fragment.rangeInElement.location)
            let upper = min(owner.placement.visibleLength, owner.offset(of: fragment.rangeInElement.endLocation))
            if lower >= 0, upper > lower { ranges.append(NSRange(location: lower, length: upper - lower)) }
            return true
        }
        if let keptRow, keptRow < storage.length, !ranges.contains(where: { NSLocationInRange(keptRow, $0) }) {
            ranges.append(NSRange(location: keptRow, length: 1))
        }
        for range in ranges {
            storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
                guard let row = value as? TableRowAttachment else { return }
                #if os(macOS)
                if probing, owner.segmentFrames(for: run).isEmpty { probeRows.append("\(run.location) no segment") }
                #endif
                guard let frame = owner.segmentFrames(for: run).first else { return }
                #if os(macOS)
                if probing {
                    let items = row.interactionCells(size: frame.size, viewportHeight: owner.readerContainer.viewportSize.height)
                    let shown = items.filter { !$0.frame.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y).intersection(visible).isEmpty }.count
                    probeRows.append("\(run.location) y \(Int(frame.minY + origin.y))+\(Int(frame.height)) cells \(shown)/\(items.count)")
                }
                #endif
                for item in row.interactionCells(size: frame.size, viewportHeight: owner.readerContainer.viewportSize.height) {
                    let key = Key(location: run.location, cell: item.cell,
                        lower: item.characters.location, upper: item.characters.upperBound)
                    let target = item.frame.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
                    guard !target.intersection(visible).isEmpty || run.location == keptRow else { continue }
                    retained.insert(key)
                    let cell: TableCellTextView
                    if let existing = cells[key] { cell = existing }
                    else {
                        cell = TableCellTextView(text: item.text, width: item.width, characters: item.characters)
                        cell.canvas = owner.canvas
                        cell.onSelection = { [weak self, weak cell] selected in
                            guard let self, !self.updating, let owner = self.owner, let cell,
                                  let canvas = owner.canvas, let anchor = canvas.position(at: run.location, in: owner) else { return }
                            if self.projectedSelections[key] == selected,
                               self.cells.allSatisfy({ self.projectedSelections[$0.key] == $0.value.cellSelection }) { return }
                            self.projectedSelections.removeAll()
                            if selected.length == 0 {
                                if !self.cells.values.contains(where: { $0 !== cell && $0.cellSelection.length > 0 }) {
                                    canvas.setExternalSelection(nil, source: self)
                                }
                                return
                            }
                            self.updating = true
                            for other in self.cells.values where other !== cell { other.cellSelection = NSRange(location: 0, length: 0) }
                            self.updating = false
                            let start = ReaderTextPosition(section: anchor.section, offset: row.table.sourceRowOffsets[row.table.cells[item.cell].row] ?? anchor.offset,
                                tableCell: ReaderTablePosition(table: row.table.sourceOrder, cell: item.cell, offset: selected.location))
                            let end = ReaderTextPosition(section: anchor.section, offset: row.table.sourceRowOffsets[row.table.cells[item.cell].row] ?? anchor.offset,
                                tableCell: ReaderTablePosition(table: row.table.sourceOrder, cell: item.cell, offset: selected.upperBound))
                            canvas.setExternalSelection(ReaderSelection(range: ReaderTextRange(start: start, end: end),
                                text: item.text.readerPlainText(in: selected)), source: self)
                        }
                        cell.onLink = { [weak owner, weak cell] url, characters in
                            guard let owner, let cell, let canvas = owner.canvas,
                                  let anchor = canvas.position(at: run.location, in: owner) else { return }
                            let position = ReaderTextPosition(section: anchor.section, offset: row.table.sourceRowOffsets[row.table.cells[item.cell].row] ?? anchor.offset,
                                tableCell: ReaderTablePosition(table: row.table.sourceOrder, cell: item.cell, offset: characters.location))
                            canvas.activateExternalLink(url, position: position, rect: cell.convert(cell.bounds, to: canvas))
                        }
                        cell.onAction = { [weak owner] in owner?.canvas?.performSelectionAction() }
                        cell.onCopy = { [weak self, weak owner] in
                            guard let self else { return nil }
                            return owner?.canvas?.selectionText(for: self)
                        }
                        cell.onImage = { [weak owner] image in owner?.canvas?.inspectImage(image) }
                        cells[key] = cell
                        owner.addSubview(cell)
                    }
                    cell.configure(frame: target, scale: item.scale,
                        textOffset: CGPoint(x: (item.frame.minX - item.textOrigin.x) / item.scale,
                                            y: (item.frame.minY - item.textOrigin.y) / item.scale),
                        actionTitle: owner.canvas?.configuration.selectionActionTitle)
                }
            }
        }
        for key in Array(cells.keys) where !retained.contains(key) { cells.removeValue(forKey: key)?.removeFromSuperview() }
        #if os(macOS)
        if probing {
            let text = "TABLES clip \(Int(visible.minY))+\(Int(visible.height)) ranges \(ranges.count) caret \(probeCaret) fragment \(probeFragment)"
                + " kept \(keptRow.map(String.init) ?? "none") rows \(probeRows)"
            owner.probe(text)
        }
        #endif
    }

    func clearSelection() {
        projectedSelections.removeAll()
        updating = true
        for cell in cells.values { cell.cellSelection = NSRange(location: 0, length: 0) }
        updating = false
    }

    func select(_ range: ReaderTextRange, reporting: Bool = true) -> Bool {
        guard let owner, let canvas = owner.canvas else { return false }
        refresh()
        var found = false
        updating = true
        for (key, cell) in cells {
            cell.cellSelection = NSRange(location: 0, length: 0)
            guard let position = canvas.position(at: key.location, in: owner),
                  let storage = owner.contentStorage.textStorage,
                  let row = storage.attribute(.attachment, at: key.location, effectiveRange: nil) as? TableRowAttachment,
                  position.section >= range.start.section, position.section <= range.end.section else { continue }
            let lower: Int
            let upper: Int
            if let start = range.start.tableCell, position.section == range.start.section {
                guard row.table.sourceOrder >= start.table else { continue }
                if row.table.sourceOrder == start.table {
                    guard key.cell >= start.cell else { continue }
                    lower = key.cell == start.cell ? start.offset : 0
                } else { lower = 0 }
            } else {
                guard position >= range.start else { continue }; lower = 0
            }
            if let end = range.end.tableCell, position.section == range.end.section {
                guard row.table.sourceOrder <= end.table else { continue }
                if row.table.sourceOrder == end.table {
                    guard key.cell <= end.cell else { continue }
                    upper = key.cell == end.cell ? end.offset : cell.cellText.length
                } else { upper = cell.cellText.length }
            } else {
                guard position < range.end else { continue }; upper = cell.cellText.length
            }
            let intersection = NSIntersectionRange(NSRange(location: lower, length: max(0, upper - lower)), cell.shownCharacters)
            cell.cellSelection = intersection
            if intersection.length > 0 { found = true }
        }
        projectedSelections = cells.mapValues { $0.cellSelection }
        updating = false
        if found, reporting {
            let text = canvas.currentSelection?.range == range ? canvas.currentSelection?.text : nil
            canvas.setExternalSelection(ReaderSelection(range: range, text: text ?? selectedText()), source: self)
        }
        return found
    }

    func selectedText() -> String {
        cells.sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }
            .filter { $0.value.cellSelection.length > 0 }
            .map { $0.value.cellText.readerPlainText(in: $0.value.cellSelection) }.joined(separator: "\t")
    }

    func selectionContinues(_ range: ReaderTextRange, forward: Bool) -> Bool {
        let endpoint = forward ? range.end : range.start
        guard let target = endpoint.tableCell, let visible = visibleCharacters(for: endpoint) else { return false }
        return forward ? visible.upperBound < target.offset : visible.location > target.offset
    }

    func visibleCharacters(for endpoint: ReaderTextPosition) -> NSRange? {
        guard let owner, let canvas = owner.canvas, let storage = owner.contentStorage.textStorage else { return nil }
        guard let target = endpoint.tableCell else { return nil }
        let matching = cells.keys.filter { key in
            guard let position = canvas.position(at: key.location, in: owner), position.section == endpoint.section,
                  let row = storage.attribute(.attachment, at: key.location, effectiveRange: nil) as? TableRowAttachment else { return false }
            return row.table.sourceOrder == target.table && key.cell == target.cell
        }
        guard let lower = matching.map(\.lower).min(), let upper = matching.map(\.upper).max() else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    func highlights(_ highlights: [ReaderHighlight]) {
        guard let owner, let canvas = owner.canvas, let storage = owner.contentStorage.textStorage else { return }
        for (key, cell) in cells {
            var runs: [(NSRange, PlatformColor)] = []
            guard let position = canvas.position(at: key.location, in: owner),
                  let row = storage.attribute(.attachment, at: key.location, effectiveRange: nil) as? TableRowAttachment else { continue }
            for highlight in highlights where highlight.range.start.section <= position.section && highlight.range.end.section >= position.section {
                let start = highlight.range.start, end = highlight.range.end
                var lower = 0, upper = cell.cellText.length
                if let endpoint = start.tableCell, start.section == position.section {
                    if row.table.sourceOrder < endpoint.table || (row.table.sourceOrder == endpoint.table && key.cell < endpoint.cell) { continue }
                    if row.table.sourceOrder == endpoint.table && key.cell == endpoint.cell { lower = endpoint.offset }
                } else if position < start { continue }
                if let endpoint = end.tableCell, end.section == position.section {
                    if row.table.sourceOrder > endpoint.table || (row.table.sourceOrder == endpoint.table && key.cell > endpoint.cell) { continue }
                    if row.table.sourceOrder == endpoint.table && key.cell == endpoint.cell { upper = endpoint.offset }
                } else if position >= end { continue }
                if upper > lower {
                    runs.append((NSRange(location: lower, length: upper - lower),
                                 ReaderPalette.highlight(highlight.kind, dark: canvas.configuration.isDark)))
                }
            }
            cell.setCellHighlights(runs)
        }
    }
}

extension ReaderTextView {
    func refreshTableInteractions() {
        guard canvas != nil, containsTableRows else {
            tableInteraction?.removeViews()
            tableInteraction = nil
            return
        }
        if tableInteraction == nil { tableInteraction = ReaderTableInteraction(owner: self) }
        tableInteraction?.refresh()
    }
    func clearTableSelection() { tableInteraction?.clearSelection() }
    func selectTableRange(_ range: ReaderTextRange, reporting: Bool = true) -> Bool {
        refreshTableInteractions()
        return tableInteraction?.select(range, reporting: reporting) ?? false
    }
    func setTableHighlights(_ highlights: [ReaderHighlight]) {
        refreshTableInteractions()
        tableInteraction?.highlights(highlights)
    }
}
