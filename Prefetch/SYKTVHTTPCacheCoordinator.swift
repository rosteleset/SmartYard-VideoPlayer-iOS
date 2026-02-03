import Foundation
import KTVHTTPCache

enum SYKTVHTTPCacheCoordinator {
    private static let startQueue = DispatchQueue(label: "sy.ktvhttpcache.start")
    private static var didStart = false

    /// Starts the KTVHTTPCache proxy if needed.
    static func ensureStarted() {
        startQueue.sync {
            guard !didStart else { return }
            SYPlayerConfig.shared.log("KTVHTTPCache start", level: .debug)
            var error: NSError?
            _ = try? KTVHTTPCache.proxyStart()
            didStart = KTVHTTPCache.proxyIsRunning()
            if let error {
                SYPlayerConfig.shared.log(
                    "KTVHTTPCache start error: \(error.localizedDescription)",
                    level: .error
                )
            }
            if !didStart {
                SYPlayerConfig.shared.log(
                    "KTVHTTPCache proxy not running after start",
                    level: .error
                )
            }
        }
    }

    /// Returns a proxy URL for the given original URL.
    static func proxyURL(for url: URL) -> URL {
        if KTVHTTPCache.proxyIsProxyURL(url) { return url }
        ensureStarted()
        return KTVHTTPCache.proxyURL(withOriginalURL: url)
    }
}
