import AppKit

/// File type groups used for box colors and the legend.
enum FileKind: String, CaseIterable {
    case video = "Video", image = "Image", audio = "Audio", code = "Code"
    case document = "Docs", archive = "Archive", app = "App", other = "Other"

    var color: NSColor {
        switch self {
        case .video:    return NSColor(srgbRed: 0.56, green: 0.42, blue: 0.86, alpha: 1)
        case .image:    return NSColor(srgbRed: 0.27, green: 0.68, blue: 0.56, alpha: 1)
        case .audio:    return NSColor(srgbRed: 0.85, green: 0.42, blue: 0.62, alpha: 1)
        case .code:     return NSColor(srgbRed: 0.30, green: 0.55, blue: 0.86, alpha: 1)
        case .document: return NSColor(srgbRed: 0.83, green: 0.70, blue: 0.32, alpha: 1)
        case .archive:  return NSColor(srgbRed: 0.88, green: 0.52, blue: 0.27, alpha: 1)
        case .app:      return NSColor(srgbRed: 0.84, green: 0.33, blue: 0.33, alpha: 1)
        case .other:    return NSColor(srgbRed: 0.50, green: 0.53, blue: 0.58, alpha: 1)
        }
    }

    private static let table: [String: FileKind] = {
        var t: [String: FileKind] = [:]
        func add(_ k: FileKind, _ exts: String) { for e in exts.split(separator: " ") { t[String(e)] = k } }
        add(.video, "mp4 mov m4v mkv avi webm wmv flv mpg mpeg prores mxf braw r3d")
        add(.image, "png jpg jpeg gif heic heif tif tiff bmp webp psd raw cr2 cr3 nef arw dng svg exr hdr tga ico icns ai")
        add(.audio, "mp3 wav aiff aif flac m4a aac ogg opus caf mid midi")
        add(.code, "swift js ts tsx jsx mjs cjs py rb go rs c h cpp hpp m mm java kt cs lua luau json yaml yml toml xml html css scss sh zsh md wasm glsl wgsl metal sql")
        add(.document, "pdf doc docx xls xlsx ppt pptx key pages numbers txt rtf csv epub")
        add(.archive, "zip tar gz tgz bz2 xz 7z rar dmg iso pkg")
        add(.app, "app dylib so framework bundle exe dll")
        return t
    }()

    static func of(_ node: Node) -> FileKind {
        if node.isPackage { return .app }
        let name = node.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        return table[name[name.index(after: dot)...].lowercased()] ?? .other
    }
}
