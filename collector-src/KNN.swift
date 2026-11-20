import Foundation

struct KNNPrediction {
    let column: Double
    let row: Double
    let neighborsUsed: Int
}

struct WiFiKNN {
    static let neighborCount = 3

    let references: Set<String>
    let sampleCount: Int
    let ignoredCount: Int
    let duplicateCount: Int

    private let fingerprints: [Fingerprint]
    private let knownBSSIDs: Set<String>

    var canLocate: Bool { references.count >= 2 }

    init(directory: URL) {
        let files = SampleStore.scanFiles(in: directory)
        let decoder = JSONDecoder()
        let gridPoints = Dictionary(uniqueKeysWithValues: (0..<9).map { index in
            let point = GridPoint(index: index)
            return (point.name, point)
        })
        let validFingerprints: [Fingerprint] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let sample = try? decoder.decode(SampleStore.StoredScan.self, from: data),
                  let point = gridPoints[sample.pointId] else { return nil }
            let signals = Self.signals(from: sample.accessPoints)
            guard !signals.isEmpty else { return nil }
            return Fingerprint(point: point, signals: signals)
        }
        // Identical readings at the same point should occupy just one neighbor slot.
        var seen = Set<Fingerprint>()
        let fingerprints = validFingerprints.filter { seen.insert($0).inserted }
        self.fingerprints = fingerprints
        sampleCount = fingerprints.count
        ignoredCount = files.count - validFingerprints.count
        duplicateCount = validFingerprints.count - fingerprints.count
        references = Set(fingerprints.map { $0.point.name })
        knownBSSIDs = fingerprints.reduce(into: []) { $0.formUnion($1.signals.keys) }
    }

    func predict(accessPoints: [AccessPoint]) -> KNNPrediction? {
        let observed = Self.signals(from: accessPoints).filter { knownBSSIDs.contains($0.key) }
        let requiredMatches = min(3, knownBSSIDs.count)
        guard canLocate, observed.count >= requiredMatches else { return nil }

        let neighbors = fingerprints.compactMap { fingerprint -> Neighbor? in
            let overlap = observed.keys.reduce(into: 0) { count, bssid in
                if fingerprint.signals[bssid] != nil { count += 1 }
            }
            guard overlap >= requiredMatches else { return nil }

            // A known AP observed only on one side is compared with the weak-signal floor.
            let keys = Set(observed.keys).union(fingerprint.signals.keys)
            let sum = keys.sorted().reduce(0.0) { sum, key in
                let delta = Double(observed[key] ?? -100) - Double(fingerprint.signals[key] ?? -100)
                return sum + delta * delta
            }
            // Mean squared distance has the same ranking as root mean square distance.
            return Neighbor(point: fingerprint.point, distance: sum / Double(keys.count))
        }.sorted { $0.distance < $1.distance }.prefix(Self.neighborCount)

        guard !neighbors.isEmpty else { return nil }
        let columns = neighbors.reduce(0) { $0 + $1.point.column }
        let rows = neighbors.reduce(0) { $0 + $1.point.row }
        return KNNPrediction(column: Double(columns) / Double(neighbors.count),
                             row: Double(rows) / Double(neighbors.count),
                             neighborsUsed: neighbors.count)
    }

    private static func signals(from accessPoints: [AccessPoint]) -> [String: Int] {
        accessPoints.reduce(into: [:]) { signals, point in
            guard let bssid = point.bssid?.lowercased(), !bssid.isEmpty else { return }
            signals[bssid] = max(signals[bssid] ?? Int.min, point.rssi)
        }
    }

    private struct Fingerprint: Hashable {
        let point: GridPoint
        let signals: [String: Int]
    }

    private struct Neighbor {
        let point: GridPoint
        let distance: Double
    }
}
