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

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
