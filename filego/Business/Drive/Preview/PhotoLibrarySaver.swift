import os
import Photos
import UIKit

/// 将图片或视频保存到系统相册。
///
/// `VideoPreviewController` 与 `FilePreviewContainerViewController` 共用，
/// 统一处理 `.addOnly` 权限申请、不支持格式的兜底提示以及成功/失败反馈。
@MainActor
enum PhotoLibrarySaver {
    nonisolated enum MediaKind: Sendable {
        case image
        case video

        init?(fileKind: FileKind) {
            switch fileKind {
            case .image: self = .image
            case .video: self = .video
            default: return nil
            }
        }
    }

    private nonisolated enum SaveError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? {
            R.Strings.previewSaveToPhotosUnsupported.localizedString()
        }
    }

    static func save(
        url: URL,
        kind: MediaKind,
        from presenter: UIViewController
    ) {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                presentPermissionAlert(from: presenter)
                return
            }
            do {
                try await write(url: url, kind: kind)
                HapticManager.notification(.success)
                PaperToast.show(
                    R.Strings.previewSavedToPhotos.localizedString(),
                    in: presenter.view
                )
            } catch {
                AppLogger.error("保存到相册失败", error: error)
                HapticManager.notification(.error)
                PaperToast.show(
                    error.localizedDescription,
                    in: presenter.view,
                    isError: true
                )
            }
        }
    }

    private nonisolated static func write(url: URL, kind: MediaKind) async throws {
        let created = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            switch kind {
            case .image:
                if PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) != nil {
                    created.withLock { $0 = true }
                } else if let image = UIImage(contentsOfFile: url.path) {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                    created.withLock { $0 = true }
                }
            case .video:
                if PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) != nil {
                    created.withLock { $0 = true }
                }
            }
        }
        guard created.withLock({ $0 }) else {
            throw SaveError.unsupportedFormat
        }
    }

    private static func presentPermissionAlert(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: R.Strings.previewSaveToPhotosDenied.localizedString(),
            message: R.Strings.previewSaveToPhotosDeniedMessage.localizedString(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: R.Strings.commonCancel.localizedString(),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: R.Strings.driveImportOpenSettings.localizedString(),
            style: .default
        ) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
    }
}
