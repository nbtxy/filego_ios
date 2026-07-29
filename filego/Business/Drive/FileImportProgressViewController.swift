import UIKit

final class FileImportProgressViewController: UIViewController {
    private let fileName: String
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()

    init(fileName: String) {
        self.fileName = fileName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.background
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 220 }]
            sheet.prefersGrabberVisible = false
        }

        let titleLabel = UILabel()
        titleLabel.text = R.Strings.driveImportTitle.localizedString()
        titleLabel.font = AppTypography.title
        titleLabel.textColor = AppColor.textPrimary

        let fileLabel = UILabel()
        fileLabel.text = fileName
        fileLabel.font = AppTypography.body
        fileLabel.textColor = AppColor.textPrimary
        fileLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel.text = R.Strings.driveImportPreparing.localizedString()
        statusLabel.font = AppTypography.caption
        statusLabel.textColor = AppColor.textSecondary

        progressView.progressTintColor = AppColor.accent
        progressView.progress = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, fileLabel, progressView, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppSpacing.large),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppSpacing.large),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func updateProgress(_ fraction: Double) {
        let value = min(1, max(0, fraction))
        progressView.setProgress(Float(value), animated: true)
        statusLabel.text = R.Strings.driveImportUploading.localizedString()
            + " \(Int(value * 100))%"
    }
}
