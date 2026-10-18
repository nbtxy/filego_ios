import UIKit

/// 轻拟物材质。只有 iOS 有，网页仍是扁平的（见 `DesignSystem.swift` 顶部）。
///
/// 三种面：
/// - **凸起**（`.paper` / `.ink` / `.danger`）：上浅下深的渐变 + 顶边 1px 内高光 +
///   两层阴影（墨绿长投影 + 贴地的接触阴影）。卡片、按钮、Toast。
/// - **凹槽**（`.well`）：暖灰底 + 顶部内阴影 + 底边 1px 白色反光。输入框、进度条轨道。
/// - **压印**：见 `FileIconTile`，色块上叠一层顶光。
///
/// 一律画在一张垫在最底下的 `MaterialView` 上，而不是直接改宿主的 layer：
/// 宿主（cell 的 contentView、`UIButton`、`UITextField`）各有各的 layer 用法，
/// 往上叠 sublayer 迟早和系统的子视图抢层级。
@MainActor
enum AppMaterial {
    /// 把宿主的底色与描边换成一张凸起面，返回垫进去的那张面。
    ///
    /// 宿主**不能** `clipsToBounds`，否则阴影会被裁掉；需要裁切的内容自己再包一层。
    @discardableResult
    static func raise(
        _ host: UIView,
        radius: CGFloat,
        surface: MaterialView.Surface = .paper,
        elevation: MaterialView.Elevation = .card
    ) -> MaterialView {
        let material = MaterialView(surface: surface, elevation: elevation)
        material.cornerRadius = radius
        install(material, in: host)
        return material
    }

    /// 把宿主的底色换成一张凹槽。
    @discardableResult
    static func inset(_ host: UIView, radius: CGFloat) -> MaterialView {
        let material = MaterialView(surface: .well, elevation: .flat)
        material.cornerRadius = radius
        install(material, in: host)
        return material
    }

    private static func install(_ material: MaterialView, in host: UIView) {
        host.backgroundColor = .clear
        host.layer.borderWidth = 0
        host.layer.shadowOpacity = 0
        host.clipsToBounds = false
        material.frame = host.bounds
        material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.insertSubview(material, at: 0)
    }
}

/// 一张材质面。尺寸变化时自己重算渐变、高光与 `shadowPath`。
///
/// `shadowPath` 必须给：没有它，Core Animation 每帧都要按 alpha 现算阴影轮廓，
/// 长列表一滚就掉帧。
@MainActor
final class MaterialView: UIView {
    enum Surface {
        case paper
        case ink
        case danger
        case well

        fileprivate var colors: (top: UIColor, bottom: UIColor) {
            switch self {
            case .paper: return (AppColor.surfaceTop, AppColor.surfaceBottom)
            case .ink: return (AppColor.inkTop, AppColor.inkBottom)
            case .danger: return (AppColor.dangerTop, AppColor.danger)
            case .well: return (AppColor.well, AppColor.well)
            }
        }

        /// 顶边内高光的强度。深色面上要压低，否则像一道划痕。
        fileprivate var highlightAlpha: CGFloat {
            switch self {
            case .paper: return 0.9
            case .ink, .danger: return 0.16
            case .well: return 0
            }
        }

        /// 发丝描边。白卡压在纸色底上需要它勾出轮廓；深色面自己就够清楚。
        fileprivate var border: UIColor? {
            switch self {
            case .paper: return AppColor.line.withAlphaComponent(0.7)
            case .well: return AppColor.line.withAlphaComponent(0.55)
            case .ink, .danger: return nil
            }
        }
    }

    /// 离纸面多高。数值都是墨绿色的低透明度投影，不是黑色——和网页 `--shadow*` 同一个色相。
    enum Elevation {
        /// 凹槽：没有外投影，只有底边反光。
        case flat
        /// 卡片、列表段：`--shadow-sm` 的量级。
        case card
        /// 按钮：投影更近更实，按下时几乎贴地。
        case button
        /// Toast 这类浮在内容上的。
        case floating

        fileprivate var ambient: (offsetY: CGFloat, radius: CGFloat, opacity: Float) {
            switch self {
            case .flat: return (0, 0, 0)
            case .card: return (6, 9, 0.07)
            case .button: return (5, 7, 0.16)
            case .floating: return (12, 16, 0.18)
            }
        }
    }

    var cornerRadius: CGFloat = AppRadius.card {
        didSet { setNeedsLayout() }
    }

    private let surface: Surface
    private let elevation: Elevation
    /// 贴地的那层接触阴影。和外投影分两层，才有「先落地、再晕开」的厚度。
    private let contactLayer = CALayer()
    private let fillLayer = CAGradientLayer()
    private let highlightLayer = CAShapeLayer()
    private let highlightMask = CAGradientLayer()
    private let innerShadowLayer = CAShapeLayer()
    private var isPressed = false

