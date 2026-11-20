# Wi-Fi RSSI Localization

A native macOS app that collects labeled Wi-Fi RSSI fingerprints and estimates position on a 3×3 grid using 3-NN regression. It scans with CoreWLAN and compares RSSI readings by BSSID.

## Download and run

Get the macOS Universal ZIP from [GitHub Releases](https://github.com/cziwen/WIFI_RSSI_Localization/releases/latest). Extract the app into a writable folder and open it. The build supports macOS 13 and later on Apple silicon and Intel.

To build from source with Xcode or the Command Line Tools installed:

```sh
./collector-src/build.sh
open "Wi-Fi RSSI Collector.app"
```

## Use the app

1. Allow Location Services for the app so macOS can return access point identifiers.
2. In **采集** (Collection), choose P1–P9 and start scanning. The two-point mode lets you choose any two points for a quick check. The panel shows requested, skipped, and saved scan counts. The app skips a scan if its BSSID and RSSI readings exactly match the previous valid fingerprint for that point.
3. In **实时定位** (Live Localization), start scanning after collecting samples for at least two points. The model averages the grid coordinates of up to three nearest distinct fingerprints. A blue dot marks the estimate in grid units.
4. Both modes request the next scan immediately after processing a valid result. The footer reports measured scan time and time between results.

The app stores labeled JSON in the local `samples/` folder next to the app. It skips scans without BSSIDs. Existing samples with a supported `point_id` and BSSID readings work with the current version, including older files with X/Z coordinates. Git ignores the sample folder.
