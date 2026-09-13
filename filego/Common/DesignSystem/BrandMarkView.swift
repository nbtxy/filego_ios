import UIKit

/// JustFling 品牌标。对齐网页 `.brand-mark`：一个微微左倾的墨绿圆角块，
/// 顶上探出一小截（文件夹的「舌」），中间是柠檬绿的 ↗。
///
/// 标本身的几何**只**长在内部的 `container` 上，尺寸由 `side` 一次定死。
/// 早先是把 body 直接钉在 view 的四边上，于是这枚标的形状取决于调用方给
/// 这个 view 多大：塞进 `alignment == .fill` 的竖向 stack 里，view 被拉到整行宽，
/// 标就跟着摊成一条黑杠。图形不该由布局环境决定，所以现在无论外面把 view
/// 撑成什么样，标都是正中那块 `side × side`。
@MainActor
final class BrandMarkView: UIView {
    private let container = UIView()
    private let body = UIView()
    private let tab = UIView()
    private let arrow = UILabel()
    private let scale: CGFloat

    /// - Parameter side: 品牌标的边长。网页的基准是 35（body 35×30 加上探出的 5），
    ///   这里按同比例放大，所以外接盒始终是正方形。
    init(side: CGFloat = 35) {
        self.scale = side / 35
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(container)
        container.addSubview(tab)
        container.addSubview(body)
        body.addSubview(arrow)

        NSLayoutConstraint.activate([
            // 外接盒是正方形：宽 35，高 30 + 探出的 5。
            container.widthAnchor.constraint(equalToConstant: 35 * scale),
            container.heightAnchor.constraint(equalToConstant: 35 * scale),
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),

            body.widthAnchor.constraint(equalToConstant: 35 * scale),
            body.heightAnchor.constraint(equalToConstant: 30 * scale),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tab.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 3 * scale),
            tab.widthAnchor.constraint(equalToConstant: 16 * scale),
            tab.heightAnchor.constraint(equalToConstant: 9 * scale),
            tab.topAnchor.constraint(equalTo: container.topAnchor),

            arrow.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: body.centerYAnchor)
        ])

        // 网页是整块 -3deg，里面的箭头再 +3deg 转回来。转的是 container 而不是
        // 自己：view 的 frame 由外部约束说了算，在它身上叠 transform 会和那些
        // 约束打架。
        container.transform = CGAffineTransform(rotationAngle: -3 * .pi / 180)
        arrow.transform = CGAffineTransform(rotationAngle: 3 * .pi / 180)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 调用方不写尺寸约束时，这枚标自己就有大小；写了也不会把标撑变形。
    override var intrinsicContentSize: CGSize {
        CGSize(width: 35 * scale, height: 35 * scale)
    }
}
