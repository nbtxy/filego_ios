import UIKit

/**
 把一条地址摊成二维码给人扫。

 码本身固定白底黑码，不跟 `AppColor` 走：深色底的二维码有相当一部分扫码器直接读不出
 （它们假定暗模块印在亮背景上，反相要额外支持）。周围的卡片可以是纸色，码那一块必须是
 纯白，并且留足静区——所以是一个带内边距的白色圆角容器，而不是把 `UIImageView` 直接
 铺满。
 */
@MainActor
final class InboxQRViewController: UIViewController {
    private let image: UIImage
    private let address: String

    init(image: UIImage, address: String) {
        self.image = image
        self.address = address
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = R.Strings.inboxQr.localizedString()
        view.backgroundColor = AppColor.background

        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }

        let plate = UIView()
        plate.backgroundColor = .white
        plate.layer.cornerRadius = AppRadius.card
        plate.layer.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: image)
        // 码已经在 `QRCode` 里放大到位了，这里只按整数像素贴上去；交给插值会把模块
        // 边界抹糊，相机就对不上了。
        imageView.layer.magnificationFilter = .nearest
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = address

        let caption = UILabel()
        caption.text = R.Strings.inboxQrHint.localizedString()
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = AppColor.textSecondary
        caption.textAlignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false

        let addressLabel = UILabel()
        addressLabel.text = address
        addressLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        addressLabel.textColor = AppColor.textPrimary
        addressLabel.textAlignment = .center
        addressLabel.numberOfLines = 0
        addressLabel.lineBreakMode = .byCharWrapping
        addressLabel.translatesAutoresizingMaskIntoConstraints = false

        plate.addSubview(imageView)
        view.addSubview(plate)
        view.addSubview(addressLabel)
        view.addSubview(caption)

        let quiet = AppSpacing.medium
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            plate.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: AppSpacing.large),
            plate.widthAnchor.constraint(equalTo: plate.heightAnchor),
            plate.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),

            imageView.topAnchor.constraint(equalTo: plate.topAnchor, constant: quiet),
            imageView.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: quiet),
            imageView.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -quiet),
            imageView.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -quiet),

            addressLabel.topAnchor.constraint(
                equalTo: plate.bottomAnchor, constant: AppSpacing.medium),
            addressLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: AppSpacing.large),
            addressLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -AppSpacing.large),

            caption.topAnchor.constraint(
                equalTo: addressLabel.bottomAnchor, constant: AppSpacing.small),
            caption.leadingAnchor.constraint(equalTo: addressLabel.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: addressLabel.trailingAnchor)
        ])

        let plateWidth = plate.widthAnchor.constraint(equalToConstant: 280)
        plateWidth.priority = .defaultHigh
        plateWidth.isActive = true
    }
}
