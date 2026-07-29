import Foundation

/// 可取消、可重复调度的防抖任务。
final class DelayedTask {
    private var workItem: DispatchWorkItem?

    func schedule(after milliseconds: Int, task: @escaping @Sendable () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: task)
        workItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: item
        )
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    deinit {
        cancel()
    }
}
