import UIKit

/// 按文件类型分发到对应的预览控制器。
///
/// 目前只有 Markdown 有专用渲染器，其余一律走 QuickLook 兜底。
/// 后续要接 image / video / PDF 专用预览时，在这里加分支即可，调用方不用动。
enum PreviewCoordinator {
    static func makeViewController(for node: DriveNode, file: PreviewTemporaryFile) -> UIViewController {
        switch FileKind(node: node) {
        case .markdown:
            return MarkdownPreviewController(file: file, title: node.name)
        default:
            return FilePreviewController(file: file)
        }
    }
}
