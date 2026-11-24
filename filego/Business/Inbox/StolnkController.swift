import Foundation
import StolnkCore
import StolnkLAN
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
    /// 在途文件（`StolnkController.incoming`）增、删，或某一条的整数百分比变了。
    static let stolnkIncomingDidChange = Notification.Name("stolnk.incoming-did-change")
    /// 非会员的自定义子域名到期，服务端释放了名字，设备暂时没有可用地址。
    static let stolnkAddressDidExpire = Notification.Name("stolnk.address-did-expire")
}

/**
 一个正在路上的文件：目标文件夹里那个半透明的占位。

 两段拼成一根进度条——对方上传占前一半，本机下载占后一半。上传段只能按 64 MiB
 的 part 前进（浏览器自己也只知道这么细），下载段按字节走。
 */
struct IncomingTransfer: Equatable, Sendable {
    let fileID: String
    let name: String
    let size: Int
    let folder: URL
    /// 对方已传到中转的比例，0…1。
    var uploadFraction: Double
    /// 本机已写下的明文字节。nil 表示还在上传段。
    var downloadedBytes: Int?
    /// 局域网直传：没有「对方上传到中转」那一段，整根进度条都是本机接收。
    var isDirect = false

    var overall: Double {
        if isDirect {
            return min(1, Double(downloadedBytes ?? 0) / Double(max(size, 1)))
        }
        if let downloadedBytes {
            return 0.5 + 0.5 * min(1, Double(downloadedBytes) / Double(max(size, 1)))
        }
        return 0.5 * min(1, uploadFraction)
    }

    var percent: Int { Int(overall * 100) }
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
    /// 建 `LanReceiver` 时复用：直传落地和中转落地走同一套回调。
    private var receiverEvents: ReceiverEvents?
    /**
     PRD 8.2 的应答方。和 Mac 端 `AppState.lanReceiver` 同一个写法、同一个理由：
     只在主线程写，但 signalling 的回调要在跳上主线程**之前**读它——offer 的 payload
     是 JSON 字典，跨不过 actor 边界，协商也在跟发送页的超时赛跑。`LanReceiver`
     自己加锁。
     */
    private nonisolated(unsafe) var lanReceiver: LanReceiver?
    private var identityKeys: DeviceIdentity?
    private var pollTimer: Timer?
    private var socketConnected = false
    private var isStarting = false
    private var hasObservedForeground = false

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

    /// 在途文件，以 file id 为键。只在内存里：App 重开后靠 `/incoming` 和
    /// `/pending` 重新拼出来，持久化只会留下永远走不完的占位。
    private(set) var incoming: [String: IncomingTransfer] = [:]

    /// 上传进度。`fraction` 是整个文件的 0…1，不是单个 part 的。
    struct ShareUpload: Sendable {
        let shareID: String
        let filename: String
        var fraction: Double
    }

    /**
     专属接收文件夹（`Documents/Received`）。由 `AppEnvironment` 在启动时设好。

     单一收件地址之后每台设备只有一个 inbox，它永远落在这里——不再有「给某个文件夹
     取一条地址」这回事，所以绑定也不再是用户的操作，而是这里自己维持的不变量。
     */
    var receiveFolder: URL?

    /// 这台设备唯一的收件地址。服务端只返回一个；旧服务端若返回多个，取第一个。
    var inbox: InboxSummary? { inboxes.first }

    /// 没有 deviceID 就是还没注册过——onboarding 的唯一判据。
    var isRegistered: Bool { store.snapshot.deviceID != nil }

    /// `.stolnk.com`，name 输入框后面跟着的那截。
    var nameSuffix: String { SiteAddress.suffix(baseHost: store.snapshot.baseHost) }

