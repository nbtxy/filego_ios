import Foundation

/// 预览用临时文件的生命周期句柄。
///
/// `FileDownloadService` 把文件下到 `tmp/FileGoPreview/<UUID>/<原文件名>`，
/// 每次下载独占一个 UUID 目录。本类被释放时删除整个父目录，
/// 由持有它的预览 VC 决定何时结束——避免临时目录泄漏。
final class PreviewTemporaryFile {
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileGoPreview", isDirectory: true)

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// 进程被杀（崩溃、Xcode 重装、系统回收）时 `deinit` 不会执行，临时目录会留下来。
    /// 启动时整体清一次：这里的内容从来不需要跨启动存活。
    static func purgeOrphans() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 在还没交给预览 VC 之前（例如任务被取消）提前清理。
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
