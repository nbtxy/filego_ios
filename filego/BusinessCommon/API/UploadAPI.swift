import Alamofire
import Foundation
import Moya

/// 一片的描述。`uploadUrl` 是服务端签发的 R2 预签名 PUT 地址；服务端未配置 R2
/// 直传密钥时会是 nil，此时大文件传不上去（见 FileUploadService.Failure）。
struct UploadPartDescriptor: Decodable, Sendable {
    let partNumber: Int
    let size: Int64
    let uploadUrl: String?
}

struct UploadInitResponse: Decodable {
    let mode: String
    let sessionId: String?
    let uploadUrl: String?
    let chunkSize: Int64?
    let parts: [UploadPartDescriptor]?
    let nextPartNumber: Int?
    let node: DriveNode?
}

/// `GET /uploads/{id}/parts?from=` 的续签结果。服务端一页最多签 20 片。
struct UploadPartsPage: Decodable, Sendable {
    let parts: [UploadPartDescriptor]
    let nextPartNumber: Int?
    let partCount: Int
}

/// `GET /uploads/{id}`：断点续传的依据，`uploadedParts` 是服务端已确认的片。
struct UploadStatusResponse: Decodable, Sendable {
    struct Part: Decodable, Sendable {
        let partNumber: Int
        let etag: String
        let size: Int64
    }

    let sessionId: String
    let mode: String
    let status: String
    let size: Int64
    let chunkSize: Int64
    let uploadedParts: [Part]
}

struct UploadPartRecorded: Decodable {
    let recorded: Bool
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
    case status(sessionId: String)
    case partURLs(sessionId: String, from: Int)
    case reportPart(sessionId: String, partNumber: Int, etag: String, size: Int64)
    case complete(sessionId: String)
    case abort(sessionId: String)
}

extension UploadAPI: FileGoTarget {
    var path: String {
        switch self {
        case .initialize: return "/uploads/init"
        case let .status(sessionId): return "/uploads/\(sessionId)"
        case let .partURLs(sessionId, _): return "/uploads/\(sessionId)/parts"
        case let .reportPart(sessionId, _, _, _): return "/uploads/\(sessionId)/parts"
        case let .complete(sessionId): return "/uploads/\(sessionId)/complete"
        case let .abort(sessionId): return "/uploads/\(sessionId)"
        }
    }

    var method: Moya.Method {
        switch self {
        // .status 与 .abort 共用 /uploads/{id}，靠方法区分
        case .status, .partURLs: return .get
        case .initialize, .reportPart, .complete: return .post
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
        case let .partURLs(_, from):
            return .requestParameters(
                parameters: ["from": from],
                encoding: URLEncoding.queryString
            )
        case let .reportPart(_, partNumber, etag, size):
            return .requestParameters(
                parameters: [
                    "partNumber": partNumber,
                    "etag": etag,
                    "size": size
                ],
                encoding: JSONEncoding.default
            )
        case .status, .complete, .abort:
            return .requestPlain
        }
    }
}
