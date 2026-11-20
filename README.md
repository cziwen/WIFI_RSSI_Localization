# Wi-Fi RSSI Localization

A native macOS app for collecting labeled Wi-Fi RSSI fingerprints and identifying the closest reference point on a 3×3 grid. It scans with CoreWLAN and matches access points by BSSID.

## Download and run

Get the macOS Universal ZIP from [GitHub Releases](https://github.com/cziwen/WIFI_RSSI_Localization/releases/latest). Extract the app into a writable folder and open it. The build supports macOS 13 and later on Apple silicon and Intel. The distributed app uses an ad hoc signature.

To build from source with Xcode or the Command Line Tools installed:

```sh
./collector-src/build.sh
open "Wi-Fi RSSI Collector.app"
```

## Use the app

1. Allow Location Services for the app so macOS can return BSSIDs.
2. In **采集** (Collection), select P1–P9 and start scanning. The two-point mode lets you choose any two reference points. The panel shows requested, skipped, and saved rounds. Collection skips exact repeats and rapid responses that strongly resemble the last saved scan in the same session.
3. In **数据检查** (Data Check), compare all BSSIDs with the **Any point ≥ 50%** filter. The app shows two-dimensional MDS plots, per-point AP detection rates, and retained sample counts. Each view fits its own projection.
4. In **实时定位** (Live Localization), start scanning after collecting samples for at least two points. The app uses 1-NN with the **Any point ≥ 50%** filter and highlights the closest reference point. It shows the last valid result time, matching distances, and overlapping AP counts. Responses returned within 0.5 seconds do not update the result, and the highlight clears after 25 seconds without a valid prediction.

The app stores labeled JSON in the local `samples/` folder next to the app. Existing samples with a supported `point_id` and BSSID readings remain compatible, including older files with X/Z coordinates. Keep holdout or evaluation files outside `samples/` to keep them independent of the reference library.
