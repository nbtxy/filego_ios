import StolnkCore
import UIKit

/**
 「创建下载链接」的统一入口：前置校验 + 弹表单 + 成功后复制链接。

 抽出来是因为入口有两个——Drive 的长按菜单和文件预览页——而它们要做的检查一模一样。
 各写一份的下场是其中一处会漏掉某道闸门，而漏掉的那道大概率就是 0 字节那道
 （理由见 `refuseEmpty` 上的注释），它的代价最贵。

 所有检查都在本地，一个网络请求都不发：这些答案本地全都有，为了一句「文件是空的」
 去 round-trip 一次，还要在免费档上烧掉那唯一的额度，是说不过去的。
 */
@MainActor
enum ShareLauncher {
    static func start(
        from presenter: UIViewController,
        environment: AppEnvironment,
        file: URL,
        filename: String,
        size: Int64
    ) {
        /*
         0 字节必须在这里挡住，这不是理论上的洁癖。服务端对空文件算出 `part_count = 1`、
         `expected = 0`，`content-length: 0` 会**通过** part 的长度检查，然后卡在
         `if (!c.req.raw.body) return badRequest("Empty body.")`（`shares.ts`）。
         也就是说创建返回 201、传 part 返回 400：记录建出来了，永远停在 `uploading`，
         占着一个额度和一个路径。免费档只有一个额度。
         */
        guard size > 0 else {
            return alert(
                on: presenter,
                title: R.Strings.shareEmptyTitle.localizedString(),
                message: R.Strings.shareEmptyMessage.localizedString())
        }

        let stolnk = environment.stolnk
        // plan 缺失就不预判任何事，让 402 自然到来——`PlanState.shareLimit` 的文档
        // 注释就是这么要求的，而 `refreshPlan()` 是 try?，plan 真的可能是 nil。
        if let plan = stolnk.plan {
            // 条数上限。服务端统计的是**全部**记录，不过滤状态，所以已撤回和已过期的
            // 也算在内——这条本地判断和它数的是同一群。
            if let limit = plan.shareLimit, stolnk.shares.count >= limit {
                return showUpgrade(on: presenter, environment: environment)
            }
            let maximum = ShareFormatting.maxFileSize(isPro: plan.isPro)
            if size > maximum {
                return alert(
                    on: presenter,
                    title: R.Strings.shareTooBigTitle.localizedString(),
                    message: R.Strings.shareTooBigMessage.formatted(ByteFormatting.quota(maximum)))
            }
            // 外发链接同样从月度中转额度里扣（worker 的 `lib/share.ts`），很容易漏。
            if Int64(plan.relayLimit - plan.relayUsed) < size {
                return alert(
                    on: presenter,
                    title: R.Strings.quotaExceededTitle.localizedString(),
                    message: R.Strings.quotaExceededMessage.localizedString())
            }
        }

        let form = NewShareViewController(
            environment: environment, file: file, filename: filename, size: size
        ) { [weak presenter] handle in
            guard let presenter else { return }
            // 和 Mac 端一样，建完就把链接放进剪贴板——那是用户接下来唯一要做的事。
            // 不跳转到列表：突然 push 一屏会把这个提示埋掉。
            UIPasteboard.general.string = handle.url
            PaperToast.show(R.Strings.shareCopied.localizedString(), in: presenter.view)
            HapticManager.notification(.success)
        }
        presenter.present(UINavigationController(rootViewController: form), animated: true)
    }

    private static func showUpgrade(on presenter: UIViewController, environment: AppEnvironment) {
        presenter.present(
            UINavigationController(
                rootViewController: ProUpgradeViewController(environment: environment)),
            animated: true)
    }

    private static func alert(on presenter: UIViewController, title: String, message: String) {
        let controller = UIAlertController(
            title: title, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(
            title: R.Strings.commonOk.localizedString(), style: .default))
        presenter.present(controller, animated: true)
    }
}
