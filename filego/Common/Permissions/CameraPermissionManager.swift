import AVFoundation
import UIKit

enum PermissionResult {
    case granted
    case justDenied
    case previouslyDenied
}

final class CameraPermissionManager {
    static let shared = CameraPermissionManager()
    private init() {}

    func requestPermission(completion: @escaping (PermissionResult) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(.granted)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .granted : .justDenied)
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
