import Foundation

protocol SYHLSPrefetchBackend: AnyObject {
    /// Starts prefetching the given URL and calls completion when done.
    func prefetch(_ url: URL, completion: @escaping () -> Void)
    /// Cancels prefetching for a specific URL.
    func cancel(_ url: URL)
    /// Cancels all in-flight prefetch work.
    func cancelAll()
}

final class SYNoopHLSPrefetchBackend: SYHLSPrefetchBackend {
    /// Immediately completes without doing any work.
    func prefetch(_ url: URL, completion: @escaping () -> Void) {
        completion()
    }

    /// No-op cancellation.
    func cancel(_ url: URL) {}

    /// No-op cancellation of all work.
    func cancelAll() {}
}
