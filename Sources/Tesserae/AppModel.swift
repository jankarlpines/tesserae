import AppKit
import SwiftUI

/// What the status bar shows for the box under the mouse. Kept separate so hovering
/// does not redraw the whole window.
@MainActor final class HoverState: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
}

@MainActor final class AppModel: ObservableObject {
    @Published var root: Node?
    @Published var current: Node?
    /// Selected boxes, in click order. Shift- or ⌘-click adds and removes.
    @Published var selection: [Node] = []
    @Published var scanning = false
    @Published var scannedCount = 0
    @Published var topFiles: [Node] = [] { didSet { resortList() } }
    @Published var version = 0
    @Published var errorText: String?
    @Published var showHidden: Bool {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            if let root { scan(root.url) }
        }
    }

    @Published var mapSort: SortKey { didSet { UserDefaults.standard.set(mapSort.rawValue, forKey: "mapSort") } }
    @Published var mapReversed: Bool { didSet { UserDefaults.standard.set(mapReversed, forKey: "mapReversed") } }
    @Published var listSort: SortKey { didSet { UserDefaults.standard.set(listSort.rawValue, forKey: "listSort"); resortList() } }
    @Published var listReversed: Bool { didSet { UserDefaults.standard.set(listReversed, forKey: "listReversed"); resortList() } }

    /// The sidebar's files in the chosen order. Sorted once when something changes, not on every redraw.
    @Published private(set) var sortedTopFiles: [Node] = []
    private func resortList() { sortedTopFiles = listSort.sorted(topFiles, reversed: listReversed) }

    /// The sidebar's selection, as the native List sees it. Shift-click selects a range, ⌘-click toggles.
    var listSelection: Set<ObjectIdentifier> {
        get { Set(selection.map(ObjectIdentifier.init)) }
        set {
            let nodes = sortedTopFiles.filter { newValue.contains(ObjectIdentifier($0)) }
            selection = nodes
            reveal(onMap: nodes)
        }
    }

    /// Zooms out just enough that every node is visible on the map.
    private func reveal(onMap nodes: [Node]) {
        guard let cur = current, nodes.contains(where: { !$0.isDescendant(of: cur) }) else { return }
        var common = nodes.first?.parent?.ancestors ?? []
        for n in nodes.dropFirst() {
            let chain = n.parent?.ancestors ?? []
            var i = 0
            while i < common.count, i < chain.count, common[i] === chain[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        if let target = common.last { zoom(to: target) }
    }

    let hover = HoverState()
    private var scanner: Scanner?
    private var pollTimer: Timer?

    init() {
        let d = UserDefaults.standard
        showHidden = d.bool(forKey: "showHidden")
        mapSort = SortKey(rawValue: d.string(forKey: "mapSort") ?? "") ?? .size
        mapReversed = d.bool(forKey: "mapReversed")
        listSort = SortKey(rawValue: d.string(forKey: "listSort") ?? "") ?? .size
        listReversed = d.bool(forKey: "listReversed")
        resortList()
        if let last = UserDefaults.standard.string(forKey: "lastFolder"),
           FileManager.default.fileExists(atPath: last) {
            scan(URL(fileURLWithPath: last))
        }
    }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to map"
        if let root { panel.directoryURL = root.url }
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func rescan() { if let root { scan(root.url) } }

    func scan(_ url: URL) {
        scanner?.cancel()
        let s = Scanner(showHidden: showHidden)
        scanner = s
        scanning = true
        scannedCount = 0
        errorText = nil
        UserDefaults.standard.set(url.path, forKey: "lastFolder")

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scannedCount = s.filesScanned }
        }

        Task.detached(priority: .userInitiated) {
            let node = s.scan(url)
            let top = largestFiles(in: node)
            await MainActor.run { [weak self] in
                guard let self, self.scanner === s, !s.isCancelled else { return }
                self.pollTimer?.invalidate()
                self.scanning = false
                self.root = node
                self.current = node
                self.selection = []
                self.topFiles = top
                self.version += 1
                if node.fileCount == 0 && node.children.isEmpty {
                    self.errorText = "Nothing readable in this folder. If it's a protected folder, give Tesserae Full Disk Access in System Settings."
                }
            }
        }
    }

    // MARK: Navigation

    func zoom(to node: Node) {
        guard node.isDir else { return }
        current = node
        version += 1
    }

    func goUp() {
        if let p = current?.parent { zoom(to: p) }
    }

    func activate(_ node: Node) {
        if node.isDir && (!node.isPackage || showHidden) && !node.children.isEmpty { zoom(to: node) }
        else { open(node) }
    }

    /// Selects a file from the sidebar, zooming out to its folder if it is not under the current view.
    func focus(_ node: Node) {
        if let cur = current, !node.isDescendant(of: cur), let p = node.parent { zoom(to: p) }
        select(node, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
    }

    // MARK: Selection

    func isSelected(_ node: Node) -> Bool { selection.contains { $0 === node } }

    /// Plain click picks one; extend toggles the node in or out of the selection.
    func select(_ node: Node?, extend: Bool) {
        guard let node else { if !extend { selection = [] }; return }
        if extend {
            if let i = selection.firstIndex(where: { $0 === node }) { selection.remove(at: i) }
            else { selection.append(node) }
        } else {
            selection = [node]
        }
    }

    /// The selection without items already inside another selected folder (so sizes aren't counted twice).
    var effectiveSelection: [Node] {
        selection.filter { n in !selection.contains { $0 !== n && n.isDescendant(of: $0) } }
    }

    var selectionSize: Int64 { effectiveSelection.reduce(0) { $0 + $1.size } }

    func hover(_ node: Node?, smallBox: Box?) {
        if let b = smallBox, b.kind == .small {
            hover.title = "\(b.smallCount) small items"
            hover.detail = "\(formatBytes(b.smallSize)) · double-click to zoom into \(b.smallParent?.name ?? "folder")"
        } else if let n = node {
            hover.title = n.name
            let kind = n.isDir ? "\(n.fileCount.formatted()) files" : FileKind.of(n).rawValue
            hover.detail = "\(formatBytes(n.size)) · \(kind) · modified \(formatDate(n.modified)) · \(n.path)"
        } else {
            hover.title = ""; hover.detail = ""
        }
    }

    // MARK: File actions

    func open(_ node: Node) { NSWorkspace.shared.open(node.url) }

    func reveal(_ node: Node) { reveal([node]) }
    func reveal(_ nodes: [Node]) { NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url)) }

    func trash(_ node: Node) { trash([node]) }

    func trash(_ nodes: [Node]) {
        let items = nodes.filter { n in n.parent != nil && !nodes.contains { $0 !== n && n.isDescendant(of: $0) } }
        guard !items.isEmpty else { return }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let alert = NSAlert()
        if items.count == 1, let node = items.first {
            alert.messageText = "Move “\(node.name)” to the Trash?"
            alert.informativeText = "\(formatBytes(node.size))\(node.isDir ? " · \(node.fileCount.formatted()) files" : "")\n\(node.path)"
        } else {
            alert.messageText = "Move \(items.count) items to the Trash?"
            let names = items.prefix(8).map { "• " + $0.name }.joined(separator: "\n")
            alert.informativeText = "\(formatBytes(total)) in total\n\n\(names)\(items.count > 8 ? "\n… and \(items.count - 8) more" : "")"
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed: [String] = []
        for node in items {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            } catch {
                failed.append(node.name); continue
            }
            if let cur = current, cur.isDescendant(of: node) { current = node.parent }
            node.detach()
            selection.removeAll { $0 === node || $0.isDescendant(of: node) }
        }
        if !failed.isEmpty { errorText = "Couldn't move to Trash: \(failed.joined(separator: ", "))" }
        if let root { topFiles = largestFiles(in: root) }
        version += 1
    }

    /// Right-click: act on the whole selection if the clicked box is part of it, otherwise just that box.
    func contextMenu(for node: Node) -> NSMenu {
        if !isSelected(node) { selection = [node] }
        return menu(for: effectiveSelection.isEmpty ? [node] : effectiveSelection)
    }

    func menu(for nodes: [Node]) -> NSMenu {
        let m = NSMenu()
        if nodes.count > 1 {
            let header = NSMenuItem(title: "\(nodes.count) items · \(formatBytes(nodes.reduce(0) { $0 + $1.size }))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            m.addItem(header)
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Open All") { [weak self] in nodes.forEach { self?.open($0) } })
            m.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.reveal(nodes) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Move \(nodes.count) Items to Trash…") { [weak self] in self?.trash(nodes) })
            return m
        }
        guard let node = nodes.first else { return m }
        if node.isDir && !node.children.isEmpty {
            m.addItem(ClosureMenuItem("Zoom In") { [weak self] in self?.zoom(to: node) })
        }
        m.addItem(ClosureMenuItem("Open") { [weak self] in self?.open(node) })
        m.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.reveal(node) })
        m.addItem(.separator())
        let t = ClosureMenuItem("Move to Trash…") { [weak self] in self?.trash(node) }
        t.isEnabled = node.parent != nil
        m.addItem(t)
        return m
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
