import Foundation

struct Fingerprint: Hashable, Sendable {
    let point: GridPoint
    let signals: [String: Int]

    static func bssid(for accessPoint: AccessPoint) -> String? {
        guard let bssid = accessPoint.bssid?.lowercased(), !bssid.isEmpty else { return nil }
        return bssid
    }

    static func signals(from accessPoints: [AccessPoint]) -> [String: Int] {
        accessPoints.reduce(into: [:]) { signals, point in
            guard let bssid = bssid(for: point) else { return }
            signals[bssid] = max(signals[bssid] ?? Int.min, point.rssi)
        }
    }

    static func isValidRSSI(_ rssi: Int) -> Bool {
        (-127 ... -1).contains(rssi)
    }

    static func meanSquaredDistance(_ left: [String: Int], _ right: [String: Int]) -> Double {
        meanSquaredDistance(left.mapValues(Double.init), right)
    }

    /// `left` may be an average of several scans, so its readings are not whole dBm.
    static func meanSquaredDistance(_ left: [String: Double], _ right: [String: Int]) -> Double {
        let keys = Set(left.keys).union(right.keys)
        let sum = keys.sorted().reduce(0.0) { sum, key in
            let delta = (left[key] ?? -100) - Double(right[key] ?? -100)
            return sum + delta * delta
        }
        return sum / Double(keys.count)
    }
}

struct FingerprintDataset {
    let fingerprints: [Fingerprint]
    let ignoredCount: Int
    let duplicateCount: Int
    let networkNames: [String: String]
    /// Last channel seen for each BSSID; used to tell 2.4 GHz (≤ 14) from 5 GHz.
    let channels: [String: Int]

    init(directory: URL, collectMetadata: Bool = false) {
        let files = SampleStore.scanFiles(in: directory)
        let decoder = JSONDecoder()
        let gridPoints = Dictionary(uniqueKeysWithValues: (0..<9).map { index in
            let point = GridPoint(index: index)
            return (point.name, point)
        })
        var fingerprints: [Fingerprint] = []
        var seen = Set<Fingerprint>()
        var ignored = 0
        var names: [String: String] = [:]
        var channels: [String: Int] = [:]

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let sample = try? decoder.decode(SampleStore.StoredScan.self, from: data),
                  let point = gridPoints[sample.pointId] else {
                ignored += 1
                continue
            }
            let signals = Fingerprint.signals(from: sample.accessPoints)
            guard !signals.isEmpty else {
                ignored += 1
                continue
            }

            for accessPoint in sample.accessPoints {
                if let bssid = Fingerprint.bssid(for: accessPoint), let channel = accessPoint.channel {
                    channels[bssid] = channel
                }
            }

            if collectMetadata {
                for accessPoint in sample.accessPoints {
                    if let bssid = Fingerprint.bssid(for: accessPoint),
                       let name = accessPoint.ssid, !name.isEmpty, names[bssid] == nil {
                        names[bssid] = name
                    }
                }
            }

            let fingerprint = Fingerprint(point: point, signals: signals)
            if seen.insert(fingerprint).inserted { fingerprints.append(fingerprint) }
        }
        self.fingerprints = fingerprints
        self.ignoredCount = ignored
        duplicateCount = files.count - ignored - fingerprints.count
        networkNames = names
        self.channels = channels
    }
}


enum FingerprintFilter: String, CaseIterable, Identifiable, Sendable {
    case baseline = "全部 BSSID"
    case anyPoint = "任一点 ≥ 50%"

    var id: Self { self }
}

struct FingerprintSelection {
    struct Feature: Identifiable, Sendable {
        let id: String
        let ssid: String?
        let detections: [Int]
        let selectionCoverage: Double
        let retained: Bool
    }

    let points: [(point: GridPoint, count: Int)]
    let features: [Feature]
    let fingerprints: [Fingerprint]
    let retainedBSSIDs: Set<String>
    let invalidReadings: Int
    let emptyFingerprints: Int
    let mergedFingerprints: Int

    init(dataset: FingerprintDataset, filter: FingerprintFilter) {
        let groups = Dictionary(grouping: dataset.fingerprints, by: \.point)
        let labels = groups.keys.sorted { $0.index < $1.index }
        let totals = labels.map { groups[$0]?.count ?? 0 }
        points = Array(zip(labels, totals))
        let originalBSSIDs = Set(dataset.fingerprints.flatMap { $0.signals.keys })
        let plausible = dataset.fingerprints.map { fingerprint in
            guard filter == .anyPoint else { return fingerprint }
            return Fingerprint(point: fingerprint.point,
                               signals: fingerprint.signals.filter { Fingerprint.isValidRSSI($0.value) })
        }
        let observed = Dictionary(grouping: plausible, by: \.point).mapValues { group in
            group.reduce(into: [String: Int]()) { counts, fingerprint in
                for bssid in fingerprint.signals.keys { counts[bssid, default: 0] += 1 }
            }
        }
        let features = originalBSSIDs.map { bssid in
            let detections = labels.map { observed[$0]?[bssid] ?? 0 }
            let rates = zip(detections, totals).map { Double($0) / Double($1) }
            let coverage = rates.max() ?? 0
            return Feature(id: bssid, ssid: dataset.networkNames[bssid], detections: detections,
                           selectionCoverage: coverage, retained: filter == .baseline || coverage >= 0.5)
        }
        self.features = features

        let retained = Set(features.lazy.filter(\.retained).map(\.id))
        retainedBSSIDs = retained
        let nonempty = plausible.compactMap { fingerprint -> Fingerprint? in
            let signals = fingerprint.signals.filter { retained.contains($0.key) }
            guard !signals.isEmpty else { return nil }
            return Fingerprint(point: fingerprint.point, signals: signals)
        }
        var seen = Set<Fingerprint>()
        let selected = nonempty.filter { seen.insert($0).inserted }
        fingerprints = selected
        invalidReadings = zip(dataset.fingerprints, plausible).reduce(0) {
            $0 + $1.0.signals.count - $1.1.signals.count
        }
        emptyFingerprints = plausible.count - nonempty.count
        mergedFingerprints = nonempty.count - selected.count
    }
}
