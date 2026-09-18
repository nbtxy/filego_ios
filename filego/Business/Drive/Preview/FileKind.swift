import Foundation

/// 按扩展名归类文件类型。列表图标与预览分发共用这一张表，避免两处各写一份扩展名清单。
nonisolated enum FileKind {
    case folder
    case markdown
    case html
    case image
    case audio
    case video
    case pdf
    case plainText
    case archive
    case other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdtext":
            self = .markdown
        case "html", "htm", "xhtml", "xht":
            self = .html
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            self = .image
        case "mp3", "m4a", "wav", "aac", "flac":
            self = .audio
        case "mp4", "mov", "m4v", "avi", "mkv":
            self = .video
        case "pdf":
            self = .pdf
        case "txt", "rtf":
            self = .plainText
        case "zip", "rar", "7z", "tar", "gz":
            self = .archive
        default:
            self = .other
        }
    }

    init(fileName: String) {
        self.init(fileExtension: URL(fileURLWithPath: fileName).pathExtension)
    }

    init(node: DriveNode) {
        if node.isFolder {
            self = .folder
        } else {
            self.init(fileName: node.name)
        }
    }

    var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .markdown, .plainText: return "doc.text"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }
}
