import Foundation

/// One file or folder in the scanned tree.
final class Node {
    let name: String
    let isDir: Bool
    let isPackage: Bool
    var size: Int64
    var fileCount: Int
    /// Last modified, seconds since 2001. For folders: the newest thing inside.
    var modified: Double = 0
    /// Sorted largest first.
    var children: [Node]
    weak var parent: Node?

    init(name: String, isDir: Bool, isPackage: Bool = false, size: Int64 = 0, fileCount: Int = 0, children: [Node] = []) {
        self.name = name
        self.isDir = isDir
        self.isPackage = isPackage
        self.size = size
        self.fileCount = fileCount
        self.children = children
    }

    /// The root node's name holds its full path.
    var path: String {
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    var ancestors: [Node] {
        var list: [Node] = []
        var n: Node? = self
        while let cur = n { list.append(cur); n = cur.parent }
        return list.reversed()
    }

    /// Removes this node from its parent and subtracts its size up the chain.
    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var n: Node? = parent
        while let cur = n {
            cur.size -= size
            cur.fileCount -= isDir ? fileCount : 1
            n = cur.parent
        }
        self.parent = nil
    }

    func isDescendant(of other: Node) -> Bool {
        var n: Node? = self
        while let cur = n { if cur === other { return true }; n = cur.parent }
        return false
    }
}

/// Walks one folder in the background. Thread-safe counters for progress.
final class Scanner: @unchecked Sendable {
    let showHidden: Bool
    private let lock = NSLock()
    private var _files = 0
    private var _cancelled = false

    init(showHidden: Bool) { self.showHidden = showHidden }

    var filesScanned: Int { lock.lock(); defer { lock.unlock() }; return _files }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey,
    ]

    func scan(_ url: URL) -> Node {
        let root = scanDir(url, name: url.path, isPackage: false, depth: 0)
        return root
    }

    private func scanDir(_ url: URL, name: String, isPackage: Bool, depth: Int) -> Node {
        let node = Node(name: name, isDir: true, isPackage: isPackage)
        if isCancelled { return node }

        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Scanner.keys, options: opts)
        else { return node }

        var children: [Node] = []
        children.reserveCapacity(entries.count)
        var subdirs: [(URL, Bool)] = []
        var localFiles = 0

        for entry in entries {
            guard let v = try? entry.resourceValues(forKeys: Set(Scanner.keys)) else { continue }
            if v.isSymbolicLink == true {
                // Count the link itself, never follow it.
                let n = Node(name: entry.lastPathComponent, isDir: false, size: Int64(v.fileAllocatedSize ?? 0), fileCount: 1)
                n.modified = v.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                children.append(n)
                localFiles += 1
            } else if v.isDirectory == true {
                subdirs.append((entry, v.isPackage == true))
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
                let n = Node(name: entry.lastPathComponent, isDir: false, size: size, fileCount: 1)
                n.modified = v.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                children.append(n)
                localFiles += 1
            }
        }
        lock.lock(); _files += localFiles; lock.unlock()

        if depth < 2 && subdirs.count > 1 {
            // Scan the top levels in parallel.
            var results = [Node?](repeating: nil, count: subdirs.count)
            let resLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                let (u, pkg) = subdirs[i]
                let child = scanDir(u, name: u.lastPathComponent, isPackage: pkg, depth: depth + 1)
                resLock.lock(); results[i] = child; resLock.unlock()
            }
            children.append(contentsOf: results.compactMap { $0 })
        } else {
            for (u, pkg) in subdirs {
                children.append(scanDir(u, name: u.lastPathComponent, isPackage: pkg, depth: depth + 1))
            }
        }

        var total: Int64 = 0
        var count = 0
        var newest = 0.0
        for c in children {
            c.parent = node
            total += c.size
            count += c.isDir ? c.fileCount : 1
            newest = max(newest, c.modified)
        }
        node.modified = newest
        children.sort { $0.size > $1.size }
        node.children = children
        node.size = total
        node.fileCount = count
        return node
    }
}

/// The largest files under a node, biggest first.
func largestFiles(in root: Node, limit: Int = 50) -> [Node] {
    var top: [Node] = []
    var minSize: Int64 = 0
    var stack: [Node] = [root]
    while let n = stack.popLast() {
        if n.isDir {
            stack.append(contentsOf: n.children)
        } else if top.count < limit || n.size > minSize {
            let idx = top.firstIndex { $0.size < n.size } ?? top.count
            top.insert(n, at: idx)
            if top.count > limit { top.removeLast() }
            minSize = top.last?.size ?? 0
        }
    }
    return top
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// How boxes and the sidebar list are ordered.
enum SortKey: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", kind = "Type", date = "Date Modified"
    var id: String { rawValue }

    /// Strict "comes before" for this key, in its natural direction
    /// (biggest, A to Z, grouped by type, newest first). Ties fall back to size.
    func before(_ a: Node, _ b: Node) -> Bool {
        switch self {
        case .size:
            return a.size > b.size
        case .name:
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.size > b.size : r == .orderedAscending
        case .kind:
            let ka = a.isDir && !a.isPackage ? -1 : FileKind.allCases.firstIndex(of: FileKind.of(a))!
            let kb = b.isDir && !b.isPackage ? -1 : FileKind.allCases.firstIndex(of: FileKind.of(b))!
            return ka == kb ? a.size > b.size : ka < kb
        case .date:
            return a.modified == b.modified ? a.size > b.size : a.modified > b.modified
        }
    }

    func sorted(_ nodes: [Node], reversed: Bool) -> [Node] {
        if self == .size && !reversed { return nodes }   // already biggest first
        return nodes.sorted { reversed ? before($1, $0) : before($0, $1) }
    }
}

func formatDate(_ t: Double) -> String {
    guard t > 0 else { return "unknown" }
    let d = Date(timeIntervalSinceReferenceDate: t)
    return d.formatted(date: .abbreviated, time: .shortened)
}

/// Nodes are identified by object identity (ObjectIdentifier), which is free to compute.
extension Node: Identifiable {}
