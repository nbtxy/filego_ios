import Foundation

/// 缓存最近一次拿到的存储用量，供上传前本地快速预检。
///
/// **只用于快速失败，绝不用于放行。** 服务端那条原子条件 UPDATE 才是唯一权威，
/// 这里的快照可能过期（别的设备刚传了东西、Pro 刚过期），所以：
///   - 快照说「放不下」→ 可以立刻拒，省掉用户白等一次完整 SHA-256
///   - 快照说「放得下」→ 什么都不保证，照常发请求让服务端裁决
@MainActor
final class StorageSnapshotStore {
    private(set) var current: StorageUsage?

    func update(_ usage: StorageUsage?) {
        current = usage
    }

    func clear() {
        current = nil
    }

    /// 本地预检。没有快照时返回 true（不知道就别拦）。
    func likelyFits(_ byteCount: Int64) -> Bool {
        guard let current else { return true }
        return current.canAccommodate(byteCount)
    }
}
