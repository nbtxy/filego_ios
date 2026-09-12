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

    /// 没有 deviceID 就是还没注册过——onboarding 的唯一判据。
    var isRegistered: Bool { store.snapshot.deviceID != nil }

    /// `.stolnk.com`，name 输入框后面跟着的那截。
    var nameSuffix: String { SiteAddress.suffix(baseHost: store.snapshot.baseHost) }

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

     `folder` 是这台手机上的落地目录，绑定只存在本地（服务端从不知道文件落在哪）。
     */
    func register(name chosen: String, slug: String, folder: URL) async -> Bool {
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
            let result = try await client.register(
                name: NameRules.normalise(chosen), slug: PathRules.normalise(slug))
            store.mutate { state in
                state.deviceID = result.deviceID
                state.name = result.name
                state.token = result.token
            }
            name = result.name

            let (_, list) = try await client.inboxes()
            if let first = list.first { store.bind(inboxID: first.inboxID, to: folder) }
            inboxes = list
            store.mutate {
                $0.inboxes = list
                $0.hasCompletedOnboarding = true
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
            state.folders = [:]
            state.hasCompletedOnboarding = false
        }
        api = nil
        receiver = nil
        signalling?.stop()
        signalling = nil
        pollTimer?.invalidate()
        pollTimer = nil
        inboxes = []
        name = nil
        status = .offline
        broadcast()
        NotificationCenter.default.post(name: .stolnkRegistrationDidChange, object: nil)
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .stolnkStateDidChange, object: nil)
    }
}
