#!/usr/bin/env bash
# Packs the locally built maplibre-native-ffi artifacts into the release
# assets that the podspec and CMakeLists.txt download.
#
# usage: scripts/package_native.sh <maplibre-native-ffi checkout> <out dir>
#
# Expects the artifacts already in place, exactly where a local build puts
# them (see README "Native prerequisites"):
#   ios/MaplibreNativeC.xcframework
#   android/src/main/cpp/prebuilt/arm64-v8a/libmaplibre-native-c.a
#
# Produces mln-ios.zip, mln-android.zip and SHA256SUMS in <out dir>. Publish
# them as a GitHub release, then point the URL and hashes in
# ios/flutter_map_maplibre.podspec and android/src/main/cpp/CMakeLists.txt at
# it. Each zip carries the license texts binary redistribution requires.
set -euo pipefail

ffi=$(cd "$1" && pwd)
out=$(mkdir -p "$2" && cd "$2" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

ffi_rev=$(git -C "$ffi" rev-parse HEAD)

licenses() {
  local dir=$1
  mkdir -p "$dir"
  cp "$ffi/LICENSE" "$dir/maplibre-native-ffi.LICENSE"
  cp "$ffi/third_party/maplibre-native/LICENSE.md" "$dir/maplibre-native.LICENSE.md"
  cp "$ffi/third_party/maplibre-native/LICENSES.core.md" "$dir/maplibre-native.LICENSES.core.md"
}

# iOS: the xcframework plus its notices, unpacked by the podspec into ios/.
mkdir -p "$stage/ios"
cp -R "$root/ios/MaplibreNativeC.xcframework" "$stage/ios/"
licenses "$stage/ios/MaplibreNativeC.licenses"
cat > "$stage/ios/MaplibreNativeC.licenses/BUILD_INFO.txt" <<EOF
maplibre-native-ffi $ffi_rev, unmodified.
Presets: ios-arm64-metal, ios-simulator-arm64-metal.
EOF

# Android: the arm64 archive plus its notices, unpacked by CMake into
# prebuilt/. The Rust HTTP/TLS stack is linked into this archive, so its
# crates' notices ride along.
mkdir -p "$stage/android/arm64-v8a"
cp "$root/android/src/main/cpp/prebuilt/arm64-v8a/libmaplibre-native-c.a" \
  "$stage/android/arm64-v8a/"
licenses "$stage/android/licenses"
python3 "$root/scripts/rust_licenses.py" "$ffi" \
  "$stage/android/licenses/rust-crates.md"
cat > "$stage/android/licenses/BUILD_INFO.txt" <<EOF
maplibre-native-ffi $ffi_rev
+ patches/0001-android-webpki-roots.patch from flutter_map_maplibre.
Preset: android-arm64-egl, NDK 28.2.13676358.
EOF

# The same notices, as the package assets registerMaplibreLicenses() reads,
# so the licenses page matches the binaries being published.
cp "$ffi/LICENSE" "$root/licenses/maplibre-native-ffi.LICENSE"
cp "$ffi/third_party/maplibre-native/LICENSES.core.md" \
  "$root/licenses/maplibre-native.LICENSES.core.md"

rm -f "$out/mln-ios.zip" "$out/mln-android.zip"
(cd "$stage/ios" && zip -qr -9 "$out/mln-ios.zip" .)
(cd "$stage/android" && zip -qr -9 "$out/mln-android.zip" .)
(cd "$out" && shasum -a 256 mln-ios.zip mln-android.zip > SHA256SUMS)
cat "$out/SHA256SUMS"
