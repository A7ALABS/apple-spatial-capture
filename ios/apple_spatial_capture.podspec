Pod::Spec.new do |s|
  s.name             = 'apple_spatial_capture'
  s.version          = '0.1.0'
  s.summary          = 'Apple RoomPlan, photogrammetry, and LiDAR capture for Flutter.'
  s.description      = <<-DESC
A Flutter iOS and iPadOS plugin that exposes Apple Object Capture
photogrammetry, RoomPlan scanning, LiDAR mesh capture, and native 3D preview
helpers.
                       DESC
  s.homepage         = 'https://example.com/apple_spatial_capture'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mappe' => 'dev@mappe.local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency       'Flutter'
  s.dependency       'GLTFSceneKit', '~> 0.3'
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.0'

  # Vendored msplat Gaussian-splatting training engine (Apache 2.0,
  # https://github.com/rayanht/msplat) and its Metal shader library.
  # iOS support is experimental — training is gated at runtime (iOS 16+).
  s.vendored_frameworks = 'apple_spatial_capture/MsplatCore.xcframework'
  s.resource_bundles = {
    'apple_spatial_capture_msplat' => [
      'apple_spatial_capture/Sources/apple_spatial_capture/Resources/*.metallib'
    ]
  }
  s.frameworks       = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'ImageIO', 'CoreGraphics'
  s.libraries        = 'c++'

  # RoomPlan and ObjectCapture require modern iOS SDKs.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
