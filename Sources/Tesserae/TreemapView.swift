import AppKit
import SwiftUI

/// One drawn box.
struct Box {
    enum Kind { case file, folder, small }
    let node: Node?          // nil for a "small items" group
    let rect: CGRect
    let depth: Int
    let kind: Kind
    var smallCount = 0
    var smallSize: Int64 = 0
    var smallParent: Node?   // folder that owns a "small items" group
}

// MARK: - Squarified layout

enum TreemapLayout {
    static let header: CGFloat = 17
    static let pad: CGFloat = 2
    static let minSide: CGFloat = 6
    static let maxDepth = 8

    static func layout(root: Node, in bounds: CGRect, expandPackages: Bool, sort: SortKey = .size, reversed: Bool = false) -> [Box] {
        var out: [Box] = []
        out.reserveCapacity(4096)
        place(children: root, in: bounds.insetBy(dx: pad, dy: pad), depth: 0, expandPackages: expandPackages, sort: sort, reversed: reversed, out: &out)
        return out
    }

    private static func place(children parent: Node, in rect: CGRect, depth: Int, expandPackages: Bool, sort: SortKey, reversed: Bool, out: inout [Box]) {
        guard rect.width >= 1, rect.height >= 1, parent.size > 0 else { return }
        let area = Double(rect.width * rect.height)
        let scale = area / Double(parent.size)
        let minArea = Double(minSide * minSide) * 2

        // Big items get their own box; the tail is grouped into one "small items" box (always last).
        var big: [Node] = []
        var smallArea = 0.0, smallCount = 0
        var smallSize: Int64 = 0
        for c in parent.children where c.size > 0 {
            let a = Double(c.size) * scale
            if a >= minArea { big.append(c) }
            else { smallArea += a; smallCount += 1; smallSize += c.size }
        }
        var items: [(Node?, Double)] = sort.sorted(big, reversed: reversed).map { ($0, Double($0.size) * scale) }
        if smallCount > 0 { items.append((nil, smallArea)) }

        for (node, r) in squarify(items, in: rect) {
            guard let node else {
                var b = Box(node: nil, rect: r, depth: depth, kind: .small)
                b.smallCount = smallCount; b.smallSize = smallSize; b.smallParent = parent
                out.append(b)
                continue
            }
            let expandable = node.isDir && (!node.isPackage || expandPackages) && !node.children.isEmpty
            out.append(Box(node: node, rect: r, depth: depth, kind: node.isDir ? .folder : .file))
            if expandable && depth < maxDepth && r.width > 28 && r.height > header + 14 {
                let inner = CGRect(x: r.minX + pad, y: r.minY + header, width: r.width - pad * 2, height: r.height - header - pad)
                place(children: node, in: inner, depth: depth + 1, expandPackages: expandPackages, sort: sort, reversed: reversed, out: &out)
            }
        }
    }

    /// Classic squarified treemap. Values must already be areas summing to rect's area.
    static func squarify<T>(_ items: [(T, Double)], in bounds: CGRect) -> [(T, CGRect)] {
        var result: [(T, CGRect)] = []
        var rect = bounds
        var i = 0
        func worst(_ sum: Double, _ rmin: Double, _ rmax: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * rmax / s2, s2 / (w2 * rmin))
        }
        while i < items.count {
            if rect.width < 0.5 || rect.height < 0.5 { break }
            let side = Double(min(rect.width, rect.height))
            var sum = items[i].1, rmin = sum, rmax = sum
            var j = i + 1
            var cur = worst(sum, rmin, rmax, side)
            while j < items.count {
                let v = items[j].1
                let n = worst(sum + v, min(rmin, v), max(rmax, v), side)
                if n > cur { break }
                sum += v; rmin = min(rmin, v); rmax = max(rmax, v); cur = n; j += 1
            }
            if rect.width >= rect.height {
                // Column on the left.
                let w = CGFloat(sum / Double(rect.height))
                var y = rect.minY
                for k in i..<j {
                    let h = CGFloat(items[k].1) / w
                    result.append((items[k].0, CGRect(x: rect.minX, y: y, width: w, height: h)))
                    y += h
                }
                rect = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            } else {
                // Row along the top.
                let h = CGFloat(sum / Double(rect.width))
                var x = rect.minX
                for k in i..<j {
                    let w = CGFloat(items[k].1) / h
                    result.append((items[k].0, CGRect(x: x, y: rect.minY, width: w, height: h)))
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            }
            i = j
        }
        return result
    }
}

