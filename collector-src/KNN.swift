import Foundation

struct KNNPrediction {
    let nearestReference: String
    let matchedAccessPoints: Int
}

struct WiFiKNN {
    let references: Set<String>
    let sampleCount: Int
    let ignoredCount: Int

    private let fingerprints: [Fingerprint]
    private let knownBSSIDs: Set<String>

    var canLocate: Bool { references.count >= 2 }

    init(directory: URL) {
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        let files = (entries?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("scan-")
        }.sorted { $0.path < $1.path }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let gridLabels = Set((0..<9).map { GridPoint(index: $0).name })
        let fingerprints: [Fingerprint] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let sample = try? decoder.decode(SavedFingerprint.self, from: data),
                  gridLabels.contains(sample.pointId) else { return nil }
            let signals = Self.signals(from: sample.accessPoints)
            guard !signals.isEmpty else { return nil }
            return Fingerprint(reference: sample.pointId, signals: signals)
        }
        self.fingerprints = fingerprints
        sampleCount = fingerprints.count
        ignoredCount = files.count - fingerprints.count
        references = Set(fingerprints.map(\.reference))
        knownBSSIDs = fingerprints.reduce(into: []) { $0.formUnion($1.signals.keys) }
    }

    func predict(accessPoints: [AccessPoint]) -> KNNPrediction? {
        let observed = Self.signals(from: accessPoints).filter { knownBSSIDs.contains($0.key) }
        let requiredMatches = min(3, knownBSSIDs.count)
        guard canLocate, observed.count >= requiredMatches else { return nil }

        let best = fingerprints.lazy.compactMap { fingerprint -> Neighbor? in
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
            return Neighbor(reference: fingerprint.reference, distance: sum / Double(keys.count),
                            matchedAccessPoints: overlap)
        }.min(by: { $0.distance < $1.distance })

        guard let best else { return nil }
        return KNNPrediction(nearestReference: best.reference, matchedAccessPoints: best.matchedAccessPoints)
    }

    private static func signals(from accessPoints: [AccessPoint]) -> [String: Int] {
        accessPoints.reduce(into: [:]) { signals, point in
            guard let bssid = point.bssid?.lowercased(), !bssid.isEmpty else { return }
            signals[bssid] = max(signals[bssid] ?? Int.min, point.rssi)
        }
    }

    private struct SavedFingerprint: Decodable {
        let pointId: String
        let accessPoints: [AccessPoint]
    }

    private struct Fingerprint {
        let reference: String
        let signals: [String: Int]
    }

    private struct Neighbor {
        let reference: String
        let distance: Double
        let matchedAccessPoints: Int
    }
}
