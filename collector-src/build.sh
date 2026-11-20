#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-"$source_dir/.."}"
app_name='Wi-Fi RSSI Collector.app'
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifi-rssi.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/$app_name"
mkdir -p "$app/Contents/MacOS" "$destination"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"

for arch in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -target "$arch-apple-macos13" \
        -module-cache-path "$build_dir/module-cache" \
        "$source_dir/WiFiScanner.swift" "$source_dir/CollectionModel.swift" \
        "$source_dir/FingerprintDataset.swift" "$source_dir/FingerprintQuality.swift" \
        "$source_dir/FingerprintQualityView.swift" "$source_dir/KNN.swift" "$source_dir/LocalizationMap.swift" "$source_dir/CollectorApp.swift" -o "$build_dir/WiFiRSSI-$arch"
done

xcrun lipo -create "$build_dir/WiFiRSSI-arm64" "$build_dir/WiFiRSSI-x86_64" \
    -output "$app/Contents/MacOS/WiFiRSSI"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto "$app" "$destination/$app_name"
codesign --verify --strict "$destination/$app_name"