// MARK: - AppKit view

final class TreemapNSView: NSView {
    var root: Node? { didSet { if root !== oldValue { invalidateLayout() } } }
    var version = 0 { didSet { if version != oldValue { invalidateLayout() } } }
    var expandPackages = false { didSet { if expandPackages != oldValue { invalidateLayout() } } }
    var sort: SortKey = .size { didSet { if sort != oldValue { invalidateLayout() } } }
    var reversed = false { didSet { if reversed != oldValue { invalidateLayout() } } }
    var selection: [Node] = [] {
        didSet {
            guard selection.count != oldValue.count || !zip(selection, oldValue).allSatisfy({ $0 === $1 }) else { return }
            // Redraw only the boxes whose selection changed, not the whole map.
            for n in oldValue + selection {
                if let i = boxIndex[ObjectIdentifier(n)] { setNeedsDisplay(boxes[i].rect.insetBy(dx: -2, dy: -2)) }
            }
        }
    }

    var onHover: ((Node?, Box?) -> Void)?
    var onSelect: ((Node?, Bool) -> Void)?
    var onClearSelection: (() -> Void)?
    var onDoubleClick: ((Node) -> Void)?
    var onZoomSmall: ((Node) -> Void)?
    var menuBuilder: ((Node) -> NSMenu?)?

    private var boxes: [Box] = []
    private var boxIndex: [ObjectIdentifier: Int] = [:]
    private var layoutSize: CGSize = .zero
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func invalidateLayout() { layoutSize = .zero; hoveredIndex = nil; needsDisplay = true }

    private func ensureLayout() {
        guard layoutSize != bounds.size else { return }
        layoutSize = bounds.size
        if let root { boxes = TreemapLayout.layout(root: root, in: bounds, expandPackages: expandPackages, sort: sort, reversed: reversed) }
        else { boxes = [] }
        boxIndex.removeAll(keepingCapacity: true)
        for (i, b) in boxes.enumerated() { if let n = b.node { boxIndex[ObjectIdentifier(n)] = i } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Drawing

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let subFont = NSFont.systemFont(ofSize: 10)
    private static let para: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
    }()

    override func draw(_ dirtyRect: NSRect) {
        ensureLayout()
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
        bounds.fill()
        guard !boxes.isEmpty else { return }

        let border = NSColor(white: 0, alpha: 0.55)
        for b in boxes where b.rect.intersects(dirtyRect) {
            let r = b.rect
            switch b.kind {
            case .folder:
                let shade = 0.17 + min(CGFloat(b.depth), 6) * 0.025
                NSColor(srgbRed: shade, green: shade + 0.01, blue: shade + 0.03, alpha: 1).setFill()
                r.fill()
                if let n = b.node, n.isPackage, !expandPackages {
                    FileKind.app.color.withAlphaComponent(0.85).setFill(); r.insetBy(dx: 1, dy: 1).fill()
                }
            case .file:
                let base = FileKind.of(b.node!).color
                base.setFill(); r.fill()
                // Soft top highlight so boxes read as tiles.
                NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 0, alpha: 0.12))?
                    .draw(in: r, angle: 90)
            case .small:
                NSColor(white: 0.28, alpha: 1).setFill(); r.fill()
            }
            border.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
            drawLabel(for: b)
        }

