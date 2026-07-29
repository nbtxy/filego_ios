import Foundation

/// 令牌存储。对外 API 与迁移前保持一致（`NetworkProvider` 的 tokenProvider 默认值
/// 直接引用 `AuthTokenStorage.token`），内部改为 Keychain 落盘。
enum AuthTokenStorage {
    private static let tokenKey = "filego.auth.access-token"
    private static let refreshTokenKey = "filego.auth.refresh-token"
    private static let migrationFlagKey = "filego.auth.migrated-to-keychain"

    static var token: String? {
        get { read(tokenKey) }
        set { KeychainStore.set(newValue, forKey: tokenKey) }
    }

    static var refreshToken: String? {
        get { read(refreshTokenKey) }
        set { KeychainStore.set(newValue, forKey: refreshTokenKey) }
    }

    static var isLoggedIn: Bool {
        refreshToken?.isEmpty == false
    }

    static func clear() {
        KeychainStore.remove(forKey: tokenKey)
        KeychainStore.remove(forKey: refreshTokenKey)
    }

    /// 把历史版本写在 UserDefaults 里的令牌搬进 Keychain，并抹掉明文残留。
    /// 在 App 启动时调用一次即可；已迁移过则直接返回。
    static func migrateFromUserDefaultsIfNeeded() {
        let store = KeyValueStore.shared
        guard store.globalValue(forKey: migrationFlagKey, as: Bool.self) != true else { return }

        for key in [tokenKey, refreshTokenKey] {
            if let legacy: String = store.globalValue(forKey: key) {
                KeychainStore.set(legacy, forKey: key)
                // 明文副本必须清掉，否则迁移只是把钥匙多配了一把
                store.setGlobal(Optional<String>.none, forKey: key)
                AppLogger.info("已将 \(key) 从 UserDefaults 迁移至 Keychain")
            }
        }
        store.setGlobal(true, forKey: migrationFlagKey)
    }

    private static func read(_ key: String) -> String? {
        KeychainStore.string(forKey: key)
    }
}
