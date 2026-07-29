import Foundation

/// 将一次业务操作中的多个请求关联到同一个 trace id。
enum TraceContext {
    @TaskLocal static var current: String?
}
