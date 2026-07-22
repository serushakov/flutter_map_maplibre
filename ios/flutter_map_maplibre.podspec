#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_map_maplibre.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_map_maplibre'
  s.version          = '0.0.1'
  s.summary          = 'MapLibre basemap rendered into a Flutter texture.'
  s.description      = <<-DESC
Spike: a natively-rendered MapLibre basemap streamed into a Flutter Texture,
with the camera owned by Dart.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_map_maplibre/Sources/flutter_map_maplibre/**/*'
  s.dependency 'Flutter'
  # A dynamic framework must resolve the vendored C symbols at its own link
  # step, which loses to link order. Static lets them resolve at the app link,
  # where -force_load below pulls the whole archive in.
  s.static_framework = true

  # maplibre-native-ffi's Apple CMake presets set CMAKE_OSX_DEPLOYMENT_TARGET
  # to 14.3, so this cannot go lower while the xcframework is linked.
  s.platform = :ios, '14.3'

  # Built from source out of maplibre-native-ffi. NOT committed — see
  # .gitignore. Produced by:
  #   cmake --preset ios-simulator-arm64-metal
  #   cmake --build --preset ios-simulator-arm64-metal
  #   xcodebuild -create-xcframework -library libmaplibre-native-c.a \
  #     -headers <include dir with module.modulemap> -output MaplibreNativeC.xcframework
  s.vendored_frameworks = 'MaplibreNativeC.xcframework'

  s.libraries = 'c++', 'z'
  s.frameworks = 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'ImageIO'

  # A static-library xcframework carries headers but CocoaPods does not register
  # its module.modulemap, so Swift cannot `import MaplibreNativeC` without being
  # told where to look. Both slices hold a library of the same name, so the
  # -lmln-stripped that CocoaPods derives from the filename resolves for either
  # SDK; only the search path has to vary.
  mln_root    = '$(PODS_TARGET_SRCROOT)/MaplibreNativeC.xcframework'
  mln_dev     = %("#{mln_root}/ios-arm64")
  mln_sim     = %("#{mln_root}/ios-arm64-simulator")
  mln_dev_hdr = %("#{mln_root}/ios-arm64/Headers")
  mln_sim_hdr = %("#{mln_root}/ios-arm64-simulator/Headers")

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'HEADER_SEARCH_PATHS[sdk=iphoneos*]' => mln_dev_hdr,
    'HEADER_SEARCH_PATHS[sdk=iphonesimulator*]' => mln_sim_hdr,
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => mln_dev,
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => mln_sim,
  }
  # The app target links the archive too, and PODS_TARGET_SRCROOT is not
  # defined there — hence the PODS_ROOT-relative path.
  mln_user_root = '$(PODS_ROOT)/../../../ios/MaplibreNativeC.xcframework'
  s.user_target_xcconfig = {
    # maplibre-native-ffi has no x86_64 simulator preset, so a universal
    # simulator build has nothing to link for that slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => %("#{mln_user_root}/ios-arm64"),
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => %("#{mln_user_root}/ios-arm64-simulator"),
  }

  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_map_maplibre_privacy' => ['flutter_map_maplibre/Sources/flutter_map_maplibre/PrivacyInfo.xcprivacy']}
end
