# Wi-Fi RSSI Localization

A native macOS app for collecting labeled Wi-Fi RSSI fingerprints and matching live scans to reference points on a 3×3 grid. It uses CoreWLAN and finds the closest saved fingerprint by comparing RSSI values for matching BSSIDs.

## Download and run

Get the macOS Universal ZIP from [GitHub Releases](https://github.com/cziwen/WIFI_RSSI_Localization/releases/latest). Extract the app into a writable folder and open it. The build supports macOS 13 and later on Apple silicon and Intel.

To build from source with Xcode or the Command Line Tools installed:

```sh
./collector-src/build.sh
open "Wi-Fi RSSI Collector.app"
```

## Use the app

1. Allow Location Services for the app so macOS can return access point identifiers.
2. In **采集** (Collection), choose a point from P1–P9 and start scanning. The two-point mode lets you choose any two points for a quick test.
3. In **实时定位** (Live Localization), start scanning after collecting samples for at least two points. The grid highlights the point whose saved fingerprint best matches the current scan.
4. Use **轮间等待** (Delay Between Scans) at the bottom of the window to set the wait time for both modes. The setting takes effect when you next start a session. A value of 0 requests the next scan as soon as the previous one finishes.

The app saves each labeled scan as JSON in the local `samples/` folder next to the app. It skips scans without BSSIDs. Existing samples with a supported `point_id` and BSSID readings can be reused, including older JSON files that also contain X/Z coordinates. Git ignores the sample folder.
