import Foundation
import StolnkCore
import UIKit

/// 连接状态。与 Mac 端 `ConnectionStatus` 同形，少了 `.receiving` 之外的差别。
enum StolnkStatus: Equatable {
    case connecting
    case ready
    case receiving(progress: Double)
    case paused
    case offline
}

extension Notification.Name {
    /// 状态、inbox 列表、name、错误任一变化。UIKit 侧统一靠它刷新。
    static let stolnkStateDidChange = Notification.Name("stolnk.state-did-change")
    /// 有文件落地。`userInfo["files"]` 是 `[LandedFile]`。
    static let stolnkDidLandFiles = Notification.Name("stolnk.did-land-files")
    /// 设备注册状态变化——注册成功，或服务端不再认识这台设备。
    static let stolnkRegistrationDidChange = Notification.Name("stolnk.registration-did-change")
}

/**
 iOS 侧的设备控制器，对应 Mac 端的 `AppState`。

 职责与 Mac 端一致：持有设备密钥与 `APIClient`，装配 `Receiver`，维护 signalling
 长连接，并在各种时机触发 `/pending` 轮询。差别只在触发源——Mac 靠
 `NSWorkspace.didWakeNotification` 和常驻的 300 秒定时器，iOS 没有常驻进程，
 靠的是进前台。

 不是 `ObservableObject`：这个 App 是 UIKit 的，状态变化通过
 `NotificationCenter` 广播，和既有的 `RootViewController` 换根方式一致。
 */
@MainActor
final class StolnkController {
    private let store: InboxStore
    private var api: APIClient?
    private var receiver: Receiver?
    private var signalling: SignallingClient?
    private var identityKeys: DeviceIdentity?
    private var pollTimer: Timer?
    private var socketConnected = false

    private(set) var status: StolnkStatus = .connecting
    private(set) var inboxes: [InboxSummary] = []
    private(set) var recent: [LandedFile] = []
    private(set) var name: String?
    private(set) var plan: PlanState?
    private(set) var isEnclaveBacked = false
    private(set) var lastError: String?

    /// 外发的下载链接。和 `inboxes` 同级：一个是别人发给你，一个是你发给别人。
    private(set) var shares: [ShareSummary] = []

    /**
     正在上传的那一条下载链接。

     刻意是单个 optional 而不是 Mac 端那样的数组：Mac 有常驻窗口，能同时列出好几条；
     iOS 的上传是从一个还停在屏幕上的模态里驱动的，而且 App 一进后台就断
     （`URLSession.shared` 不是 background session），所以第二条永远不会存在。
     */
    private(set) var shareUpload: ShareUpload?

    /// 上一次广播出去的百分比。见 `upload(_:from:filename:)` 里的节流说明。
    private var shareUploadPercent = 0

    /// 上传进度。`fraction` 是整个文件的 0…1，不是单个 part 的。
    struct ShareUpload: Sendable {
        let shareID: String
        let filename: String
        var fraction: Double
    }

    /// 没有 deviceID 就是还没注册过——onboarding 的唯一判据。
    var isRegistered: Bool { store.snapshot.deviceID != nil }

    /// `.stolnk.com`，name 输入框后面跟着的那截。
    var nameSuffix: String { SiteAddress.suffix(baseHost: store.snapshot.baseHost) }

    /// `ryan.stolnk.com/`，路径输入框前面钉着的那截。还没注册时为 nil。
    ///
    /// 单独一个属性而不是让调用方拼：`store` 是 private，外面拿不到 baseHost，
    /// 而 `nameSuffix` 是给 name 输入框用的，形状不对。
    var addressPrefix: String? {
        let state = store.snapshot
        guard let name = state.name else { return nil }
        return SiteAddress.prefix(name: name, baseHost: state.baseHost)
    }

    var origin: URL {
        let state = store.snapshot
        return URL(string: "\(state.scheme)://\(state.baseHost)")
            ?? URL(string: "\(StoredState.defaultScheme)://\(StoredState.defaultBaseHost)")!
    }

