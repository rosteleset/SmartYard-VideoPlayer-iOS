import Foundation

private final class SYPlayerBundleToken {}

extension Bundle {
    static let syPlayer: Bundle = {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        let bundleName = "SmartYardVideoPlayer"
        let frameworkBundle = Bundle(for: SYPlayerBundleToken.self)
        let frameworkURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("\(bundleName).framework")
        let searchURLs = [
            frameworkBundle.resourceURL,
            frameworkBundle.bundleURL,
            frameworkURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL
        ].compactMap { $0 }

        for searchURL in searchURLs {
            let resourceURL = searchURL.appendingPathComponent("\(bundleName).bundle")

            if let resourceBundle = Bundle(url: resourceURL) {
                return resourceBundle
            }
        }

        return frameworkBundle
#endif
    }()
}