    /// `https://ryan.stolnk.com/~`，下载链接路径输入框前面钉着的那截。还没注册时为 nil。
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
        let saved = store.snapshot
        self.recent = saved.recent
        self.inboxes = saved.inboxes
        self.shares = saved.shares
        self.name = saved.name
    }

    // MARK: - 启动

    /**
     取密钥、恢复会话、装配接收链路。

     密钥失败和网络失败分开 catch，理由和 Mac 端相同：两者的补救动作完全不同，
     合在一起会让「拿不到密钥」表现成「离线」，用户看不出该做什么。
     */
    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        recent = store.snapshot.recent
        inboxes = store.snapshot.inboxes
        shares = store.snapshot.shares
        name = store.snapshot.name

        let keys: DeviceIdentity
        do {
            keys = try DeviceIdentity.loadOrCreate()
        } catch {
            AppLogger.error("StolnkController 加载设备密钥失败", error: error)
            lastError = error.localizedDescription
            status = .offline
            observeForeground()
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
                await refreshIncoming()
                await poll()
                startForegroundPolling()
            }
        } catch {
            AppLogger.error("StolnkController 启动认证失败（origin=\(origin.absoluteString)）", error: error)
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

     只上行名字：服务端注册时自动建好唯一的根 inbox（`<name>.stolnk.com`），注册完
     拉一次 `/inboxes` 把它绑到接收文件夹上。
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
            store.mutate { state in
                state.deviceID = result.deviceID
                state.name = result.name
                state.token = result.token
                state.inboxes = []
                state.hasCompletedOnboarding = true
            }

            buildReceiver(api: client, keys: keys)
            // 根 inbox 是服务端注册时建的，拉回来绑到接收文件夹，顺带拿到套餐与子域名期限。
            await refreshInboxes()
            await refreshPlan()
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

     不重拉 `/inboxes`：服务端已经把新名字下的整份列表一并返回了。`throws`：调用方要把
     「这个名字被占了」和别的错分开讲。改完刷新套餐——新名字的过期时间（非会员 7 天）
     在 `PlanState.nameExpiresAt` 里。
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
            bindReceiveFolder()
            await refreshPlan()
            broadcast()
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /// 删除账号（App Store 5.1.1(v)）。设备就是账号：服务端删掉设备，名字、地址、
    /// 链接和还停在中转里的文件一起没了。本机已落地的文件不动——那是用户自己的。
    /// 成功后走 `forgetDevice()`，根界面随注册通知换回 onboarding。
    func deleteAccount() async throws {
        guard let api else { throw Self.notRegistered }
        do {
            try await api.deleteDevice()
        } catch let error as APIError where error.code == "unknown_device" {
            // 服务端已经不认识这台设备，要的结果已经成立。
        }
        forgetDevice()
    }

    // MARK: - 接收

    private func buildReceiver(api: APIClient, keys: DeviceIdentity) {
        let events = ReceiverEvents(
            progress: { [weak self] fileID, received, total in
                Task { @MainActor [weak self] in
                    guard let self, total > 0 else { return }
                    let fraction = Double(received) / Double(total)
                    self.status = fraction >= 1 ? .ready : .receiving(progress: fraction)
                    self.broadcast()
                    self.advanceDownload(fileID, to: received)
                }
            },
            landed: { [weak self] files in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recent = self.store.snapshot.recent
                    self.status = .ready
                    self.broadcast()
                    // 一般早在 `advanceDownload` 走到 100% 时就摘掉了，这里兜底。
                    self.removeIncoming(files.map(\.id))
                    NotificationCenter.default.post(
                        name: .stolnkDidLandFiles, object: nil, userInfo: ["files": files])
                }
            },
            failed: { [weak self] file, _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status = .ready
                    self.handle(error)
                    self.broadcast()
                    self.removeIncoming([file.fileID])
                }
            },
            inboxUnavailable: { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status = .paused
                    await self.refreshInboxes()
                    self.broadcast()
                }
            },
            started: { [weak self] file, name, folder in
                Task { @MainActor [weak self] in
                    self?.beginDownload(file, name: name, folder: folder)
                }
            }
        )
        receiver = Receiver(api: api, identity: keys, store: store, events: events)
        receiverEvents = events
    }

    // MARK: - 在途文件（占位）

    /// 某个文件夹里正在路上的文件，按名字排。列表把它们固定放在最前。
    func incoming(in folder: URL) -> [IncomingTransfer] {
        let here = folder.standardizedFileURL
        return incoming.values
            .filter { $0.folder.standardizedFileURL == here }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /**
     对方开始上传，或者 `/incoming` 里补回来的一条。

     找不到落地目录就不显示：这条地址会在文件真正到来时被 `Receiver` 暂停
     （PRD 12.5），为一个不会落地的文件画占位只会误导。已经在下载段的不回退。
     */
    private func announce(_ file: IncomingFile) {
        guard incoming[file.fileID]?.downloadedBytes == nil,
              let keys = identityKeys,
              let folder = store.folder(for: file.inboxID),
              let name = try? Receiver.displayName(of: file, identity: keys)
        else { return }
        let fraction = file.cipherSize > 0 ? Double(file.uploaded) / Double(file.cipherSize) : 0
        setIncoming(IncomingTransfer(
            fileID: file.fileID, name: name, size: file.size, folder: folder,
            uploadFraction: fraction, downloadedBytes: nil))
    }

    private func advanceUpload(_ fileID: String, uploaded: Int, total: Int) {
        guard var entry = incoming[fileID] else {
            // 错过了 `file.incoming`（比如那一刻 socket 正在重连），问一次全量。
            Task { await refreshIncoming() }
            return
        }
        guard entry.downloadedBytes == nil, total > 0 else { return }
        entry.uploadFraction = Double(uploaded) / Double(total)
        setIncoming(entry)
    }

    /// 局域网直传开始。名字和目录同样来自 `Receiver.prepare`。
    private func beginDirect(_ file: PendingFile, name: String, folder: URL) {
        setIncoming(IncomingTransfer(
            fileID: file.fileID, name: name, size: file.size, folder: folder,
            uploadFraction: 1, downloadedBytes: 0, isDirect: true))
    }

    /// 名字和目录以 `Receiver` 为准：它刚刚真的解开了信封、找到了文件夹。
    private func beginDownload(_ file: PendingFile, name: String, folder: URL) {
        setIncoming(IncomingTransfer(
            fileID: file.fileID, name: name, size: file.size, folder: folder,
            uploadFraction: 1, downloadedBytes: 0))
    }

    /**
     下载段前进。

     走到头就摘掉占位：`land` 在报最后这一次之前已经把文件挪到了正式名字下，此刻
     列表重读磁盘就能看到它。不等 `landed`——那是整轮 `poll` 结束才一次性发的，
     同一轮里先到的文件不该陪着后面的一起挂在 100%。
     */
    private func advanceDownload(_ fileID: String, to received: Int) {
        guard var entry = incoming[fileID] else { return }
        if received >= entry.size {
            removeIncoming([fileID])
            return
        }
        entry.downloadedBytes = received
        setIncoming(entry)
    }

    /**
     拉一次 `/incoming` 对账。

     不在列表里的上传段条目删掉——它要么被取消了，要么已经传完进了 `/pending`。后者
     的例外是已经传满的（`uploadFraction >= 1`）：它马上会被 `poll` 接走，删了再加
     会闪一下。下载段的条目不归这里管，它们的结局由 `Receiver` 报。
     */
    func refreshIncoming() async {
        guard let api, let files = try? await api.incoming() else { return }
        let listed = Set(files.map(\.fileID))
        let stale = incoming.values
            .filter { $0.downloadedBytes == nil && $0.uploadFraction < 1 && !listed.contains($0.fileID) }
            .map(\.fileID)
        removeIncoming(stale)
        for file in files { announce(file) }
    }

    /// 写入一条，只有增删或整数百分比变了才广播，理由同 `advance(_:to:)`。
    private func setIncoming(_ entry: IncomingTransfer) {
        let previous = incoming.updateValue(entry, forKey: entry.fileID)
        guard previous?.percent != entry.percent else { return }
        NotificationCenter.default.post(name: .stolnkIncomingDidChange, object: nil)
    }

    private func removeIncoming(_ fileIDs: [String]) {
        let removed = fileIDs.compactMap { incoming.removeValue(forKey: $0) }
        guard !removed.isEmpty else { return }
        NotificationCenter.default.post(name: .stolnkIncomingDidChange, object: nil)
    }

    private func connectSignalling() {
        signalling?.stop()
        lanReceiver?.stopAll()
        let client = SignallingClient(
            urlProvider: { [weak self] in
                guard let api = await self?.api else { return nil }
                return await api.signallingURL()
            },
            onEvent: { [weak self] event in
                // 在跳主线程之前处理：理由见 `lanReceiver` 的注释。
                if case .signal(let session, let payload) = event {
                    self?.lanReceiver?.handle(session: session, payload: payload)
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .signal:
                        break  // 上面已经处理。
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
                    case .fileIncoming(let file):
                        self.announce(file)
                    case .fileUploadProgress(let fileID, let uploaded, let total):
                        self.advanceUpload(fileID, uploaded: uploaded, total: total)
                    case .fileCancelled(let fileID):
                        self.lanReceiver?.cancel(fileID: fileID)
                        self.removeIncoming([fileID])
                    }
                }
            }
        )
        signalling = client

        /*
         PRD 8.2 —— 局域网直传，挂在同一条 socket 上。

         共用 `Receiver`：从 DataChannel 来的文件和从中转拉的文件，由同一段代码
         净化文件名、找目录、原子落地、ACK。区别只在字节从哪里来。
         */
        if let receiver, let api, let events = receiverEvents {
            lanReceiver = LanReceiver(
                receiver: receiver,
                api: api,
                answer: { [weak client] session, payload in
                    client?.sendSignal(session: session, payload: payload)
                },
                onLanded: { landed in events.landed(landed) },
                onStarted: { [weak self] file, name, folder in
                    Task { @MainActor [weak self] in
                        self?.beginDirect(file, name: name, folder: folder)
                    }
                },
                // 走中转那条进度回调：状态栏的「接收中」和占位进度一起更新。
                onProgress: { fileID, written, total in events.progress(fileID, written, total) },
                onEnded: { [weak self] fileID in
                    Task { @MainActor [weak self] in self?.removeIncoming([fileID]) }
                }
            )
        }

        client.start()
    }

    /**
     进前台时重建连接并拉一次。

     对应 Mac 的 `observeWake()`。iOS 在后台会静默掐死 WebSocket，所以这里是
     `reconnectNow()` 而不是「检查一下还活着吗」——回到前台时那条连接基本必死。
     */
    private func observeForeground() {
        guard !hasObservedForeground else { return }
        hasObservedForeground = true
        /*
         进后台就把直传断掉。系统很快会掐掉 socket 和 DataChannel，与其留一个
         不会再有字节进来的 `.part` 和一个永远停在半截的占位，不如现在干净地收掉；
         发送页看到通道关闭会回落中转。
         */
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lanReceiver?.stopAll() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRegistered else { return }
                // 卸载重装首次启动时，iOS 的“无线数据/本地网络”系统弹窗会先让 start()
                // 里的 authenticate() 失败。用户点允许后系统触发 didBecomeActive，此时
                // receiver/signalling 尚未装配，重新跑一遍 start() 就能自动恢复。
                if self.receiver == nil || self.signalling == nil || self.status == .offline {
                    await self.start()
                    return
                }
                self.signalling?.reconnectNow()
                // 后台期间 socket 是死的，推送全丢了：先把在途的补回来，再接已传完的。
                await self.refreshIncoming()
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
        // 子域名到期后服务端的 cron 会释放名字、让地址失效。到点了就重拉一次，
        // 好让首页、「我的」和接收文件夹显示「已到期」而不是一个已经无效的地址。
        if let expiry = plan?.nameExpiryDate, expiry <= Date() {
            await refreshInboxes()
        }
        broadcast()
    }

    // MARK: - 服务端状态

    func refreshInboxes() async {
        guard let api else { return }
        do {
            let (currentName, list) = try await api.inboxes()
            let previous = name
            name = currentName
            // 没有地址时服务端返回空列表；设备本身还在，接收文件夹也还在。
            let live = currentName == nil ? [] : Array(list.prefix(1))
            inboxes = live
            store.mutate {
                $0.name = currentName
                $0.inboxes = live
            }
            bindReceiveFolder()
            if inbox?.paused == true { status = .paused }
            broadcast()
            // 从“有地址”变成“没有地址”：只可能是 7 天到期后服务端释放了名字。
            if previous != nil, currentName == nil {
                NotificationCenter.default.post(name: .stolnkAddressDidExpire, object: nil)
                await refreshPlan()
            }
        } catch {
            handle(error)
        }
    }

    /// 失败不报错：配额是顺路刷新的，为它弹一个错会盖住真正的操作结果。
    func refreshPlan() async {
        guard let api, let state = try? await api.plan() else { return }
        // 地址从“可用”变成“已失效”：服务端的清扫任务已经释放了名字。重拉一次地址，
        // 好把本机缓存的旧名字和 inbox 清掉——否则界面会继续显示一条 404 的地址。
        let wasActive = plan?.addressActive ?? true
        plan = state
        broadcast()
        if wasActive, state.addressActive == false {
            await refreshInboxes()
        }
    }

    /// 终身买断交易交给 Worker 回查 Apple。返回 Worker 判定后的套餐。
    func verifyLifetime(transactionID: UInt64) async throws -> PlanState {
        guard let api else { throw Self.notRegistered }
        do {
            let state = try await api.verifyLifetime(transactionID: transactionID)
            plan = state
            broadcast()
            return state
        } catch {
            handle(error)
            broadcast()
            throw error
        }
    }

    /// 旧版 $14.99 终身买断（已停售）。只用于恢复购买，走旧的校验接口。
    func verifyLegacyLifetime(transactionID: UInt64) async throws -> PlanState {
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

    /// 会员订阅交易交给 Worker 回查 Apple。返回 Worker 判定后的套餐。
    func verifySubscription(transactionID: UInt64) async throws -> PlanState {
        guard let api else { throw Self.notRegistered }
        do {
            let state = try await api.verifySubscription(transactionID: transactionID)
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

     `throws` 而不是返回 Bool：调用方要把 402（不是会员）、409（路径被占）和 413
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

    /// 换路径。旧链接当场失效。`throws`：调用方要把「这个路径被占了」和别的错分开讲。
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
    /// 同时解绑源文件：记录没了就再没有东西引用这条绑定，留着只是 state.json 里的一行垃圾。
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

    /// 发件人在上传页看到的名字。和地址无关——地址就是 `<name>.stolnk.com`。
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

    private static var notRegistered: APIError {
        APIError(status: 0, code: "no_device", message: "还没有注册。")
    }

    func folder(for inboxID: String) -> URL? { store.folder(for: inboxID) }

    /**
     把唯一的 inbox 绑到接收文件夹，并维持这个不变量。

     老数据迁移：旧版本里一个 inbox 可以绑到任意文件夹。服务端保留的那个 inbox 若绑在
     根目录下的某个子文件夹上、而 `Received` 还不存在，就把那个文件夹直接改名为
     `Received`——用户之前收到的东西原样跟过来。绑在根目录或 `Received` 已存在时只改绑，
     文件一律不动。其余 inbox 的绑定解开（服务端已经把它们退役了），原文件夹作为普通
     文件夹留着。
     */
    private func bindReceiveFolder() {
        guard let receiveFolder, let inbox else { return }
        let fm = FileManager.default
        let target = receiveFolder.standardizedFileURL
        let root = target.deletingLastPathComponent().standardizedFileURL

        if let old = store.folder(for: inbox.inboxID)?.standardizedFileURL,
           old != target,
           old.path.hasPrefix(root.path + "/"),
           !fm.fileExists(atPath: target.path) {
            do {
                try fm.moveItem(at: old, to: target)
                AppLogger.info("旧收件文件夹已迁移为接收文件夹：\(old.lastPathComponent)")
            } catch {
                AppLogger.error("迁移旧收件文件夹失败", error: error)
            }
        }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        if store.folder(for: inbox.inboxID)?.standardizedFileURL != target {
            store.bind(inboxID: inbox.inboxID, to: target)
        }
        for stale in store.snapshot.folders.keys where stale != inbox.inboxID {
            store.unbind(inboxID: stale)
        }
    }

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
        receiverEvents = nil
        lanReceiver?.stopAll()
        lanReceiver = nil
        signalling?.stop()
        signalling = nil
        pollTimer?.invalidate()
        pollTimer = nil
        inboxes = []
        shares = []
        shareUpload = nil
        removeIncoming(Array(incoming.keys))
        name = nil
        status = .offline
        broadcast()
        NotificationCenter.default.post(name: .stolnkRegistrationDidChange, object: nil)
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .stolnkStateDidChange, object: nil)
    }
}
