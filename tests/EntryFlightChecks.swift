import Foundation

/// 在 macOS 上验证 EntrySingleFlight 的并发语义：
/// 同 index 并发只加载一次、不同 index 互不阻塞（load 期间不持有全局锁）、
/// 失败（nil）不落缓存且等待者拿到 nil、缓存命中不再进 load。
@main
struct EntryFlightChecks {
  static func main() {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }

    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var n = 0
      func inc() { lock.withLock { n += 1 } }
      var value: Int { lock.withLock { n } }
    }

    func freshCache() -> NSCache<NSNumber, NSData> {
      let cache = NSCache<NSNumber, NSData>()
      cache.countLimit = 4
      cache.totalCostLimit = 16 << 20
      return cache
    }

    // 1. 同 index 16 路并发：load 只跑一次，所有调用方拿到同一份数据
    do {
      let flight = EntrySingleFlight()
      let cache = freshCache()
      let loads = Counter()
      let payload = Data("page-bytes".utf8)
      let group = DispatchGroup()
      let queue = DispatchQueue(label: "flight-check", attributes: .concurrent)
      for _ in 0..<16 {
        group.enter()
        queue.async {
          let data = flight.entryData(at: 7, cache: cache) {
            loads.inc()
            Thread.sleep(forTimeInterval: 0.05)
            return payload
          }
          precondition(data == payload, "等待者应拿到 leader 的结果")
          group.leave()
        }
      }
      group.wait()
      expect(loads.value == 1, "并发 16 路只允许一次加载，实际 \(loads.value)")
      // 再次请求：缓存命中，不进 load
      let hit = flight.entryData(at: 7, cache: cache) {
        loads.inc()
        return payload
      }
      expect(hit == payload && loads.value == 1, "缓存命中不应重新加载")
    }

    // 2. 不同 index 互不阻塞：index 0 的 load 卡住时，index 1 照常完成
    do {
      let flight = EntrySingleFlight()
      let cache = freshCache()
      let gate = DispatchSemaphore(value: 0)
      let slowDone = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        _ = flight.entryData(at: 0, cache: cache) {
          gate.wait() // 卡住直到测试放行
          return Data("slow".utf8)
        }
        slowDone.signal()
      }
      Thread.sleep(forTimeInterval: 0.15) // 让慢任务先成为 leader
      let fast = flight.entryData(at: 1, cache: cache) { Data("fast".utf8) }
      expect(fast == Data("fast".utf8), "其他 index 不应被慢 leader 阻塞")
      gate.signal()
      slowDone.wait()
    }

    // 3. 失败传播：leader 返回 nil，等待者也是 nil；nil 不落缓存，下次重跑
    do {
      let flight = EntrySingleFlight()
      let cache = freshCache()
      let loads = Counter()
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        _ = flight.entryData(at: 3, cache: cache) {
          loads.inc()
          started.signal()
          Thread.sleep(forTimeInterval: 0.1)
          return nil
        }
        finished.signal()
      }
      started.wait()
      let waiter = flight.entryData(at: 3, cache: cache) {
        loads.inc()
        return nil
      }
      expect(waiter == nil, "等待者应收到 leader 的 nil")
      finished.wait()
      let retry = flight.entryData(at: 3, cache: cache) {
        loads.inc()
        return Data("ok".utf8)
      }
      expect(retry == Data("ok".utf8) && loads.value == 2, "nil 不落缓存，重试应重跑 load")
    }

    print("Passed \(checks) EntrySingleFlight concurrency checks")
  }
}
