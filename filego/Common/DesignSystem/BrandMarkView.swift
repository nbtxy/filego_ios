import UIKit

/// FileGo 品牌标。对齐网页 `.brand-mark`：一个微微左倾的墨绿圆角块，
/// 顶上探出一小截（文件夹的「舌」），中间是柠檬绿的 ↗。
@MainActor
final class BrandMarkView: UIView {
    private let body = UIView()
    private let tab = UIView()
    private let arrow = UILabel()
    private let scale: CGFloat

    /// - Parameter side: 主体宽度。网页是 35×30，这里按同比例放大。
    init(side: CGFloat = 35) {
        self.scale = side / 35
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // 「舌」要在主体下面，否则圆角处会露出直角。
        tab.backgroundColor = AppColor.ink
        tab.layer.cornerRadius = 5 * scale
        tab.layer.cornerCurve = .continuous
        tab.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tab.translatesAutoresizingMaskIntoConstraints = false

        body.backgroundColor = AppColor.ink
        body.layer.cornerRadius = 8 * scale
        body.layer.cornerCurve = .continuous
        body.translatesAutoresizingMaskIntoConstraints = false

        arrow.text = "↗"
        arrow.textColor = AppColor.lime
        arrow.font = .systemFont(ofSize: 19 * scale, weight: .medium)
        arrow.textAlignment = .center
        arrow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tab)
        addSubview(body)
        body.addSubview(arrow)

        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 35 * scale),
            body.heightAnchor.constraint(equalToConstant: 30 * scale),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),

            tab.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 3 * scale),
            tab.widthAnchor.constraint(equalToConstant: 16 * scale),
            tab.heightAnchor.constraint(equalToConstant: 9 * scale),
            tab.topAnchor.constraint(equalTo: topAnchor),
            tab.bottomAnchor.constraint(equalTo: body.topAnchor, constant: 4 * scale),

            arrow.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: body.centerYAnchor)
        ])

        // 网页是整块 -3deg，里面的箭头再 +3deg 转回来。
        transform = CGAffineTransform(rotationAngle: -3 * .pi / 180)
        arrow.transform = CGAffineTransform(rotationAngle: 3 * .pi / 180)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
