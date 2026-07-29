import Alamofire
import Foundation
import Moya

struct UploadInitResponse: Decodable {
    let mode: String
    let sessionId: String?
    let uploadUrl: String?
    let node: DriveNode?
}

struct UploadCompleteResponse: Decodable {
    let mode: String
    let sessionId: String?
    let node: DriveNode
}

struct UploadAbortResponse: Decodable {
    let aborted: Bool
}

enum UploadAPI {
    case initialize(parentId: String, name: String, size: Int64, mime: String, sha256: String)
    case complete(sessionId: String)
    case abort(sessionId: String)
}

extension UploadAPI: FileGoTarget {
    var path: String {
        switch self {
        case .initialize: return "/uploads/init"
        case let .complete(sessionId): return "/uploads/\(sessionId)/complete"
        case let .abort(sessionId): return "/uploads/\(sessionId)"
        }
    }

    var method: Moya.Method {
        switch self {
        case .initialize, .complete: return .post
        case .abort: return .delete
        }
    }

    var task: Task {
        switch self {
        case let .initialize(parentId, name, size, mime, sha256):
            return .requestParameters(
                parameters: [
                    "parentId": parentId,
                    "name": name,
                    "size": size,
                    "mime": mime,
                    "sha256": sha256
                ],
                encoding: JSONEncoding.default
            )
        case .complete, .abort:
            return .requestPlain
        }
    }
}
