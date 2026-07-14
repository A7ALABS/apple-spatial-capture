Pod::Spec.new do |s|
  s.name             = 'apple_spatial_capture'
  s.version          = '0.1.0'
  s.summary          = 'Apple photogrammetry and model preview support for Flutter on macOS.'
  s.description      = <<-DESC
A Flutter macOS plugin that exposes Apple Object Capture photogrammetry from
existing image sets and native model preview helpers.
                       DESC
  s.homepage         = 'https://github.com/A7ALABS/apple-spatial-capture'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'A7ALABS' => 'dev@a7alabs.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency       'FlutterMacOS'
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.0'

  # Vendored msplat Gaussian-splatting training engine (Apache 2.0,
  # https://github.com/rayanht/msplat) and its Metal shader library.
  s.vendored_frameworks = 'apple_spatial_capture/MsplatCore.xcframework'
  s.resource_bundles = {
    'apple_spatial_capture_msplat' => [
      'apple_spatial_capture/Sources/apple_spatial_capture/Resources/*.metallib'
    ]
  }
  s.frameworks       = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'ImageIO', 'CoreGraphics'
  s.libraries        = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
