import UIKit

/// 文件类型色块。对齐网页 `.file-icon`：一个圆角色块，里面是**大写扩展名文字**
/// （文件夹例外，放 folder 图标）。
///
/// 轻拟物：色块上叠一层顶光渐变 + 0.5pt 白色内缘 + 一层贴地小阴影，像压出来的凸面。
/// 因为要投阴影，色块本身**不裁切**（文字与图标都约束在边界内，用不着）。
///
/// 分类判定复用 `FileKind`，配色对应网页 `app.client.js` 的 `fileClass()`：
/// 图片走 `.photo`、音视频走 `.media`、其余（含无扩展名）走默认的文档色。
@MainActor
final class FileIconTile: UIView {
    enum Size {
        /// `.file-icon`：46pt / 圆角 13 / 11px 文字
        case large
        /// `.file-icon.sm`：38pt / 圆角 11 / 10px 文字
        case small

        var side: CGFloat { self == .large ? 46 : 38 }
        var radius: CGFloat { self == .large ? AppRadius.fileTile : AppRadius.fileTileSmall }
        var labelSize: CGFloat { self == .large ? 11 : 10 }
        var glyphSize: CGFloat { self == .large ? 22 : 18 }
    }

    private let gloss = CAGradientLayer()
    private let label = UILabel()
    private let glyph = UIImageView()
    private let size: Size

    init(size: Size) {
        self.size = size
        super.init(frame: .zero)

        layer.cornerRadius = size.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1, alpha: 0.6).cgColor
        layer.shadowColor = AppColor.ink.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 2.5
        layer.shadowOpacity = 0.12

        gloss.colors = [UIColor(white: 1, alpha: 0.4).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        gloss.locations = [0, 0.55]
        gloss.cornerCurve = .continuous
        gloss.cornerRadius = size.radius
        gloss.masksToBounds = true
        layer.insertSublayer(gloss, at: 0)

        label.textAlignment = .center
        label.font = .systemFont(ofSize: size.labelSize, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.translatesAutoresizingMaskIntoConstraints = false

        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(glyph)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.side),
            heightAnchor.constraint(equalToConstant: size.side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gloss.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: size.radius).cgPath
        CATransaction.commit()
    }

    func configure(with node: DriveNode) {
        let kind = FileKind(node: node)
        let palette = Self.palette(for: kind)
        backgroundColor = palette.background

        if kind == .folder {
            glyph.isHidden = false
            glyph.tintColor = palette.foreground
            glyph.image = UIImage(
                systemName: "folder.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: size.glyphSize, weight: .medium
                )
            )
            label.isHidden = true
            return
        }

        glyph.isHidden = true
        label.isHidden = false
        label.textColor = palette.foreground
        label.text = Self.extensionLabel(for: node.name)
    }

    /// 网页取扩展名的前 4 个字符转大写，没有扩展名时显示 `FILE`。
    private static func extensionLabel(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension
        guard !ext.isEmpty else { return "FILE" }
        return String(ext.prefix(4)).uppercased()
    }

    private static func palette(for kind: FileKind) -> (background: UIColor, foreground: UIColor) {
        switch kind {
        case .folder:
            return (AppColor.FileTile.folderBackground, AppColor.FileTile.folderForeground)
        case .image:
            return (AppColor.FileTile.photoBackground, AppColor.FileTile.photoForeground)
        case .audio, .video:
            return (AppColor.FileTile.mediaBackground, AppColor.FileTile.mediaForeground)
        case .markdown, .html, .pdf, .plainText, .archive, .other:
            return (AppColor.FileTile.documentBackground, AppColor.FileTile.documentForeground)
        }
    }
}
