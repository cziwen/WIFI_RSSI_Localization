# Wi-Fi RSSI Localization

A native macOS app for collecting labeled Wi-Fi RSSI fingerprints and estimating a MacBook's indoor position with weighted K-nearest neighbors. The app uses CoreWLAN and shows estimates on a local X–Z floor map.

## Build and run

With Xcode or the Command Line Tools installed, run:

```sh
./collector-src/build.sh
open "Wi-Fi RSSI Collector.app"
```

The build targets macOS 13 or later and supports Intel and Apple silicon.

## Use the app

1. Enable Location Services for the app so macOS can provide access-point identifiers.
2. In **采集** (Collection), configure the measured X and Z spacing, select a reference point, and start scanning. The two-point mode is useful for a quick check.
3. In **实时定位** (Live Localization), start scanning to estimate the MacBook's position from the saved fingerprints. Each live estimate uses up to three nearest fingerprints.

The app writes labeled JSON samples into the local `samples/` folder beside the app. A scan with no BSSID is skipped. The sample folder is ignored by Git.