        if !selection.isEmpty {
            let ids = Set(selection.map(ObjectIdentifier.init))
            for b in boxes where b.rect.intersects(dirtyRect) {
                guard let n = b.node, ids.contains(ObjectIdentifier(n)) else { continue }
                NSColor(white: 1, alpha: 0.18).setFill(); b.rect.fill(using: .sourceOver)
                NSColor.white.setStroke()
                let p = NSBezierPath(rect: b.rect.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
            }
        }
        if let h = hoveredIndex, h < boxes.count {
            NSColor(white: 1, alpha: 0.85).setStroke()
            let p = NSBezierPath(rect: boxes[h].rect.insetBy(dx: 1.5, dy: 1.5)); p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }
    }

    private func drawLabel(for b: Box) {
        let r = b.rect
        guard r.width > 34, r.height > 14 else { return }
        let main: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor(white: 1, alpha: 0.95), .paragraphStyle: Self.para]
        let sub: [NSAttributedString.Key: Any] = [.font: Self.subFont, .foregroundColor: NSColor(white: 1, alpha: 0.7), .paragraphStyle: Self.para]
        let textW = r.width - 8
        switch b.kind {
        case .folder:
            let n = b.node!
            let s = NSMutableAttributedString(string: n.name, attributes: main)
            s.append(NSAttributedString(string: "  " + formatBytes(n.size), attributes: sub))
            s.draw(with: CGRect(x: r.minX + 4, y: r.minY + 2, width: textW, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .file:
            guard r.height > 16 else { return }
            let n = b.node!
            (n.name as NSString).draw(with: CGRect(x: r.minX + 4, y: r.minY + 3, width: textW, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: main)
            if r.height > 32 {
                (formatBytes(n.size) as NSString).draw(with: CGRect(x: r.minX + 4, y: r.minY + 17, width: textW, height: 13), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: sub)
            }
        case .small:
            guard r.height > 16 else { return }
            ("\(b.smallCount) small items" as NSString).draw(with: CGRect(x: r.minX + 4, y: r.minY + 3, width: textW, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: sub)
        }
    }

    // MARK: Mouse

    /// Deepest box under the point.
    private func hitIndex(_ p: CGPoint) -> Int? {
        ensureLayout()
        var best: Int?
        for (i, b) in boxes.enumerated() where b.rect.contains(p) {
            if best == nil || b.depth >= boxes[best!].depth { best = i }
        }
        return best
    }

    private func setHover(_ i: Int?) {
        guard i != hoveredIndex else { return }
        if let old = hoveredIndex, old < boxes.count { setNeedsDisplay(boxes[old].rect.insetBy(dx: -2, dy: -2)) }
        hoveredIndex = i
        if let i { setNeedsDisplay(boxes[i].rect.insetBy(dx: -2, dy: -2)) }
        let box = i.map { boxes[$0] }
        onHover?(box?.node ?? box?.smallParent, box)
    }

    override func mouseMoved(with e: NSEvent) { setHover(hitIndex(convert(e.locationInWindow, from: nil))) }
    override func mouseExited(with e: NSEvent) { setHover(nil) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let extend = e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command)
        guard let i = hitIndex(convert(e.locationInWindow, from: nil)) else { onSelect?(nil, extend); return }
        let b = boxes[i]
        if e.clickCount >= 2 {
            if let n = b.node { onDoubleClick?(n) }
            else if let p = b.smallParent { onZoomSmall?(p) }
        } else {
            onSelect?(b.node, extend)
        }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        guard let i = hitIndex(convert(e.locationInWindow, from: nil)), let n = boxes[i].node else { return nil }
        return menuBuilder?(n)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onClearSelection?() } else { super.keyDown(with: e) }   // Esc
    }
}

struct TreemapView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        v.onHover = { node, box in model.hover(node, smallBox: box) }
        v.onSelect = { model.select($0, extend: $1) }
        v.onClearSelection = { model.selection = [] }
        v.onDoubleClick = { model.activate($0) }
        v.onZoomSmall = { model.zoom(to: $0) }
        v.menuBuilder = { model.contextMenu(for: $0) }
        return v
    }

    func updateNSView(_ v: TreemapNSView, context: Context) {
        v.expandPackages = model.showHidden
        v.sort = model.mapSort
        v.reversed = model.mapReversed
        v.root = model.current
        v.version = model.version
        v.selection = model.selection
    }
}
