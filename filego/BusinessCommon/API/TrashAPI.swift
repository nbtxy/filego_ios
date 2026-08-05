import Alamofire
import Foundation
import Moya

/// 回收站。列表只返回「回收根」——被回收文件夹里的子项由服务端隐藏，
/// 还原父级时子项会一并回来，无需客户端做树形处理。
enum TrashAPI {
    case list(limit: Int)
    case restore(id: String)
    case deleteForever(id: String)
    case emptyAll
}

extension TrashAPI: FileGoTarget {
    var path: String {
        switch self {
        case .list, .emptyAll: return "/trash"
        case let .restore(id): return "/trash/\(id)/restore"
        case let .deleteForever(id): return "/trash/\(id)"
        }
    }

    var method: Moya.Method {
        switch self {
        case .list: return .get
        case .restore: return .post
        case .deleteForever, .emptyAll: return .delete
        }
    }

    var task: Task {
        switch self {
        case let .list(limit):
            return .requestParameters(parameters: ["limit": limit], encoding: URLEncoding.queryString)
        case .restore, .deleteForever, .emptyAll:
            return .requestPlain
        }
    }
}
