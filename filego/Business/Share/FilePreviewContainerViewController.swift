import QuickLook
import UIKit

/**
 给 QuickLook 预览套一层自己的导航栏，好挂上「创建下载链接」。

 为什么要这一层：Markdown 和 HTML 是自实现的控制器，各自已经有一个 `ellipsis.circle`
 菜单，加一项就行；其余所有类型（图片、PDF、视频、压缩包……）走的是
 `QLPreviewController`，而它的工具栏归 QuickLook 自己管，系统没有给出插入菜单项的
 口子。直接 push 一个 `QLPreviewController` 时它会接管 `navigationItem`；把它降级成
 **child**，导航栏就还是我们的。

 代价是 QuickLook 自带的分享和**标注**按钮消失了。所以菜单里补了两项：「分享原文件」
 顶替前者，「在 QuickLook 中打开」把一个完整 chrome 的预览模态弹出来，标注在那里照常
 可用。后者不是新发明——`HtmlPreviewController` 早就有同名的一项，出于同样的理由。
 */
@MainActor
final class FilePreviewContainerViewController: UIViewController {
    private let file: PreviewTemporaryFile
    private let onCreateShareLink: (UIViewController) -> Void

    init(
        file: PreviewTemporaryFile,
        title: String,
        onCreateShareLink: @escaping (UIViewController) -> Void
    ) {
        self.file = file
        self.onCreateShareLink = onCreateShareLink
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        embedPreview()
        buildMenu()
    }

    private func embedPreview() {
        let preview = FilePreviewController(file: file)
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.topAnchor.constraint(equalTo: view.topAnchor),
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        preview.didMove(toParent: self)
    }

    private func buildMenu() {
        let createLink = UIAction(
            title: R.Strings.previewCreateShareLink.localizedString(),
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            guard let self else { return }
            onCreateShareLink(self)
        }
        let shareFile = UIAction(
            title: R.Strings.previewShareOriginalFile.localizedString(),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in self?.presentShareSheet() }
        let quickLook = UIAction(
            title: R.Strings.previewOpenInQuickLook.localizedString(),
            image: UIImage(systemName: "eye")
        ) { [weak self] _ in self?.openInQuickLook() }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [createLink, shareFile, quickLook]))
    }

    private func presentShareSheet() {
        let controller = UIActivityViewController(
            activityItems: [file.url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    /// 模态弹出，而不是复用 child：QuickLook 的整套 chrome（含标注）只有在它自己
    /// 管导航的时候才在。
    private func openInQuickLook() {
        present(FilePreviewController(file: file), animated: true)
    }
}
