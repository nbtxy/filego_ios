import QuickLook
import UIKit

final class FilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let file: PreviewTemporaryFile

    init(file: PreviewTemporaryFile) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        file.url as NSURL
    }
}
