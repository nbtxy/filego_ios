import Foundation

/// `nonisolated`：`NSLocalizedString` / `String(format:)` 本身线程安全，
/// 而后台线程也要取文案（比如 Task.detached 里抛出的错误的 errorDescription）。
/// 本 target 开了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，不写就绑主线程了。
nonisolated extension String {
    /// 与 R.Strings 生成的资源键搭配使用。
    func localizedString() -> String {
        NSLocalizedString(self, bundle: .main, comment: "")
    }

    func formatted(_ arguments: CVarArg...) -> String {
        String(format: localizedString(), arguments: arguments)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
