import Foundation

/// 页图的同步加载 / 解压 / 解码专用有界线程池。
///
/// 页源里有 `DispatchSemaphore` 桥接的同步网络调用（fetchDataSync / getSync / RangeFetcher），
/// 这些调用绝不能直接阻塞 Swift 并发的协作线程池，否则多页并发时会线程饥饿、优先级反转。
/// 这里用独立的 OperationQueue 承载阻塞，最多 3 个并发（前台 1 + 预取 1 + 尺寸 1）。
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
  func run<T>(priority: TaskPriority = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
      let operation = BlockOperation()
      operation.addExecutionBlock {
        continuation.resume(returning: work())
      }
      let high = priority.rawValue >= TaskPriority.userInitiated.rawValue
      operation.qualityOfService = high ? .userInitiated : .utility
      operation.queuePriority = high ? .veryHigh : .low
      queue.addOperation(operation)
    }
  }
}
