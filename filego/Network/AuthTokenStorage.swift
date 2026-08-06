import Foundation

/// 令牌存储。对外 API 与迁移前保持一致（`NetworkProvider` 的 tokenProvider 默认值
/// 直接引用 `AuthTokenStorage.token`），内部改为 Keychain 落盘。
enum AuthTokenStorage {
    private static let tokenKey = "filego.auth.access-token"
    private static let refreshTokenKey = "filego.auth.refresh-token"
    private static let migrationFlagKey = "filego.auth.migrated-to-keychain"
    private static let installMarkerKey = "filego.auth.install-marker"

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

    /// 全新安装时清掉 Keychain 里活过卸载的令牌。
    ///
    /// iOS 删除 App 只清 sandbox（Documents / Caches / UserDefaults），Keychain 条目按
    /// service 归属，不随 App 一起删。结果是重装后 refresh token 还在（`isLoggedIn` 为
    /// true 直接进主页），而存在 UserDefaults 里的 userID 已经没了——`/auth/refresh` 又
    /// 只返回令牌不返回 user，userID 补不回来，缓存域、订阅绑定、「我的」页全部静默失效。
    ///
    /// 根因是凭据和身份信息放在了寿命不同的两种介质里。这里把「全新安装」显式判成未登录，
    /// 让两者重新对齐：重装即回登录页，重登时令牌与 userID 一起写入。
    ///
    /// 必须在 `migrateFromUserDefaultsIfNeeded()` **之前**调用，否则迁移会把
    /// `migrationFlagKey` 置 true，全新安装与老用户升级就分辨不出来了。
    static func clearOnFreshInstallIfNeeded() {
        let store = KeyValueStore.shared
        guard store.globalValue(forKey: installMarkerKey, as: Bool.self) != true else { return }

        // 老用户升级到本版本时同样没有安装标记，不能一律清，否则等于把存量用户全踢下线。
        // 卸载会把 UserDefaults 一并带走，所以 global 域里还留着旧版本写过的痕迹，
        // 就说明这是升级而非全新安装。迁移标记覆盖迁移之后的版本，明文令牌覆盖更早的版本。
        let isUpgrade = store.globalValue(forKey: migrationFlagKey, as: Bool.self) != nil
            || store.globalValue(forKey: tokenKey, as: String.self) != nil
            || store.globalValue(forKey: refreshTokenKey, as: String.self) != nil

        if !isUpgrade {
            clear()
            AppLogger.info("检测到全新安装，已清理 Keychain 中残留的历史令牌")
        }
        store.setGlobal(true, forKey: installMarkerKey)
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
