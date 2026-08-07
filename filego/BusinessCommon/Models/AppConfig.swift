import Foundation

/// `GET /app/config` 的 data。所有业务分组均可缺省，保证新旧服务端可以交叉运行。
struct AppConfigData: Codable {
    let schemaVersion: Int?
    let legal: Legal?
    let support: Support?
    let ios: IOS?
    let policies: Policies?

    struct Legal: Codable {
        let privacyPolicyUrl: String?
        let userAgreementUrl: String?
        let termsOfUseUrl: String?
        let policyVersion: String?
    }

    struct Support: Codable {
        let email: String?
        let helpUrl: String?
    }

    struct IOS: Codable {
        let latestVersion: String?
        let minimumSupportedVersion: String?
        let appStoreUrl: String?
        let releaseNotes: String?
    }

    struct Policies: Codable {
        let trashRetentionDays: Int?
    }
}
