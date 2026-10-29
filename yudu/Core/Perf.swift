import os

/// 阅读器性能标记：Instruments 里按 subsystem/category 过滤 "reader"。
/// 用来量化打开耗时、页加载耗时、缓存命中率（配合真机 Instruments 使用）。
nonisolated enum Perf {
  nonisolated static let signposter = OSSignposter(subsystem: "com.mkk.yudu", category: "reader")
}
