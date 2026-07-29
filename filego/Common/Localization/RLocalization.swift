import Foundation

extension String {
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
