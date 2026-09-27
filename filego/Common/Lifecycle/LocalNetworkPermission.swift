import Foundation
import Network

/**
 让系统提前弹出「本地网络」权限框。

 iOS 在 App 第一次真正碰本地网络时才弹框，而 LAN 直传第一次碰本地网络是在一个
 offer 到来的那一刻——弹框挡在协商中间，发送页等不及就回落中转了，用户第一次的
 同 Wi-Fi 传输白白走了一趟服务器。所以在用户刚给文件夹取完地址时先弹：那时他
 正在想「别人怎么把文件发给我」，这个问题最好懂。

 手段是浏览一下 `_stolnk._tcp`（`AppInfo.plist` 的 `NSBonjourServices` 里声明过），
 一秒后取消。浏览结果不用，要的只是那一下对本地网络的访问。只触发一次：用户答过
 之后，系统不会再问，再浏览也没有意义。
 */
enum LocalNetworkPermission {
    private static let askedKey = "lan.permission.asked"

    static func requestOnce(preferences: KeyValueStore) {
        guard preferences.value(forKey: askedKey, as: Bool.self) != true else { return }
        preferences.set(true, forKey: askedKey)

        let browser = NWBrowser(
            for: .bonjour(type: "_stolnk._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { browser.cancel() }
    }
}
