import Foundation
import StolnkCore

/**
 子域名（`ryan.stolnk.com` 的 `ryan`）现在的状态，给侧栏「我的」、收件设置、改名页和
 onboarding 共用同一套说法。

 规则在服务端（`PlanState.addressActive` / `nameExpiresAt`）：会员的名字永久保留、可随时
 修改；非会员的自定义名 7 天后失效、原名字释放，设备暂时没有可用地址，必须重新设置
 一个子域名才能继续接收文件。
 */
@MainActor
enum NameStatusText {
    /// 非会员自定义名的宽限期。只用于文案里事先说明，真正的到期时间以服务端为准。
    static let graceDays = 7

    struct Text {
        /// 一行里放得下的：「永久」「还剩 3 天」「已到期」。
        let short: String
        /// 一两句解释后果。
        let detail: String
        /// 非会员、名字会过期——调用方据此显示升级入口。
        let expires: Bool
        /// 现在没有可用地址，需要设置（或重新设置）子域名。
        let needsName: Bool
    }

    static func make(environment: AppEnvironment) -> Text {
        let plan = environment.stolnk.plan
        // 文案里的地址要和上面那张卡片显示的是同一个。用 inbox 的服务端地址，
        // 而不是用本机配置拼出来的 `<name><suffix>`：开发环境连的是
        // `localhost:5173`，而服务端给出的链接已经是 `https://<name>.stolnk.com`，
        // 拼出来的那一份会在同一屏里和真实地址打架。
        let address = (environment.stolnk.inbox?.url ?? "")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let fallback = address.isEmpty
            ? (environment.stolnk.name ?? "") + environment.stolnk.nameSuffix
            : address
        guard let plan else {
            return Text(
                short: "", detail: R.Strings.nameStatusUnknown.localizedString(),
                expires: false, needsName: false)
        }
        // 地址失效优先于会员身份：会员若在到期后才订阅，也得先设置一个新名字。
        if plan.addressActive == false {
            return Text(
                short: R.Strings.nameStatusExpired.localizedString(),
                detail: R.Strings.nameStatusExpiredDetail.localizedString(),
                expires: false, needsName: true)
        }
        if plan.isPro {
            return Text(
                short: R.Strings.nameStatusLocked.localizedString(),
                detail: R.Strings.nameStatusLockedDetail.formatted(fallback),
                expires: false, needsName: false)
        }
        guard let days = plan.nameDaysLeft() else {
            // 非会员、地址可用、却没有到期日：只可能是旧版本留下的随机名。
            return Text(
                short: R.Strings.nameStatusNoName.localizedString(),
                detail: R.Strings.nameStatusNoNameDetail.formatted(graceDays),
                expires: false, needsName: true)
        }
        if days <= 0 {
            // 已过期但清扫任务还没跑（最长一个 cron 周期）。
            return Text(
                short: R.Strings.nameStatusExpired.localizedString(),
                detail: R.Strings.nameStatusExpiredDetail.localizedString(),
                expires: true, needsName: true)
        }
        return Text(
            short: R.Strings.nameStatusDaysLeft.formatted(days),
            detail: R.Strings.nameStatusDaysLeftDetail.formatted(fallback, days),
            expires: true, needsName: false)
    }
}
