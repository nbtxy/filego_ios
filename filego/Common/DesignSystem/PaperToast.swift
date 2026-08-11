import UIKit

/// 一次性反馈的浮层提示。对齐网页 `.toast`：墨绿胶囊、白字、居中偏下、自己消失。
///
/// 之前 `DriveListViewController` 与 `AccountDetailViewController` 各写了一份
/// 几乎逐行相同的毛玻璃版本，现在统一走这里。
@MainActor
enum PaperToast {
    /// 只用来找到并替换上一条提示。取值随意，只要不和别处的 tag 撞车。
    private static let tag = 0x504F5354

    /// 复制成功这类反馈不值得弹 alert，浮一条自己消失的就够。
    static func show(_ message: String, in view: UIView, isError: Bool = false) {
        view.viewWithTag(tag)?.removeFromSuperview()

        let container = UIView()
        container.tag = tag
        container.backgroundColor = isError ? AppColor.danger : AppColor.ink
        container.layer.cornerRadius = 21
        container.layer.cornerCurve = .continuous
        container.alpha = 0
        // 提示只是路过，别挡住底下的点击。
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false
        AppShadow.small(container)

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AppColor.white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            container.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            container.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -AppSpacing.large
            ),
            container.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: AppSpacing.large
            )
        ])

        // 网页的 `rise` 动画：从下方 10px 淡入。
        container.transform = CGAffineTransform(translationX: 0, y: 10)
        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
            container.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: isError ? 3.6 : 1.6) {
            container.alpha = 0
        } completion: { _ in
            container.removeFromSuperview()
        }
    }
}
