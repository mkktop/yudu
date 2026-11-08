import Foundation

/// 取消标记：Task 的取消状态无法跨线程直接查询，用带锁布尔承接 onCancel 回调。
nonisolated final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  /// 复位（新一轮工作开始前）
  func reset() {
    lock.withLock { cancelled = false }
  }
}

/// 页图的同步加载 / 解压 / 解码专用有界线程池。
///
/// 页源里有 `DispatchSemaphore` 桥接的同步网络调用（fetchDataSync / getSync / RangeFetcher），
/// 这些调用绝不能直接阻塞 Swift 并发的协作线程池，否则多页并发时会线程饥饿、优先级反转。
/// 这里用独立的 OperationQueue 承载阻塞，最多 3 个并发（前台 1 + 预取 1 + 尺寸 1）。
///
/// 取消语义：所属任务被取消时，还没开跑的入队操作直接短路跳过（返回 nil），
/// 把并发槽让给还需要的工作——快速连翻时过期的预取解码不会再堵住当前页。
/// 已经开跑的解码无法中断，会自然跑完（在跑最多 3 个，等待有界）。
nonisolated final class PageLoadExecutor: @unchecked Sendable {
  static let shared = PageLoadExecutor()

  private let queue: OperationQueue

  private init() {
    let queue = OperationQueue()
    queue.name = "com.mkk.yudu.page-load"
    queue.maxConcurrentOperationCount = 3
    self.queue = queue
  }

  /// 在专用线程上执行同步加载工作，异步返回结果。
  /// 返回 nil = 所属任务在排队期间被取消，操作没开跑就被跳过。
  func run<T>(priority: TaskPriority = .userInitiated, _ work: @escaping @Sendable () -> T?) async -> T? {
    let flag = CancelFlag()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let operation = BlockOperation()
        operation.addExecutionBlock { [flag] in
          if flag.isCancelled {
            continuation.resume(returning: nil)
            return
          }
          continuation.resume(returning: work())
        }
        let high = priority.rawValue >= TaskPriority.userInitiated.rawValue
        operation.qualityOfService = high ? .userInitiated : .utility
        operation.queuePriority = high ? .veryHigh : .low
        queue.addOperation(operation)
      }
    } onCancel: {
      flag.cancel()
    }
  }
}
