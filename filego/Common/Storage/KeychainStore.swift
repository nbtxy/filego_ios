import Foundation
import Security

/// Keychain 封装，只存字符串。
///
/// 令牌等同于用户全部云端文件的钥匙，不能放 UserDefaults——那是明文 plist，
/// 且会进入 iTunes / iCloud 备份，一次备份泄露等于把网盘交出去。
///
/// 可访问性用 `AfterFirstUnlock` 而不是 `WhenUnlocked`：M2 的后台上传要在
/// 锁屏状态下继续跑并读取令牌，`WhenUnlocked` 会让后台任务在锁屏时拿不到令牌。
enum KeychainStore {
    private static let service = "com.nbtxy.filego.secure"

    static func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                AppLogger.error("Keychain 读取失败 key=\(key) status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 传 nil 等于删除。
    static func set(_ value: String?, forKey key: String) {
        // 先删后加，避免 SecItemUpdate 在属性变更时的边角情况。令牌写入极不频繁，
        // 多一次系统调用无所谓，换来的是逻辑上不会有「更新了值但可访问性还是旧的」。
        remove(forKey: key)

        guard let value, let data = value.data(using: .utf8) else { return }

        var attributes = baseQuery(forKey: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.error("Keychain 写入失败 key=\(key) status=\(status)")
        }
    }

    static func remove(forKey key: String) {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLogger.error("Keychain 删除失败 key=\(key) status=\(status)")
        }
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
