import Foundation
import StolnkCore

/**
 输入框里那个名字，眼下是什么状态。

 `unknown` 刻意不等于 `taken`：问不出来的名字绝不能渲染成「已被占用」——那是两件
 不同的事，用户要做的补救动作也不同。`unchanged` 同理，它不是一个可用性判断，
 而是「这个问题根本没问」：服务端对你自己的名字当然答「已被占用」，照着渲染就会
 在改名页上骗人。
 */
nonisolated enum NameStatus: Equatable {
    case empty
    case invalid
    /// 打回来的就是调用方已经持有的名字。
    case unchanged
    case checking
    case available
    case taken
    case unknown

    /**
     能不能按下提交。

     `checking` 拦着：答案马上就到，让用户在这半秒里打出去一个注定失败的请求没有
     意义。`unknown` 不拦：可用性接口是限流的（worker 那边 `RATE_MAX_RESOLVES`），
     问不出来就锁死按钮，等于在离线或被限流时把改名这条路整个封掉。真正的闸门在
     服务端——重名会以 409 挡回来，那是准确的，而这里的猜测不是。
     */
    var blocksSubmission: Bool {
        switch self {
        case .empty, .invalid, .unchanged, .taken, .checking: true
        case .available, .unknown: false
        }
    }
}

/**
 一个要在服务端保持唯一的名字：本地校验 + 防抖的可用性查询。

 抽出来是因为有多处要用——onboarding 取名字、改名页，以及外发下载链接的路径——而真正
 有分量的从来不是那次网络调用，是防抖、取消，以及「答案回来时输入框已经打到别的字了」
 这道守卫。Mac 端遇到同样的情形时抽成了 `AvailabilityField`，注释写着「按字段各抄一份
 就是它们开始走样的起点」。这里是同一个理由。

 规则用注入而不是写死：设备名走 `NameRules`，下载链接的路径走 `ShareCodeRules`
 （单段、3–32 位）。两者的防抖、取消和守卫一模一样，只有「什么算合法」不同——Mac 端
 的 `AvailabilityField` 同样是把 `normalise`/`problem` 作为闭包传进去的。默认值指向
 `NameRules`，所以原有的两个调用点一字不用改。
 */
@MainActor
final class NameAvailabilityProbe {
    /// 每敲一个字母打一次服务端，既费又会让结果乱序回来。
    private static let debounce = Duration.milliseconds(350)

    /// 调用方已经持有的名字。onboarding 是 nil，改名页是当前名字。
    /// 改名成功之后要跟着更新，否则「和现在一样」这个判断会停在旧名字上。
    var currentName: String?

    private(set) var status: NameStatus = .empty

    private let normalise: (String) -> String
    private let problem: (String) -> String?
    private let check: (String) async -> Bool?
    private let update: (NameStatus, String) -> Void
    private var probe: Task<Void, Never>?

    /// - Parameters:
    ///   - normalise: 把原始输入收拾成要提交的形状（去空白、转小写）。
    ///   - problem: 本地校验。返回非 nil 就是 `.invalid`——**只当闸门用，返回的文案
    ///     是未翻译的英文，不要渲染**（`ShareCodeRules.problem` 尤其如此）。
    ///   - check: 问服务端。`nil` 表示问不出来，不是答「不可用」。
    ///   - update: 状态变了就调一次，第二个参数是规范化之后的名字，方便文案引用它。
    init(
        currentName: String? = nil,
        normalise: @escaping (String) -> String = NameRules.normalise,
        problem: @escaping (String) -> String? = { NameRules.problem(with: $0) },
        check: @escaping (String) async -> Bool?,
        update: @escaping (NameStatus, String) -> Void
    ) {
        self.currentName = currentName
        self.normalise = normalise
        self.problem = problem
        self.check = check
        self.update = update
    }

    /// 输入框每次 `editingChanged` 调一次，传原始文本。
    func evaluate(_ raw: String) {
        probe?.cancel()
        let candidate = normalise(raw)

        if candidate.isEmpty { return settle(.empty, candidate) }
        if problem(candidate) != nil { return settle(.invalid, candidate) }
        if let currentName, candidate == currentName { return settle(.unchanged, candidate) }

        settle(.checking, candidate)
        probe = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let answer = await self.check(candidate)
            guard !Task.isCancelled else { return }
            self.settle(answer.map { $0 ? .available : .taken } ?? .unknown, candidate)
        }
    }

    func cancel() {
        probe?.cancel()
        probe = nil
    }

    private func settle(_ status: NameStatus, _ candidate: String) {
        self.status = status
        update(status, candidate)
    }
}
