import UIKit

/**
 下载链接路径（`ryan.stolnk.com/~code`）输入框的配置。建链接（`NewShareViewController`）
 和改路径（`ShareDetailViewController`）问的是同一个东西，输入规矩也就必须一样。

 收件地址已经没有路径了（每台设备只有一个 `<name>.stolnk.com`），这里只剩下载链接在用。
 */
enum SharePathField {
    /**
     把一个文本框配成路径输入框。

     `prefix` 是 `ryan.stolnk.com/` 这截，钉在 `leftView` 里而不是预填进正文：
     它是读的不是填的，放进 `text` 用户就能把它删掉，而那正是这个弹窗唯一能讲清楚
     「你在填的是一条 URL 的后半段」的东西。

     键盘一律关掉首字母大写、自动更正和拼写检查：路径只收小写字母、数字和连字符
     （`ShareCodeRules`），这三样功能在这里只会制造非法输入。
     */
    static func configure(
        _ field: UITextField, prefix: String?, text: String?, placeholder: String
    ) {
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.keyboardType = .URL
        field.text = text

        guard let prefix else { return }
        let label = UILabel()
        label.text = prefix
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = AppColor.textSecondary
        label.sizeToFit()
        field.leftView = label
        field.leftViewMode = .always
    }
}
