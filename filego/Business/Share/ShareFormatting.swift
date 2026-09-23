import Foundation
import StolnkCore

/**
 外发下载链接的选项与文案。

 「share」这个词在本 App 里已经被占用了：`R.Strings.inboxShare` 指的是唤起系统分享
 面板。这里说的是另一件事——一条公开的下载链接。面向用户的英文一律叫 **download
 link**，从不叫 "a share"；代码里沿用服务端的 `share` 是为了和 `ShareSummary`、
 `/api/v1/shares` 对得上。别把两者「统一」掉。

 抽成一个文件是因为创建页和详情页都要格式化同一批东西，各写一份的结果就是同一个
 到期时间在两个页面上长得不一样。
 */
enum ShareTTL {
    /// 和服务端 `SHARE_TTL_PRESETS` 一致。
    static let presets: [Double] = [1, 24, 168, 720]

    /// 免费档的上限（`limits.ts` 的 `maxShareTtlHours`）。超过这个数的档位要 Pro。
    static let freeMaxHours: Double = 24

    static func requiresPro(_ hours: Double) -> Bool { hours > freeMaxHours }

    static func label(_ hours: Double) -> String {
        switch hours {
        case 1: R.Strings.shareTtl1h.localizedString()
        case 24: R.Strings.shareTtl24h.localizedString()
        case 168: R.Strings.shareTtl7d.localizedString()
        default: R.Strings.shareTtl30d.localizedString()
        }
    }

    /// 选择器上显示的文案。Pro 专属的档位带一个后缀，免费用户点下去会撞到付费墙，
    /// 提前说出来比让他们撞一次强。
    static func label(_ hours: Double, isPro: Bool) -> String {
        let base = label(hours)
        guard requiresPro(hours), !isPro else { return base }
        return R.Strings.shareTtlProSuffix.formatted(base)
    }
}

enum ShareDownloads {
    /// `nil` 是不限次数，也是默认值。
    static let presets: [Int?] = [nil, 1, 5, 25]

    static func label(_ value: Int?) -> String {
        switch value {
        case .none: R.Strings.shareDownloadsUnlimited.localizedString()
        case 1: R.Strings.shareDownloadsOnce.localizedString()
        case 5: R.Strings.shareDownloads5.localizedString()
        default: R.Strings.shareDownloads25.localizedString()
        }
    }
}

enum ShareFormatting {
    /**
     单个文件的大小上限，按档位推导。

     `PlanState` 不带这个字段，而服务端是按档位写死的（`limits.ts` 的 `maxFileSize`：
     免费 2 GiB，Pro 20 GiB）。本地拦一道是为了不让用户传了一半才被 413 打回来——
     真正的闸门仍然在服务端。
     */
    static func maxFileSize(isPro: Bool) -> Int64 {
        isPro ? 20 * 1024 * 1024 * 1024 : 2 * 1024 * 1024 * 1024
    }

    /**
     这条链接现在是什么状态。

     `uploading` 分两种，差别很大：正在传的那一条是好事，而一条服务端说在传、本地却
     没有任何上传在跑的，是上次被切后台杀掉的残骸——它占着额度和路径，却永远不会生效。
     只有后者标警示色，因为只有后者需要用户动手。
     */
    static func state(of share: ShareSummary, isUploading: Bool) -> (text: String, isWarning: Bool) {
        if share.state == "uploading" {
            return isUploading
                ? (R.Strings.shareStateUploading.localizedString(), false)
                : (R.Strings.shareStateIncomplete.localizedString(), true)
        }
        if share.state == "revoked" {
            return (R.Strings.shareStateRevoked.localizedString(), true)
        }
        if share.state == "spent" {
            return (R.Strings.shareStateSpent.localizedString(), true)
        }
        // 过期是算出来的，不是服务端存的状态：一行 ready 过了 expires_at 就是过期。
        if share.expiresAt <= Date().timeIntervalSince1970 * 1000 {
            return (R.Strings.shareStateExpired.localizedString(), true)
        }
        if share.paused {
            return (R.Strings.shareStatePaused.localizedString(), true)
        }
        return (R.Strings.shareStateReady.localizedString(), false)
    }

    static func expiry(_ share: ShareSummary) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: share.expiresAt / 1000))
    }

    /// 「已下载」。有上限就说清楚是几分之几，没上限只说下了多少次——把「不限」写成
    /// 分母会让人以为还有个数字没显示出来。
    static func downloads(_ share: ShareSummary) -> String {
        guard let maximum = share.maxDownloads else {
            return R.Strings.shareDetailDownloadsServed.formatted(share.downloads)
        }
        return R.Strings.shareDetailDownloadsOf.formatted(share.downloads, maximum)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