    init(surface: Surface, elevation: Elevation) {
        self.surface = surface
        self.elevation = elevation
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        let colors = surface.colors
        fillLayer.colors = [colors.top.cgColor, colors.bottom.cgColor]
        fillLayer.masksToBounds = true
        fillLayer.cornerCurve = .continuous
        if let border = surface.border {
            fillLayer.borderColor = border.cgColor
            fillLayer.borderWidth = 0.5
        }

        if surface == .well {
            // 凹槽：底边一道白色反光，用一层不模糊的白「阴影」往下错 1pt 来画。
            layer.shadowColor = UIColor.white.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 0
            layer.shadowOpacity = 0.9

            // 顶部内阴影：一圈「外大框减去圆角矩形」的环投下的影子，被 fillLayer 的
            // 圆角裁剩下的那部分就是凹进去的阴影。环本身**不填色**、只给 `shadowPath`：
            // 填了色的话，它和 fillLayer 的圆角裁切对不严，边上会漏出一道墨色。
            innerShadowLayer.fillColor = UIColor.clear.cgColor
            innerShadowLayer.shadowColor = AppColor.ink.cgColor
            innerShadowLayer.shadowOffset = CGSize(width: 0, height: 1.5)
            innerShadowLayer.shadowRadius = 2
            innerShadowLayer.shadowOpacity = 0.12
            layer.addSublayer(fillLayer)
            fillLayer.addSublayer(innerShadowLayer)
            return
        }

        contactLayer.backgroundColor = colors.bottom.cgColor
        contactLayer.cornerCurve = .continuous
        contactLayer.shadowColor = AppColor.ink.cgColor
        contactLayer.shadowOffset = CGSize(width: 0, height: 1)
        contactLayer.shadowRadius = 1.5
        contactLayer.shadowOpacity = surface == .paper ? 0.1 : 0.28

        let ambient = elevation.ambient
        layer.shadowColor = AppColor.ink.cgColor
        layer.shadowOffset = CGSize(width: 0, height: ambient.offsetY)
        layer.shadowRadius = ambient.radius
        layer.shadowOpacity = ambient.opacity

        highlightLayer.fillColor = UIColor.clear.cgColor
        highlightLayer.strokeColor = UIColor(white: 1, alpha: surface.highlightAlpha).cgColor
        highlightLayer.lineWidth = 1
        // 高光只留在顶边，往下很快淡掉——两侧整圈都亮就成了描边。
        highlightMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        highlightMask.locations = [0, 0.35]
        highlightLayer.mask = highlightMask

        layer.addSublayer(contactLayer)
        layer.addSublayer(fillLayer)
        layer.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按下：外投影收拢到贴地，整面往下沉 1pt。
    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed, surface != .well else { return }
        isPressed = pressed
        let ambient = elevation.ambient
        let offset = pressed ? ambient.offsetY * 0.3 : ambient.offsetY
        let radius = pressed ? ambient.radius * 0.4 : ambient.radius
        let opacity = pressed ? ambient.opacity * 0.6 : ambient.opacity
        let duration = pressed ? 0.08 : 0.18

        let animations: [(String, Any)] = [
            ("shadowOffset", CGSize(width: 0, height: offset)),
            ("shadowRadius", radius),
            ("shadowOpacity", opacity)
        ]
        for (key, value) in animations {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = value
            animation.duration = duration
            layer.add(animation, forKey: key)
        }
        layer.shadowOffset = CGSize(width: 0, height: offset)
        layer.shadowRadius = radius
        layer.shadowOpacity = opacity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let rect = bounds
        // 写死的半径（尤其是胶囊的 999）一旦超过高度的一半，continuous 圆角路径就
        // 构造不出来，图层什么都不画。所以按实际尺寸夹一下。
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        layer.shadowPath = path

        fillLayer.frame = rect
        fillLayer.cornerRadius = radius

        if surface == .well {
            // shadowPath 只认 non-zero 规则，内圈反向绕一遍才是一个环。
            let ring = UIBezierPath(rect: rect.insetBy(dx: -8, dy: -8))
            ring.append(UIBezierPath(roundedRect: rect, cornerRadius: radius).reversing())
            innerShadowLayer.frame = rect
            innerShadowLayer.shadowPath = ring.cgPath
            return
        }

        contactLayer.frame = rect
        contactLayer.cornerRadius = radius
        contactLayer.shadowPath = path

        highlightLayer.frame = rect
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        highlightLayer.path = UIBezierPath(
            roundedRect: inset, cornerRadius: max(radius - 0.5, 0)
        ).cgPath
        highlightMask.frame = rect
    }
}

