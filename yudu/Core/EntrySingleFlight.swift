import Foundation

/// 同一页的尺寸探测与整图解码会并发请求同一份 zip 条目（条漫行的 requestDims
/// 不等待就发起 pageImage；打开章节时的 dims 探测也会与前台加载撞页）。
/// NSCache 并发 miss 的窗口里两条路径各自解压/下载同一页——远程源直接翻倍流量。
/// 单飞门让先到者做、后到者等：等待阻塞在解码线程池线程上，与网络桥接同一语义。
nonisolated final class EntrySingleFlight: @unchecked Sendable {
  private let lock = NSLock()
  private var inflight: [Int: Flight] = [:]

  /// 唤醒必须用条件变量的广播：同一航班可有任意多个等待者，
  /// 一次性 signal 只能唤醒一个，其余会永久挂起（解码线程池会被卡住）。
  private final class Flight: @unchecked Sendable {
    let condition = NSCondition()
    var data: Data?
    var done = false
  }

  /// 缓存命中直接返回；否则合并同 index 的并发请求，只执行一次 load。
  /// 先到的（leader）永远只做自己的那一单，不等待其他 index，无环即无死锁。
  func entryData(
    at index: Int, cache: NSCache<NSNumber, NSData>, load: () -> Data?
  ) -> Data? {
    let key = NSNumber(value: index)
    if let hit = cache.object(forKey: key) { return hit as Data }

    lock.lock()
    let flight: Flight
    let isLeader: Bool
    if let existing = inflight[index] {
      flight = existing
      isLeader = false
    } else {
      flight = Flight()
      inflight[index] = flight
      isLeader = true
    }
    lock.unlock()

    guard isLeader else {
      // leader 先标记 done 再摘除 inflight 条目：赶在两者之间到达的等待者
      // 直接拿到已就绪的结果，不会退化成重复加载
      flight.condition.lock()
      while !flight.done { flight.condition.wait() }
      let data = flight.data
      flight.condition.unlock()
      return data
    }
    let data = load()
    if let data {
      cache.setObject(data as NSData, forKey: key, cost: data.count)
    }
    flight.condition.lock()
    flight.data = data
    flight.done = true
    flight.condition.broadcast()
    flight.condition.unlock()
    lock.lock()
    if inflight[index] === flight { inflight.removeValue(forKey: index) }
    lock.unlock()
    return data
  }
}
