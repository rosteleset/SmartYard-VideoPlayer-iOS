import Foundation

private final class SYPlayerBundleToken {}

extension Bundle {
    static let syPlayer: Bundle = {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        let bundle = Bundle(for: SYPlayerBundleToken.self)
        if let resourceURL = bundle.url(forResource: "SmartYardVideoPlayer", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceURL) {
            return resourceBundle
        }
        return bundle
#endif
    }()
}