    init(store: InboxStore = InboxStore()) {
        self.store = store
    }

    // MARK: - 启动

    /**
     取密钥、恢复会话、装配接收链路。

     密钥失败和网络失败分开 catch，理由和 Mac 端相同：两者的补救动作完全不同，
     合在一起会让「拿不到密钥」表现成「离线」，用户看不出该做什么。
     */
    func start() async {
        recent = store.snapshot.recent
        inboxes = store.snapshot.inboxes
        shares = store.snapshot.shares
        name = store.snapshot.name

        let keys: DeviceIdentity
        do {
            keys = try DeviceIdentity.loadOrCreate()
        } catch {
            lastError = error.localizedDescription
            status = .offline
            broadcast()
            return
        }

        identityKeys = keys
        isEnclaveBacked = keys.isEnclaveBacked
        let client = APIClient(origin: origin, identity: keys)
        api = client

        do {
            let saved = store.snapshot
            if let deviceID = saved.deviceID {
                await client.adopt(deviceID: deviceID, token: saved.token)
                _ = try await client.authenticate()
                await persistToken()
            }

            buildReceiver(api: client, keys: keys)

            if saved.deviceID != nil {
                await refreshInboxes()
                await refreshShares()
                await refreshPlan()
                connectSignalling()
                await poll()
                startForegroundPolling()
            }
        } catch {
            handle(error)
            status = .offline
        }
        observeForeground()
        broadcast()
    }

    // MARK: - 注册