/// 垫着一张凸起面的按钮。`PaperButton` 的几个工厂都产出它。
///
/// 底色交给 `MaterialView`，`UIButton.Configuration` 只管文字、图标与内边距——
/// Dynamic Type、禁用态、菜单这些仍是系统那一套。
@MainActor
final class MaterialButton: UIButton {
    let material: MaterialView?

    var cornerRadius: CGFloat {
        get { material?.cornerRadius ?? 0 }
        set { material?.cornerRadius = newValue }
    }

    init(surface: MaterialView.Surface?) {
        material = surface.map { MaterialView(surface: $0, elevation: .button) }
        super.init(frame: .zero)
        if let material {
            material.cornerRadius = AppRadius.control
            insertSubview(material, at: 0)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let material else { return }
        material.frame = bounds
        // `UIButton` 会在布局时补插自己的子视图，每次都把材质压回最底下。
        sendSubviewToBack(material)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, let material else { return }
            material.setPressed(isHighlighted)
            if isHighlighted { HapticManager.impact(.light) }
            UIView.animate(
                withDuration: isHighlighted ? 0.08 : 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(translationX: 0, y: 1)
                    : .identity
            }
        }
    }
}

/// 凹槽输入框。替代 `.roundedRect`：系统那种是冷灰描边的白框，压在纸色底上发蓝。
///
/// 内边距放在 `textRect` / `editingRect` 里而不是 `leftView`：`InboxPathField` 要用
/// `leftView` 钉地址前缀，两者不能抢同一个位置。`placeholderRect` 不要再缩一次——
/// 系统的实现本来就从 `textRect` 推出来，再缩就是双倍内边距。
@MainActor
final class PaperTextField: UITextField {
    private let padding = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        font = AppTypography.body
        textColor = AppColor.ink
        tintColor = AppColor.ink
        AppMaterial.inset(self, radius: AppRadius.control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width, height: max(size.height + 18, 44))
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: padding))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds.inset(by: padding))
    }

    override func leftViewRect(forBounds bounds: CGRect) -> CGRect {
        super.leftViewRect(forBounds: bounds).offsetBy(dx: padding.left, dy: 0)
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        super.clearButtonRect(forBounds: bounds).offsetBy(dx: -padding.right / 2, dy: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let material = subviews.first(where: { $0 is MaterialView }) {
            sendSubviewToBack(material)
        }
    }
}

/// 列表段背景的布局：在系统 `insetGrouped` 列表外面，给每段垫一张凸起的白卡。
///
/// `UIBackgroundConfiguration` 画不了渐变和阴影，逐个 cell 加阴影又会在行与行之间
/// 叠出接缝，所以 cell 自己透明，整段共用一张 decoration。
///
/// decoration 默认铺满整个 section——连 header 一起盖住，空段还会剩一条扁药丸。
/// 这里把它收到「首行到末行」的并集，空段直接隐藏。
@MainActor
final class PaperInsetGroupedLayout: UICollectionViewCompositionalLayout {
    static func make(_ configuration: UICollectionLayoutListConfiguration) -> PaperInsetGroupedLayout {
        var configuration = configuration
        // 行间分隔线仍由系统画，但白卡的描边已经勾出了轮廓，段首段尾不需要再来一条。
        configuration.backgroundColor = .clear
        let layout = PaperInsetGroupedLayout { _, environment in
            let section = NSCollectionLayoutSection.list(
                using: configuration, layoutEnvironment: environment
            )
            section.decorationItems = [
                .background(elementKind: PaperSectionBackgroundView.elementKind)
            ]
            return section
        }
        layout.register(
            PaperSectionBackgroundView.self,
            forDecorationViewOfKind: PaperSectionBackgroundView.elementKind
        )
        return layout
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        super.layoutAttributesForElements(in: rect)?.map(fitted)
    }

    override func layoutAttributesForDecorationView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        super.layoutAttributesForDecorationView(ofKind: elementKind, at: indexPath).map(fitted)
    }

    private func fitted(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        guard attributes.representedElementCategory == .decorationView,
              attributes.representedElementKind == PaperSectionBackgroundView.elementKind,
              let copy = attributes.copy() as? UICollectionViewLayoutAttributes
        else { return attributes }
        let section = attributes.indexPath.section
        guard let collectionView,
              section < collectionView.numberOfSections,
              case let count = collectionView.numberOfItems(inSection: section), count > 0,
              let first = layoutAttributesForItem(at: IndexPath(item: 0, section: section)),
              let last = layoutAttributesForItem(at: IndexPath(item: count - 1, section: section))
        else {
            copy.isHidden = true
            return copy
        }
        copy.frame = first.frame.union(last.frame)
        return copy
    }
}
