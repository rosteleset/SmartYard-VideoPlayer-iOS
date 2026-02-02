import Foundation
import Network

final class SYHLSPrefetchController {
    nonisolated(unsafe) static let shared = SYHLSPrefetchController()

    var policy: SYHLSPrefetchPolicy {
        didSet {
            SYPlayerConfig.shared.log(
                "Prefetch policy updated",
                level: .info
            )
            workQueue.async { [weak self] in
                self?.applyPolicyLocked()
            }
        }
    }

    private let backend: SYHLSPrefetchBackend
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "sy.hls.prefetch.monitor", qos: .utility)
    private let workQueue = DispatchQueue(label: "sy.hls.prefetch.work", qos: .utility)

    private var powerObserver: NSObjectProtocol?
    private var networkClass: SYHLSPrefetchNetworkClass = .unknown
    private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var pending: [URL] = []
    private var pendingSet: Set<URL> = []
    private var inFlight: Set<URL> = []

    /// Creates a prefetch controller with a backend and policy.
    init(
        backend: SYHLSPrefetchBackend = SYKTVHLSPrefetchBackend(),
        policy: SYHLSPrefetchPolicy = SYHLSPrefetchPolicy()
    ) {
        self.backend = backend
        self.policy = policy
        self.monitor = NWPathMonitor()
        SYPlayerConfig.shared.log("Prefetch controller init", level: .debug)
        startMonitoring()
        observePowerState()
    }

    deinit {
        monitor.cancel()
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
        }
    }

    /// Enqueues URLs for prefetching.
    func prefetch(urls: [URL]) {
        guard !urls.isEmpty else { return }
        SYPlayerConfig.shared.log("Prefetch enqueue \(urls.count) urls", level: .debug)
        workQueue.async { [weak self] in
            self?.enqueue(urls: urls)
        }
    }

    /// Cancels all queued and in-flight prefetch work.
    func cancelAll() {
        SYPlayerConfig.shared.log("Prefetch cancel all (public)", level: .info)
        workQueue.async { [weak self] in
            self?.cancelAllLocked()
        }
    }

    /// Observes Low Power Mode changes to update policy.
    private func observePowerState() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.workQueue.async {
                guard let self else { return }
                let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
                if newValue != self.lowPowerModeEnabled {
                    self.lowPowerModeEnabled = newValue
                    SYPlayerConfig.shared.log(
                        "Prefetch low power mode changed: \(newValue)",
                        level: .debug
                    )
                    self.applyPolicyLocked()
                }
            }
        }
    }

    /// Starts network path monitoring.
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.workQueue.async { [weak self] in
                self?.updateNetworkClass(from: path)
            }
        }
        SYPlayerConfig.shared.log("Prefetch network monitor start", level: .debug)
        monitor.start(queue: monitorQueue)
    }

    /// Updates network class and reapplies policy on changes.
    private func updateNetworkClass(from path: NWPath) {
        let newClass: SYHLSPrefetchNetworkClass
        if path.status != .satisfied {
            newClass = .unknown
        } else if path.isConstrained {
            newClass = .constrained
        } else if path.usesInterfaceType(.wifi) {
            newClass = .wifi
        } else if path.usesInterfaceType(.cellular) || path.isExpensive {
            newClass = .cellular
        } else {
            newClass = .other
        }

        guard newClass != networkClass else { return }
        networkClass = newClass
        SYPlayerConfig.shared.log("Prefetch network class: \(newClass)", level: .info)
        applyPolicyLocked()
    }

    /// Adds URLs to the pending queue within policy limits.
    private func enqueue(urls: [URL]) {
        guard isPrefetchAllowed else {
            SYPlayerConfig.shared.log("Prefetch enqueue skipped (not allowed)", level: .debug)
            return
        }
        let allowedTotal = maxTotalPrefetchItems
        guard allowedTotal > 0 else {
            SYPlayerConfig.shared.log("Prefetch enqueue skipped (limit 0)", level: .debug)
            return
        }

        let currentTotal = inFlight.count + pending.count
        guard currentTotal < allowedTotal else {
            SYPlayerConfig.shared.log("Prefetch queue full", level: .debug)
            return
        }

        var added = 0
        for url in urls {
            if inFlight.contains(url) || pendingSet.contains(url) { continue }
            if currentTotal + added >= allowedTotal { break }
            pending.append(url)
            pendingSet.insert(url)
            added += 1
        }

        drainLocked()
    }

    /// Starts queued work while respecting concurrency limits.
    private func drainLocked() {
        guard isPrefetchAllowed else {
            cancelAllLocked()
            return
        }

        let maxConcurrent = policy.maxConcurrentPrefetches(for: networkClass)
        guard maxConcurrent > 0 else { return }

        while inFlight.count < maxConcurrent, let nextURL = dequeuePending() {
            inFlight.insert(nextURL)
            SYPlayerConfig.shared.log(
                "Prefetch start \(nextURL.absoluteString)",
                level: .debug
            )
            backend.prefetch(nextURL) { [weak self] in
                self?.workQueue.async { [weak self] in
                    self?.finish(url: nextURL)
                }
            }
        }
    }

    /// Dequeues the next pending URL.
    private func dequeuePending() -> URL? {
        guard !pending.isEmpty else { return nil }
        let url = pending.removeFirst()
        pendingSet.remove(url)
        return url
    }

    /// Marks a URL as finished and continues draining.
    private func finish(url: URL) {
        inFlight.remove(url)
        SYPlayerConfig.shared.log(
            "Prefetch finished \(url.absoluteString)",
            level: .debug
        )
        drainLocked()
    }

    /// Applies policy changes by trimming pending work and draining.
    private func applyPolicyLocked() {
        guard isPrefetchAllowed else {
            SYPlayerConfig.shared.log("Prefetch apply policy: not allowed", level: .debug)
            cancelAllLocked()
            return
        }

        let allowedTotal = maxTotalPrefetchItems
        guard allowedTotal > 0 else {
            SYPlayerConfig.shared.log("Prefetch apply policy: limit 0", level: .debug)
            cancelAllLocked()
            return
        }

        if inFlight.count > allowedTotal {
            SYPlayerConfig.shared.log(
                "Prefetch apply policy: in-flight exceeds limit",
                level: .info
            )
            cancelAllLocked()
            return
        }

        let allowedPending = max(allowedTotal - inFlight.count, 0)
        if pending.count > allowedPending {
            let removed = pending.count - allowedPending
            if removed > 0 {
                SYPlayerConfig.shared.log(
                    "Prefetch apply policy: trim \(removed) pending",
                    level: .debug
                )
            }
            if allowedPending == 0 {
                pending.removeAll()
                pendingSet.removeAll()
            } else {
                pending = Array(pending.prefix(allowedPending))
                pendingSet = Set(pending)
            }
        }

        drainLocked()
    }

    /// Cancels all work on the worker queue.
    private func cancelAllLocked() {
        if !pending.isEmpty {
            pending.removeAll()
            pendingSet.removeAll()
        }
        backend.cancelAll()
        inFlight.removeAll()
    }

    /// Returns whether prefetching is allowed under current conditions.
    private var isPrefetchAllowed: Bool {
        if lowPowerModeEnabled && !policy.allowInLowPowerMode {
            return false
        }
        return true
    }

    /// Returns maximum total items for the current network class.
    private var maxTotalPrefetchItems: Int {
        policy.maxPrefetchItems(for: networkClass)
    }
}
