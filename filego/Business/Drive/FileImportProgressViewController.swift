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
        titleLabel.textColor = AppColor.textPrimary
        titleLabel.setTightText(
            R.Strings.driveImportTitle.localizedString(),
            font: AppTypography.modalTitle
        )

        let fileLabel = UILabel()
        fileLabel.text = fileName
        fileLabel.font = AppTypography.body
        fileLabel.textColor = AppColor.textPrimary
        fileLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel.text = R.Strings.driveImportPreparing.localizedString()
        statusLabel.font = AppTypography.caption
        statusLabel.textColor = AppColor.textSecondary

        // 与网页 `.up-bar` 一致：柠檬绿进度压在 paper-2 轨道上。
        progressView.progressTintColor = AppColor.lime
        progressView.trackTintColor = AppColor.paper2
        progressView.layer.cornerRadius = 3
        progressView.clipsToBounds = true
        progressView.transform = CGAffineTransform(scaleX: 1, y: 1.5)
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
