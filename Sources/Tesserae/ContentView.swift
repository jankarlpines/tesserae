import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    if model.current != nil {
                        TreemapView(model: model)
                    } else if !model.scanning {
                        emptyState
                    }
                    if model.scanning { scanningOverlay }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.root != nil {
                    Divider()
                    LargestFilesList(model: model).frame(width: 270)
                }
            }
            Divider()
            StatusBar(hover: model.hover, error: model.errorText,
                      selectionText: model.selection.count > 1 ? "\(model.selection.count) selected · \(formatBytes(model.selectionSize))" : nil)
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.chooseFolder() } label: { Label("Choose Folder", systemImage: "folder") }
                .keyboardShortcut("o")
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .help("Up one folder (⌘↑)")
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.current?.parent == nil)
            Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan (⌘R)")
                .keyboardShortcut("r")
                .disabled(model.root == nil || model.scanning)

            breadcrumb
            Spacer(minLength: 8)
            SortMenu(title: "Sort boxes", key: $model.mapSort, reversed: $model.mapReversed)
                .help("How boxes are ordered, starting top-left")
            Toggle("Hidden files", isOn: $model.showHidden)
                .toggleStyle(.checkbox)
                .help("Include dotfiles and show what's inside apps and packages")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let cur = model.current, let root = model.root {
                    let chain = cur.ancestors.filter { $0.isDescendant(of: root) }
                    ForEach(Array(chain.enumerated()), id: \.offset) { i, n in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        Button(i == 0 ? (n.url.lastPathComponent.isEmpty ? "/" : n.url.lastPathComponent) : n.name) {
                            model.zoom(to: n)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: n === cur ? .semibold : .regular))
                        .foregroundStyle(n === cur ? .primary : .secondary)
                    }
                    Text(formatBytes(cur.size)).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 6)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.3x3.square").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("See what's taking up space in a folder").font(.title3)
            Button("Choose Folder…") { model.chooseFolder() }.controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    private var scanningOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Scanning… \(model.scannedCount.formatted()) files").monospacedDigit()
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LargestFilesList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Largest files").font(.headline)
                Spacer()
                SortMenu(title: "Sort", key: $model.listSort, reversed: $model.listReversed)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            List(model.sortedTopFiles, selection: $model.listSelection) { n in
                FileRow(node: n, showDate: model.listSort == .date)
            }
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                let items = model.sortedTopFiles.filter { ids.contains(ObjectIdentifier($0)) }
                if !items.isEmpty {
                    Button(items.count > 1 ? "Open All" : "Open") { items.forEach { model.open($0) } }
                    Button("Reveal in Finder") { model.reveal(items) }
                    Divider()
                    Button(items.count > 1 ? "Move \(items.count) Items to Trash…" : "Move to Trash…") { model.trash(items) }
                }
            } primaryAction: { ids in
                // Double-click or Return opens.
                model.sortedTopFiles.filter { ids.contains(ObjectIdentifier($0)) }.forEach { model.open($0) }
            }
            .listStyle(.plain)
        }
    }
}

/// One sidebar row. Kept tiny and free of model lookups so selecting doesn't rebuild much.
struct FileRow: View {
    let node: Node
    let showDate: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: FileKind.of(node).color)).frame(width: 8, height: 8)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(showDate ? shortDate(node.modified) : formatBytes(node.size))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.vertical, 1)
    }
}

struct StatusBar: View {
    @ObservedObject var hover: HoverState
    let error: String?
    let selectionText: String?

    var body: some View {
        HStack(spacing: 10) {
            if let selectionText {
                Text(selectionText).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.3), in: Capsule())
            }
            if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).lineLimit(1)
            } else if hover.title.isEmpty {
                Text("Double-click a folder to zoom in · shift-click to select several · right-click for actions").foregroundStyle(.secondary)
            } else {
                Text(hover.title).fontWeight(.semibold).lineLimit(1)
                Text(hover.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            legend
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(FileKind.allCases, id: \.self) { k in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: k.color)).frame(width: 8, height: 8)
                    Text(k.rawValue).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }
}

/// A compact sort dropdown: pick a key, or flip the order.
struct SortMenu: View {
    let title: String
    @Binding var key: SortKey
    @Binding var reversed: Bool

    var body: some View {
        Menu {
            Picker("Sort by", selection: $key) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(reverseLabel, isOn: $reversed)
        } label: {
            Label("\(title): \(key.rawValue)", systemImage: reversed ? "arrow.up" : "arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
    }

    private var reverseLabel: String {
        switch key {
        case .size: return "Smallest first"
        case .name: return "Z to A"
        case .kind: return "Reverse type order"
        case .date: return "Oldest first"
        }
    }
}

func shortDate(_ t: Double) -> String {
    guard t > 0 else { return "–" }
    return Date(timeIntervalSinceReferenceDate: t).formatted(date: .numeric, time: .omitted)
}
