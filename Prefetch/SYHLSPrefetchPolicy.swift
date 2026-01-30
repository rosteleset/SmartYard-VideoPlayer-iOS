import Foundation

enum SYHLSPrefetchNetworkClass {
    case wifi
    case cellular
    case constrained
    case other
    case unknown
}

struct SYHLSPrefetchPolicy {
    var maxConcurrentPrefetches: Int = 2
    var maxPrefetchItemsWiFi: Int = 4
    var maxPrefetchItemsCellular: Int = 1
    var allowInLowPowerMode: Bool = false

    /// Returns the maximum queued items for the current network class.
    func maxPrefetchItems(for network: SYHLSPrefetchNetworkClass) -> Int {
        switch network {
        case .wifi:
            return maxPrefetchItemsWiFi
        case .cellular, .constrained, .other, .unknown:
            return maxPrefetchItemsCellular
        }
    }

    /// Returns the maximum concurrent prefetches for the network class.
    func maxConcurrentPrefetches(for network: SYHLSPrefetchNetworkClass) -> Int {
        let maxItems = maxPrefetchItems(for: network)
        return min(maxConcurrentPrefetches, maxItems)
    }
}
