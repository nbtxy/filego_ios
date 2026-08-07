import Foundation

/// App 级公开配置。冷启动先使用同一后端上次成功响应，随后静默刷新。
@MainActor
final class AppConfigStore {
    private struct Cache: Codable {
        let baseURL: String
        let config: AppConfigData
    }

    private enum Fallback {
        static let supportEmail = "support@filego.deeptrans.pro"
        static let trashRetentionDays = 30
    }

    private static let cacheKey = "filego.app-config.v1"

    private let networkProvider: NetworkProvider
    private let keyValueStore: KeyValueStore
    private var loadTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var configBaseURL: String?

    private(set) var config: AppConfigData?

    init(networkProvider: NetworkProvider, keyValueStore: KeyValueStore) {
        self.networkProvider = networkProvider
        self.keyValueStore = keyValueStore

        do {
            let cache = try keyValueStore.globalCodable(forKey: Self.cacheKey, as: Cache.self)
            if cache?.baseURL == BackendConfig.baseURL.absoluteString {
                config = cache?.config
                configBaseURL = cache?.baseURL
            }
        } catch {
            AppLogger.warning("读取 App 配置缓存失败：\(error.localizedDescription)")
        }
    }

    /// 每次进程生命周期只自动请求一次；并发调用会等待同一个请求。
    func bootstrap() async {
        guard !hasBootstrapped else { return }
        await load()
        hasBootstrapped = true
    }

    /// 用户主动刷新或以后进入前台时可调用。失败时保留最后一次有效配置。
    func refresh() async {
        await load()
        hasBootstrapped = true
    }

    var privacyPolicyURL: URL {
        validatedURL(activeConfig?.legal?.privacyPolicyUrl)
            ?? serverRootURL.appendingPathComponent("legal/privacy")
    }

    var userAgreementURL: URL {
        validatedURL(activeConfig?.legal?.userAgreementUrl)
            ?? serverRootURL.appendingPathComponent("legal/agreement")
    }

    var termsOfUseURL: URL {
        validatedURL(activeConfig?.legal?.termsOfUseUrl)
            ?? URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }

    var policyVersion: String? { normalized(activeConfig?.legal?.policyVersion) }
    var supportEmail: String { normalized(activeConfig?.support?.email) ?? Fallback.supportEmail }
    var helpURL: URL? { validatedURL(activeConfig?.support?.helpUrl) }
    var iosUpgrade: AppConfigData.IOS? { activeConfig?.ios }

    var trashRetentionDays: Int {
        guard let days = activeConfig?.policies?.trashRetentionDays, (1...365).contains(days) else {
            return Fallback.trashRetentionDays
        }
        return days
    }

    private var serverRootURL: URL {
        BackendConfig.baseURL
            .deletingLastPathComponent() // /api
            .deletingLastPathComponent() // /
    }

    /// Debug 切换后端后，旧环境配置立即失效；新请求成功前使用新地址对应的随包兜底。
    private var activeConfig: AppConfigData? {
        configBaseURL == BackendConfig.baseURL.absoluteString ? config : nil
    }

    private func load() async {
        if let loadTask {
            await loadTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let requestBaseURL = BackendConfig.baseURL.absoluteString
            do {
                let value = try await networkProvider.request(
                    AppConfigAPI.config,
                    as: AppConfigData.self
                )
                // Debug 面板可能在请求途中切换后端，旧响应绝不能覆盖新环境。
                guard requestBaseURL == BackendConfig.baseURL.absoluteString else { return }
                config = value
                configBaseURL = requestBaseURL
                try keyValueStore.setGlobalCodable(
                    Cache(baseURL: requestBaseURL, config: value),
                    forKey: Self.cacheKey
                )
            } catch {
                AppLogger.warning("刷新 App 配置失败，继续使用本地配置：\(error.localizedDescription)")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func normalized(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }

    private func validatedURL(_ value: String?) -> URL? {
        guard
            let value = normalized(value),
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else { return nil }
        return url
    }
}
