import UIKit

/// 按文件类型分发到对应的预览控制器。
///
/// Markdown、HTML 与 AVPlayer 能播的视频有专用控制器，其余一律走 QuickLook 兜底。
/// 后续要接 image / PDF 专用预览时，在这里加分支即可，调用方不用动。
///
/// 三条分支都挂上「创建下载链接」，入口才是一致的。QuickLook 那条没法直接挂——
/// 工具栏是它自己的——所以套了一层 `FilePreviewContainerViewController`，理由写在
/// 那个类的注释里。
enum PreviewCoordinator {
    private static let playableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    @MainActor
    static func makeViewController(
        for node: DriveNode,
        file: PreviewTemporaryFile,
        environment: AppEnvironment
    ) -> UIViewController {
        // 捕获成一个闭包：预览控制器不认识 AppEnvironment，也不该为了一个菜单项
        // 去认识它。校验和表单都在 ShareLauncher 里，和 Drive 长按菜单是同一条路。
        let createShareLink: (UIViewController) -> Void = { presenter in
            ShareLauncher.start(
                from: presenter,
                environment: environment,
                file: file.url,
                filename: node.name,
                size: node.size)
        }

        switch FileKind(node: node) {
        case .markdown:
            let controller = MarkdownPreviewController(file: file, title: node.name)
            controller.onCreateShareLink = createShareLink
            return controller
        case .html:
            let controller = HtmlPreviewController(file: file, title: node.name)
            controller.onCreateShareLink = createShareLink
            return controller
        // 只接 AVPlayer 播得了的容器。`FileKind.video` 里的 avi / mkv 它打不开，
        // 那两种继续走 QuickLook，行为和以前一样。
        case .video where playableVideoExtensions.contains(
            URL(fileURLWithPath: node.name).pathExtension.lowercased()):
            return VideoPreviewController(
                file: file, title: node.name, onCreateShareLink: createShareLink)
        default:
            return FilePreviewContainerViewController(
                file: file, title: node.name, onCreateShareLink: createShareLink)
        }
    }
}