    /**
     PRD 7.1 —— 注册是一屏一次调用。name 不是随机地址的升级版，它**就是**身份，
     所以和公钥一起上行：重名以 409 失败且什么都不创建，这才让换个名字重试是干净的。

     只上行名字，不带 slug：这一屏只确定根域名，不产生任何链接。路径是给**文件夹**
     取的名字，而此刻还没有任何文件夹被选中，所以它属于 `createInbox`。在那之前，
     这台设备名下一个 inbox 也没有——那不是半成品状态，只是还没取地址。
     */
    func register(name chosen: String) async -> Bool {
        guard let keys = identityKeys ?? (try? DeviceIdentity.loadOrCreate()) else {
            lastError = "无法创建设备密钥"
            broadcast()
            return false
        }
        identityKeys = keys
        let client = api ?? APIClient(origin: origin, identity: keys)
        api = client
        lastError = nil

        do {
            let result = try await client.register(name: NameRules.normalise(chosen))
            name = result.name
            // 不再拉一次 /inboxes：名字已经在 result 里，列表则已知为空。
            inboxes = []
            store.mutate { state in
                state.deviceID = result.deviceID
                state.name = result.name
                state.token = result.token
                state.inboxes = []
                state.hasCompletedOnboarding = true
            }

            buildReceiver(api: client, keys: keys)
            connectSignalling()
            startForegroundPolling()
            status = .ready
            broadcast()
            NotificationCenter.default.post(name: .stolnkRegistrationDidChange, object: nil)
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /// 名字是否可用。问不到时返回 nil —— 永远不要把「问不出来」渲染成「已被占用」。
    func isNameAvailable(_ candidate: String) async -> Bool? {
        guard let api else { return nil }
        return try? await api.nameAvailable(NameRules.normalise(candidate))
    }

    /**
     改名。

     名字属于设备而不属于某一条 inbox，所以这台设备名下所有地址和分享链接跟着一起
     搬家——服务端一条 `UPDATE devices` 就够了（worker `devices.ts` 的 names 路由）。
     旧子域立刻停止解析，没有过渡跳转，旧名字当场回到公共池。

     不碰注册：这里和 `setOrigin` 只有一字之差的表象，实质完全相反。换服务器必须
     `forgetDevice()`，因为那边签的 token、那边的 inbox id 到这边一文不值；改名根本
     没换服务器，设备 ID、token、密钥、文件夹绑定全都照旧成立，清掉任何一样都是白白
     把用户踢回 onboarding。

     不重拉 `/inboxes`：服务端已经把新名字下的整份列表一并返回了，理由和 `register`
     里那条一样。`throws` 的理由和 `setSlug` 一样——调用方要把「这个名字被占了」和
     别的错分开讲。
     */
    func rename(to chosen: String) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            let normalised = NameRules.normalise(chosen)
            let list = try await api.rename(to: normalised)
            name = normalised
            inboxes = list
            store.mutate {
                $0.name = normalised
                $0.inboxes = list
            }
            broadcast()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    // MARK: - 接收

    private func buildReceiver(api: APIClient, keys: DeviceIdentity) {
        let events = ReceiverEvents(
            progress: { [weak self] _, received, total in
                Task { @MainActor [weak self] in
                    guard let self, total > 0 else { return }
                    let fraction = Double(received) / Double(total)
                    self.status = fraction >= 1 ? .ready : .receiving(progress: fraction)
                    self.broadcast()
                }
            },
            landed: { [weak self] files in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recent = self.store.snapshot.recent
                    self.status = .ready
                    self.broadcast()
                    NotificationCenter.default.post(
                        name: .stolnkDidLandFiles, object: nil, userInfo: ["files": files])
                }
            },
            failed: { [weak self] _, _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status = .ready
                    self.handle(error)
                    self.broadcast()
                }
            },
            inboxUnavailable: { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status = .paused
                    await self.refreshInboxes()
                    self.broadcast()
                }
            }
        )
        receiver = Receiver(api: api, identity: keys, store: store, events: events)
    }

    private func connectSignalling() {
        signalling?.stop()
        let client = SignallingClient(
            urlProvider: { [weak self] in
                guard let api = await self?.api else { return nil }
                return await api.signallingURL()
            },
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .signal:
                        // LAN 直传不在 iOS 上：发送方不在这台手机的网络里，
                        // 而 WebRTC 是 28 MB 的依赖。信令来了也没人接。
                        break
                    case .connected:
                        self.socketConnected = true
                        if case .receiving = self.status {} else { self.status = .ready }
                        self.broadcast()
                    case .disconnected:
                        self.socketConnected = false
                        if case .receiving = self.status {} else { self.status = .connecting }
                        self.broadcast()
                    case .fileReady:
                        await self.poll()
                    }
                }
            }
        )
        signalling = client
        client.start()
    }

    /**
     进前台时重建连接并拉一次。

     对应 Mac 的 `observeWake()`。iOS 在后台会静默掐死 WebSocket，所以这里是
     `reconnectNow()` 而不是「检查一下还活着吗」——回到前台时那条连接基本必死。
     */
    private func observeForeground() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRegistered else { return }
                self.signalling?.reconnectNow()
                await self.poll()
            }
        }
    }

    /**
     前台兜底轮询。

     Mac 上这是 300 秒的安全网。iOS 上它只在前台有意义——进后台后计时器不走，
     这正是 M2 要用 APNs 补上的那一段。socket 仍是主路径，这只是兜底。
     */
    private func startForegroundPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.poll() }
        }
    }

    func poll() async {
        guard let receiver else { return }
        await receiver.poll()
        if case .receiving = status {} else {
            status = socketConnected ? .ready : .connecting
        }
        // 刚落地的文件花掉了额度，顺路刷新，免得配额显示滞后一个周期。
        await refreshPlan()
        broadcast()
    }

    // MARK: - 服务端状态

    func refreshInboxes() async {
        guard let api else { return }
        do {
            let (currentName, list) = try await api.inboxes()
            name = currentName
            inboxes = list
            store.mutate {
                $0.name = currentName
                $0.inboxes = list
            }
            if list.allSatisfy({ $0.paused }), !list.isEmpty { status = .paused }
            broadcast()
        } catch {
            handle(error)
        }
    }

    /// 失败不报错：配额是顺路刷新的，为它弹一个错会盖住真正的操作结果。
    func refreshPlan() async {
        guard let api else { return }
        if let state = try? await api.plan() {
            plan = state
            broadcast()
        }
    }

    /// Sends an opaque StoreKit transaction id to the Worker. The Worker asks
    /// Apple for the authoritative product, bundle and refund state before it
    /// changes this device's entitlement.
    func verifyApplePurchase(transactionID: UInt64) async throws -> PlanState {
        guard let api else { throw Self.notRegistered }
        do {
            let state = try await api.verifyApplePurchase(transactionID: transactionID)
            plan = state
            broadcast()
            return state
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    // MARK: - 外发下载链接

    /**
     刷新链接列表。

     和 `refreshInboxes` 一样失败不报错：它在每次进前台、每次建/删链接之后顺路跑，
     为它弹一个错会盖住用户真正在做的那件事。

     不用服务端返回的 name 覆盖本地的：`inboxes()` 已经在管这件事，两处都写只会让
     「哪一次的答案是对的」取决于谁后回来。
     */
    func refreshShares() async {
        guard let api else { return }
        do {
            let (_, list) = try await api.shares()
            shares = list
            store.mutate { $0.shares = list }
            broadcast()
        } catch {
            handle(error)
        }
    }

    /**
     把一个本地文件变成一条公开的下载链接。

     `throws` 而不是返回 Bool：调用方要把 402（档位不够）、409（路径被占）和 413
     （空间满了）分成三句不同的话讲，而 `lastError` 那条通道会把它们压成同一句。

     返回 `ShareHandle` 而不是 Bool：链接在**上传完成之前**就已经存在（`POST /shares`
     在传第一个字节前就返回了 url），调用方要拿它去写剪贴板——而 `UIPasteboard` 加
     `PaperToast` 需要一个 view，那是页面的事，不是这里的事。

     没有 `startAccessingSecurityScopedResource`：文件来自 `LocalDriveStore`，就在
     本 App 自己的 Documents 里。Mac 端要那一步是因为它的文件是 `NSOpenPanel` 授权
     进来的，iOS 这条路上没有那回事。
     */
    func createShare(
        file: URL, ttlHours: Double, maxDownloads: Int?, password: String?, code: String?
    ) async throws -> ShareHandle {
        guard let api else { throw Self.notRegistered }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let filename = values.name ?? file.lastPathComponent
            let size = values.fileSize ?? 0

            // 发出去的是 PBKDF2 派生出来的 verifier，不是密码本身。盐由服务端给，
            // 因为下载页的浏览器要用同一个盐算出同一个 verifier。
            var verifier: String?
            var salt: String?
            if let password, !password.isEmpty {
                let parameters = try await api.shareSalt()
                salt = parameters.salt
                verifier = try await SharePassword.derive(
                    password, salt: parameters.salt, iterations: parameters.iterations)
            }

            let handle = try await api.createShare(
                filename: filename, size: size, ttlHours: ttlHours, maxDownloads: maxDownloads,
                password: verifier, passwordSalt: salt, code: code.map(ShareCodeRules.normalise))

            try await upload(handle, from: file, filename: filename)
            await refreshShares()
            return handle
        } catch {
            shareUpload = nil
            handle(error)
            broadcast()
            throw error
        }
    }

    /**
     把一条已经结束的链接重新填满，地址不变。

     服务端只接受终态的行，且 `complete` 会拿旧的 sha256 校验——传错文件会被挡回来，
     所以这里不做本地比对：服务端的判断是准的，而本地的猜测不是。
     */
    func restoreShare(_ share: ShareSummary, from file: URL) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            let handle = try await api.restoreShare(share.shareID)
            try await upload(handle, from: file, filename: share.filename)
            await refreshShares()
        } catch {
            shareUpload = nil
            handle(error)
            broadcast()
            throw error
        }
    }

    /**
     上传字节，然后记住这条链接是从哪个文件来的。

     进度广播必须节流。`broadcast()` 是 `NotificationCenter` 广播，四个页面都在听；
     而 `uploadShare` 的 `onProgress` 跟着 `didSendBodyData` 走，一秒能回几百次。
     所以 `fraction` 每次都更新（进度条自己读得到），但只有取整后的百分比变了才广播。

     绑定放在上传**之后**：一条没传完的链接不该留下「它来自这个文件」的记录，那会让
     「恢复」按钮出现在一个根本没生效过的链接上。
     */
    private func upload(_ handle: ShareHandle, from file: URL, filename: String) async throws {
        shareUpload = ShareUpload(shareID: handle.shareID, filename: filename, fraction: 0)
        shareUploadPercent = 0
        broadcast()

        // `guard let self` 落在外层闭包里而不是 Task 里：`[weak self]` 捕获的是一个
        // 可变的可选绑定，让内层并发闭包再去读它，在 Swift 6 下是错误。先解成一个
        // 不可变的强引用，内层捕获的就是它。
        let shareID = handle.shareID
        try await api?.uploadShare(handle, from: file) { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.advance(shareID, to: fraction) }
        }

        store.bindSource(shareID: handle.shareID, to: file)
        shareUpload = nil
    }

    /// 进度回调的落点。单独一个方法，好让上面那句 `Task { @MainActor in }` 只剩一行。
    private func advance(_ shareID: String, to fraction: Double) {
        guard shareUpload?.shareID == shareID else { return }
        shareUpload?.fraction = fraction
        let percent = Int(fraction * 100)
        guard percent != shareUploadPercent else { return }
        shareUploadPercent = percent
        broadcast()
    }

    /// `nil` 表示问不出来，绝不是答「已被占用」。和 `isNameAvailable` 同形。
    ///
    /// 改路径时必须带上 `forShare`：一条链接占着自己的路径，不排除它自己，服务端
    /// 会对着提问的那一行答「已被占用」。
    func isShareCodeAvailable(_ candidate: String, forShare shareID: String? = nil) async -> Bool? {
        guard let api else { return nil }
        return try? await api.shareCodeAvailable(
            ShareCodeRules.normalise(candidate), forShare: shareID)
    }

    /// 换路径。旧链接当场失效。`throws` 的理由和 `setSlug` 相同：调用方要把
    /// 「这个路径被占了」和别的错分开讲。
    func setShareCode(_ share: ShareSummary, code: String) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            _ = try await api.updateShareCode(share.shareID, code: ShareCodeRules.normalise(code))
            await refreshShares()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /// 暂停 / 恢复。调用方是一个开关，失败要把它退回去，所以返回 Bool。
    func setSharePaused(_ share: ShareSummary, paused: Bool) async -> Bool {
        guard let api else { return false }
        do {
            _ = try await api.setSharePaused(share.shareID, paused: paused)
            await refreshShares()
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /// 撤回：删掉文件，但留着记录和它占的路径。不可撤销——没有字节可以再打开了。
    func revokeShare(_ share: ShareSummary) async -> Bool {
        guard let api else { return false }
        do {
            try await api.revokeShare(share.shareID)
            await refreshShares()
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /// 删除整条记录，路径一并释放。
    ///
    /// 同时解绑源文件，理由和 `deleteInbox` 调 `store.unbind(inboxID:)` 相同：
    /// 记录没了就再没有东西引用这条绑定，留着只是 state.json 里的一行垃圾。
    func deleteShare(_ share: ShareSummary) async -> Bool {
        guard let api else { return false }
        do {
            try await api.deleteShare(share.shareID)
            store.unbindSource(shareID: share.shareID)
            await refreshShares()
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /// 这条链接当初是从哪个文件来的。`nil` 是正常答案——文件可能已经被删了。
    func shareSource(for share: ShareSummary) -> URL? { store.source(for: share.shareID) }

    /**
     恢复接收。

     `Receiver` 在落地目录够不到时会把 inbox 暂停（PRD 12.5 —— 宁可暂停也不要把
     文件放到用户没选的地方）。暂停是服务端状态，没有任何东西会自动解除它，所以
     必须有一个人工出口：否则一次瞬时故障就让这条地址在用户眼里永久废掉。

     同时清掉 `Receiver` 自己的暂停备忘，不然它记得「这个 inbox 我已经报过了」，
     下一个文件还是会把它重新按回暂停。
     */
    func resume(_ inbox: InboxSummary) async -> Bool {
        guard let api else { return false }
        do {
            _ = try await api.updateInbox(inbox.inboxID, paused: false)
            await receiver?.clearPauseMemo(for: inbox.inboxID)
            await refreshInboxes()
            await poll()
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /**
     给一个文件夹取一条收件地址。

     路径在这里才出现，而不是在 onboarding：它是给这个文件夹取的名字，没有文件夹
     的时候根本无话可说。创建和绑定是一步：一条没绑定落地目录的地址收到文件只会
     把自己暂停（`Receiver.prepare`，PRD 12.5），那是个没人想要的中间态。

     `throws` 而不是返回 Bool：调用方要分开处理 402（免费版只能有一条）和 400
     （路径被占），而 `lastError` 那条通道会把两者压成同一句话。报错前先过一道
     `handle(_:)`，否则会漏掉它对 `unknown_device` 的处理。
     */
    func createInbox(slug: String, displayName: String, folder: URL) async throws -> InboxSummary {
        guard let api else { throw Self.notRegistered }
        do {
            let inbox = try await api.createInbox(
                slug: PathRules.normalise(slug), displayName: displayName)
            store.bind(inboxID: inbox.inboxID, to: folder)
            await refreshInboxes()
            return inbox
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    // MARK: - 改一条地址

    /**
     暂停 / 恢复。

     恢复不自己实现，转发给 `resume(_:)`：那条路除了调接口还清了 `Receiver` 的暂停
     备忘并补了一次 `poll()`，少任何一样这条地址都会在下一个文件到达时被重新按回
     暂停。理由见 `resume` 自己的注释。
     */
    func setPaused(_ inbox: InboxSummary, paused: Bool) async -> Bool {
        guard paused else { return await resume(inbox) }
        guard let api else { return false }
        do {
            _ = try await api.updateInbox(inbox.inboxID, paused: true)
            await refreshInboxes()
            return true
        } catch {
            handle(error)
            broadcast()
            return false
        }
    }

    /**
     换路径。

     旧地址立刻失效，服务端不留过渡期（见 worker `inboxes.ts` 的 reset 注释）。
     `throws` 的理由和 `createInbox` 相同：调用方要把「这个路径被占了」和别的错分开讲。
     */
    func setSlug(_ inbox: InboxSummary, slug: String) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            _ = try await api.updateInbox(inbox.inboxID, slug: PathRules.normalise(slug))
            await refreshInboxes()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /// 发件人在上传页看到的名字。和地址无关——地址是「名字 + 路径」，两半都在别处改。
    func setDisplayName(_ inbox: InboxSummary, to value: String) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            _ = try await api.updateInbox(
                inbox.inboxID, displayName: DisplayNameRules.normalise(value))
            await refreshInboxes()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /// 换一条随机路径。只有路径变——名字是设备身份，重置一条地址从来不是改它的理由。
    func resetInbox(_ inbox: InboxSummary) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            _ = try await api.resetInbox(inbox.inboxID)
            await refreshInboxes()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /**
     忘掉这条地址上已完成的传输记录，地址本身留着。

     返回清掉的条数：iOS 没有历史页，这个数字是该操作唯一看得见的反馈。已经落地的
     文件在磁盘上，这里碰都不碰。
     */
    func clearTransfers(_ inbox: InboxSummary) async throws -> Int {
        guard let api else { throw Self.notRegistered }
        do {
            let cleared = try await api.clearInboxTransfers(inbox.inboxID)
            await refreshInboxes()
            return cleared
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /**
     删掉一条地址。

     服务端会级联掉它的传输记录和还停在中转站的文件，路径随之释放。本地的文件夹
     绑定必须一起解开：它以 inbox id 为键，而那个 id 已经不存在了，留着只会让下一条
     恰好复用该 id 的地址继承一个谁也没选过的落地目录。`store` 是 private，所以这件事
     只能在这里做。
     */
    func deleteInbox(_ inbox: InboxSummary) async throws {
        guard let api else { throw Self.notRegistered }
        do {
            try await api.deleteInbox(inbox.inboxID)
            store.unbind(inboxID: inbox.inboxID)
            await receiver?.clearPauseMemo(for: inbox.inboxID)
            await refreshInboxes()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    private static var notRegistered: APIError {
        APIError(status: 0, code: "no_device", message: "还没有注册。")
    }

    func folder(for inboxID: String) -> URL? { store.folder(for: inboxID) }

    func bind(inboxID: String, to folder: URL) { store.bind(inboxID: inboxID, to: folder) }

    // MARK: - 服务器地址

    /// 生产环境的 apex。inbox 链接在它下面一级。
    static let productionOrigin = URL(string: "https://stolnk.com")!

    /// 开发机上的 Worker。真机够不到 `localhost`，所以用构建阶段注入的 LAN 地址。
    static var localOrigin: URL { URL(string: "http://\(BuildLAN.host):5173")! }

    var isDefaultOrigin: Bool {
        let state = store.snapshot
        return state.scheme == StoredState.defaultScheme
            && state.baseHost == StoredState.defaultBaseHost
    }

    /**
     换服务器。

     必然连带丢掉注册：一台在 localhost 上注册过的设备对生产环境毫无意义，
     文件夹绑定的键是那边的 inbox id，token 也是那边签的。留着任何一样都会让
     下一次启动带着无效状态去认证。密钥留着——它不属于任何一台服务器。
     */
    func setOrigin(_ url: URL) {
        guard let scheme = url.scheme, let host = url.host else { return }
        let port = url.port.map { ":\($0)" } ?? ""
        forgetDevice()
        store.mutate {
            $0.scheme = scheme
            $0.baseHost = host + port
        }
        Task { await start() }
    }

    func resetOrigin() {
        setOrigin(
            URL(string: "\(StoredState.defaultScheme)://\(StoredState.defaultBaseHost)")!)
    }

    private func persistToken() async {
        guard let api else { return }
        let token = await api.currentToken
        store.mutate { $0.token = token }
    }

    // MARK: - 错误

    func handle(_ error: Error) {
        if let apiError = error as? APIError, apiError.code == "unknown_device" {
            forgetDevice()
            return
        }
        lastError = error.localizedDescription
    }

    /**
     丢掉这台手机的注册，回到首次运行。

     Secure Enclave 里的密钥留着：没有任何东西把一把公钥绑死到某一行设备记录，
     拿同一把密钥重新注册是合法的。文件夹绑定不能留——它们以 inbox id 为键，
     而那些 inbox 随设备一起没了。

     生产环境不该发生；开发环境每次重置本地 D1 都会触发，而那正是「卡住且无路可走」
     代价最高的时候。
     */
    func forgetDevice() {
        store.mutate { state in
            state.deviceID = nil
            state.token = nil
            state.name = nil
            state.inboxes = []
            state.shares = []
            state.folders = [:]
            // 和 folders 同理：键是那边的 share id，设备一没，这些绑定就只是
            // state.json 里指着一个再也对不上任何链接的文件。
            state.sources = [:]
            state.hasCompletedOnboarding = false
        }
        api = nil
        receiver = nil
        signalling?.stop()
        signalling = nil
        pollTimer?.invalidate()
        pollTimer = nil
        inboxes = []
        shares = []
        shareUpload = nil
        name = nil
        status = .offline
        broadcast()
        NotificationCenter.default.post(name: .stolnkRegistrationDidChange, object: nil)
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .stolnkStateDidChange, object: nil)
    }
}
