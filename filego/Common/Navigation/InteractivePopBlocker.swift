import Foundation

/// 页面存在未保存内容时，可临时关闭系统侧滑返回。
@MainActor
final class InteractivePopBlocker {
    static let shared = InteractivePopBlocker()
    private init() {}

    var isBlocked = false
}
