import Photos
import UIKit

final class PhotoPermissionManager {
    static let shared = PhotoPermissionManager()
    private init() {}

    func requestPermission(completion: @escaping (PermissionResult) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion(.granted)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    completion(
                        status == .authorized || status == .limited
                            ? .granted
                            : .justDenied
                    )
                }
            }
        default:
            completion(.previouslyDenied)
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
