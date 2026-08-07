import Alamofire
import Foundation
import Moya

enum NodeAPI {
    case list(parentId: String, sort: NodeSort, order: SortOrder, cursor: String?)
    case search(parentId: String, query: String)
    case detail(id: String)
    case ancestors(id: String)
    case temporaryLink(id: String)
    case createFolder(parentId: String, name: String)
    case createImportAddress(id: String)
    case resetImportAddress(id: String)
    case update(id: String, name: String?, parentId: String?, starred: Bool?)
    case copy(id: String, parentId: String)
    /// 移入回收站。服务端只写 trashed_at，可还原，30 天后由 Cron 永久删除。
    case trash(id: String)
}

nonisolated extension NodeAPI: FileGoTarget {
    var path: String {
        switch self {
        case .list: return "/nodes"
        case .search: return "/search"
        case .createFolder: return "/nodes/folder"
        case let .createImportAddress(id): return "/nodes/\(id)/import-address"
        case let .resetImportAddress(id): return "/nodes/\(id)/import-address/reset"
        case let .detail(id): return "/nodes/\(id)"
        case let .ancestors(id): return "/nodes/\(id)/ancestors"
        case let .temporaryLink(id): return "/nodes/\(id)/download-url"
        case let .update(id, _, _, _): return "/nodes/\(id)"
        case let .copy(id, _): return "/nodes/\(id)/copy"
        case let .trash(id): return "/nodes/\(id)"
        }
    }

    var method: Moya.Method {
        switch self {
        case .list, .search, .detail, .ancestors, .temporaryLink: return .get
        case .createFolder, .createImportAddress, .resetImportAddress, .copy: return .post
        case .update: return .patch
        case .trash: return .delete
        }
    }

    var task: Task {
        switch self {
        case let .list(parentId, sort, order, cursor):
            var parameters: [String: Any] = [
                "parent_id": parentId,
                "sort": sort.rawValue,
                "order": order.rawValue
            ]
            if let cursor { parameters["cursor"] = cursor }
            return .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)
        case let .search(parentId, query):
            return .requestParameters(
                parameters: ["parent_id": parentId, "q": query, "limit": 200],
                encoding: URLEncoding.queryString
            )
        case .detail, .ancestors, .temporaryLink, .createImportAddress, .resetImportAddress, .trash:
            return .requestPlain
        case let .createFolder(parentId, name):
            return .requestParameters(
                parameters: ["parentId": parentId, "name": name],
                encoding: JSONEncoding.default
            )
        case let .update(_, name, parentId, starred):
            var parameters: [String: Any] = [:]
            if let name { parameters["name"] = name }
            if let parentId { parameters["parentId"] = parentId }
            if let starred { parameters["starred"] = starred }
            return .requestParameters(parameters: parameters, encoding: JSONEncoding.default)
        case let .copy(_, parentId):
            return .requestParameters(
                parameters: ["parentId": parentId],
                encoding: JSONEncoding.default
            )
        }
    }
}
