import UIKit

final class HomeViewController: UIViewController {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // M1 将由 DriveListViewController 取代本页。
        // DEBUG 抓包入口已移到「我的」Tab，这里不再重复挂一个。
        title = R.Strings.tabFiles.localizedString()
        view.backgroundColor = AppColor.background

        let imageView = UIImageView(image: UIImage(systemName: "folder"))
        imageView.tintColor = AppColor.accent
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = R.Strings.tabFiles.localizedString()
        label.font = AppTypography.title
        label.textColor = AppColor.textPrimary
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = AppSpacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 40),
            imageView.heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
}
