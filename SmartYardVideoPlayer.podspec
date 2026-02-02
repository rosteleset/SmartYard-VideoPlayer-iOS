Pod::Spec.new do |s|
  s.name = "SmartYardVideoPlayer"
  s.version = "0.1.3"
  s.summary = "SmartYard video player UI and playback components."
  s.description = <<-DESC
SmartYardVideoPlayer provides a UIKit-based video player with archive/online playback,
HLS prefetching, caching, and customizable controls.
  DESC
  s.homepage = "https://github.com/rosteleset/SmartYard-VideoPlayer-iOS"
  s.license = { :type => "GPL-3.0" }
  s.author = { "SmartYard" => "https://sesameware.com" }
  s.source = {
    :git => 'https://github.com/rosteleset/SmartYard-VideoPlayer-iOS.git',
    :tag => s.version.to_s
  }

  s.platform = :ios, "13.0"
  s.swift_version = "6.0"

  s.source_files = "{Models,Playback,Player,Prefetch,Support,UI}/**/*.swift"
  s.resource_bundles = {
    "SmartYardVideoPlayer" => [
      "Resources/**/*",
      "UI/**/*.{xib,storyboard,xcassets}"
    ]
  }

  s.frameworks = "UIKit", "AVFoundation", "Network"
  s.dependency "SnapKit"
  s.dependency "RxSwift"
  s.dependency "RxCocoa"
  s.dependency "lottie-ios"
  s.dependency "Kingfisher"
  s.dependency "KTVHTTPCache"
  s.dependency "SwifterSwift"
  s.dependency "TouchAreaInsets"
end
