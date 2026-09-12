import Foundation

/// 预览用临时文件的生命周期句柄。
///
/// `FileDownloadService` 把文件下到 `tmp/FileGoPreview/<UUID>/<原文件名>`，
/// 每次下载独占一个 UUID 目录。本类被释放时删除整个父目录，
/// 由持有它的预览 VC 决定何时结束——避免临时目录泄漏。
final class PreviewTemporaryFile {
    nonisolated static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileGoPreview", isDirectory: true)

    let url: URL

    /// 释放时是否要删掉 `url` 的父目录。
    ///
    /// 改造前只有一种用法：文件是下载到独占 tmp 目录里的副本，删掉理所当然。
    /// 现在收件盘里的文件就在本机，预览的是原件，而它的父目录是用户的收件文件夹
    /// —— 按老路径走一遍就会把整个文件夹删掉。所以所有权必须是显式的。
    private let ownsDirectory: Bool

    /// 接管一个独占的临时目录。
    init(url: URL) {
        self.url = url
        self.ownsDirectory = true
    }

    private init(url: URL, ownsDirectory: Bool) {
        self.url = url
        self.ownsDirectory = ownsDirectory
    }

    /// 借用一份不归自己管的文件——本地收件盘里的原件。释放时什么都不删。
    static func borrowing(_ url: URL) -> PreviewTemporaryFile {
        PreviewTemporaryFile(url: url, ownsDirectory: false)
    }

    /// 进程被杀（崩溃、Xcode 重装、系统回收）时 `deinit` 不会执行，临时目录会留下来。
    /// 启动时整体清一次：这里的内容从来不需要跨启动存活。
    static func purgeOrphans() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    deinit {
        guard ownsDirectory else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 在还没交给预览 VC 之前（例如任务被取消）提前清理。
    func discard() {
        guard ownsDirectory else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
