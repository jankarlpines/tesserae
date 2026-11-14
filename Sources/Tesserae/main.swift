import AppKit
import SwiftUI

struct TesseraeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Tesserae", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

// `Tesserae --scan <folder>` runs a headless scan and prints timing (used for testing).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
    let url = URL(fileURLWithPath: args[i + 1])
    let start = Date()
    let s = Scanner(showHidden: args.contains("--hidden"))
    let root = s.scan(url)
    let secs = Date().timeIntervalSince(start)
    print("Scanned \(root.fileCount) files, \(formatBytes(root.size)) in \(String(format: "%.2f", secs))s")
    let t0 = Date()
    let boxes = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 1200, height: 700), expandPackages: false)
    print("Layout: \(boxes.count) boxes in \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
    let area = boxes.filter { $0.depth == 0 }.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
    print("Top-level box area: \(Int(area)) of \(Int(1196 * 696))")
    for key in SortKey.allCases {
        for rev in [false, true] {
            let t = Date()
            let bx = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 1200, height: 700), expandPackages: false, sort: key, reversed: rev)
            let a = bx.filter { $0.depth == 0 }.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
            let first = bx.first(where: { $0.depth == 0 })?.node?.name ?? "-"
            print("  sort \(key.rawValue)\(rev ? " (rev)" : ""): \(bx.count) boxes, area \(Int(a)), \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000))ms, top-left: \(first)")
        }
    }
    print("Largest:")
    for n in largestFiles(in: root, limit: 5) { print("  \(formatBytes(n.size))  \(n.path)") }
    exit(0)
}

TesseraeApp.main()
