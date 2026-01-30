import Foundation

public extension SYPlayerConfig {
    /// Prefetch HLS playlists (m3u8). Extra URLs are ignored after the limit.
    public func prefetch(urls: [URL], maxCount: Int = 4) {
        guard maxCount > 0 else {
            SYPlayerConfig.shared.log("Prefetch skipped (maxCount <= 0)", level: .warning)
            return
        }
        let hls = urls
            .filter { !$0.isFileURL && $0.pathExtension.lowercased() == "m3u8" }
            .prefix(maxCount)
        guard !hls.isEmpty else {
            SYPlayerConfig.shared.log("Prefetch skipped (no HLS urls)", level: .debug)
            return
        }
        SYPlayerConfig.shared.log(
            "Prefetch request count: \(hls.count), maxCount: \(maxCount)",
            level: .info
        )
        SYHLSPrefetchController.shared.prefetch(urls: Array(hls))
    }

    /// Cancel all scheduled and in-flight prefetch work.
    public func cancelPrefetch() {
        SYPlayerConfig.shared.log("Prefetch cancel all", level: .info)
        SYHLSPrefetchController.shared.cancelAll()
    }
}
