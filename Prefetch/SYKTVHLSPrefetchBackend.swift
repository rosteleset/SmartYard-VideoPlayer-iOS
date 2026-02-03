import Foundation
import KTVHTTPCache

final class SYKTVHLSPrefetchBackend: NSObject, SYHLSPrefetchBackend {
    private struct PrefetchTask {
        let loader: KTVHCDataHLSLoader
        let completion: () -> Void
    }

    private let queue = DispatchQueue(label: "sy.hls.prefetch.backend", qos: .utility)
    private var tasks: [URL: PrefetchTask] = [:]

    /// Starts an HLS prefetch using KTVHTTPCache.
    func prefetch(_ url: URL, completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            SYKTVHTTPCacheCoordinator.ensureStarted()
            if self.tasks[url] != nil { return }

            SYPlayerConfig.shared.log(
                "KTVHLSPrefetch start \(url.absoluteString)",
                level: .debug
            )
            let request = KTVHCDataRequest(url: url, headers: nil)
            let loader = KTVHTTPCache.cacheHLSLoader(with: request)

            guard let loader else { return }

            loader.delegate = self
            loader.object = url
            self.tasks[url] = PrefetchTask(loader: loader, completion: completion)
            loader.prepare()
        }
    }

    /// Cancels a specific prefetch task.
    func cancel(_ url: URL) {
        queue.async { [weak self] in
            guard let self, let task = self.tasks.removeValue(forKey: url) else { return }
            SYPlayerConfig.shared.log(
                "KTVHLSPrefetch cancel \(url.absoluteString)",
                level: .debug
            )
            task.loader.close()
            task.completion()
        }
    }

    /// Cancels all prefetch tasks.
    func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            SYPlayerConfig.shared.log("KTVHLSPrefetch cancel all", level: .info)
            let tasks = self.tasks
            self.tasks.removeAll()
            for (_, task) in tasks {
                task.loader.close()
                task.completion()
            }
        }
    }
}

extension SYKTVHLSPrefetchBackend: KTVHCDataHLSLoaderDelegate {
    func ktv_HLSLoader(_ loader: KTVHCDataHLSLoader!, didChangeProgress progress: Double) {

    }

    /// Called when an HLS loader finishes successfully.
    func ktv_HLSLoaderDidFinish(_ loader: KTVHCDataHLSLoader) {
        SYPlayerConfig.shared.log("KTVHLSPrefetch finished", level: .debug)
        finish(loader: loader)
    }

    /// Called when an HLS loader fails.
    func ktv_HLSLoader(_ loader: KTVHCDataHLSLoader, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        SYPlayerConfig.shared.log(
            "KTVHLSPrefetch failed: \(message)",
            level: .error
        )
        finish(loader: loader)
    }

    func ktv_HLSLoader(_ loader: KTVHCDataHLSLoader, makeURLsForContent content: String) -> [URL] {
        let components = content.components(separatedBy: "\n")
        var urls: [URL] = []

        guard let sourceURL = loader.object as? URL else { return [] }
        var baseComponents = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        let baseQueryItems = baseComponents?.queryItems ?? []
        baseComponents?.query = nil
        baseComponents?.fragment = nil
        let baseURL = baseComponents?.url ?? sourceURL

        func mergedURL(_ url: URL) -> URL {
            guard !baseQueryItems.isEmpty else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            var items = components.queryItems ?? []
            let existing = Set(items.map(\.name))
            for item in baseQueryItems where !existing.contains(item.name) {
                items.append(item)
            }
            components.queryItems = items
            return components.url ?? url
        }

        for line in components {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("http") {
                if let url = URL(string: trimmed) {
                    urls.append(mergedURL(url))
                }
                continue
            }

            if trimmed.hasPrefix("./http") {
                let normalized = trimmed.replacingOccurrences(of: "./http", with: "http")
                if let url = URL(string: normalized) {
                    urls.append(mergedURL(url))
                }
                continue
            }

            if let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                urls.append(mergedURL(url))
            }
        }

        return urls
    }

    /// Completes and removes a finished loader.
    private func finish(loader: KTVHCDataHLSLoader) {
        queue.async { [weak self] in
            guard let self,
                  let url = loader.object as? URL,
                  let task = self.tasks.removeValue(forKey: url) else { return }
            SYPlayerConfig.shared.log(
                "KTVHLSPrefetch cleanup \(url.absoluteString)",
                level: .debug
            )
            task.completion()
        }
    }
}
