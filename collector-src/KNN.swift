import Foundation

struct FloorPosition: Hashable {
    let x: Double
    let z: Double
}

struct FingerprintReference: Hashable {
    let label: String
    let position: FloorPosition
}

struct KNNPrediction {
    let position: FloorPosition
    let nearestReference: String
    let matchedAccessPoints: Int
}

struct WiFiKNN {
    let references: [FingerprintReference]
    let sampleCount: Int
    let ignoredCount: Int

    private let fingerprints: [Fingerprint]
    private let knownBSSIDs: Set<String>

    var canLocate: Bool {
        Set(references.map(\.position)).count >= 2
    }

    init(directory: URL) {
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        let files = (entries?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("scan-")
        }.sorted { $0.path < $1.path }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fingerprints: [Fingerprint] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let sample = try? decoder.decode(SavedFingerprint.self, from: data),
                  sample.xM.isFinite, sample.zM.isFinite else { return nil }
            let signals = Self.signals(from: sample.accessPoints)
            guard !signals.isEmpty else { return nil }
            return Fingerprint(
                reference: FingerprintReference(label: sample.pointId,
                                                position: FloorPosition(x: sample.xM, z: sample.zM)),
                signals: signals)
        }
        self.fingerprints = fingerprints
        sampleCount = fingerprints.count
        ignoredCount = files.count - fingerprints.count
        references = Set(fingerprints.map(\.reference)).sorted {
            ($0.label, $0.position.x, $0.position.z) < ($1.label, $1.position.x, $1.position.z)
        }
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
            return Neighbor(reference: fingerprint.reference, distance: (sum / Double(keys.count)).squareRoot(),
                            matchedAccessPoints: overlap)
        }.sorted { $0.distance < $1.distance }.prefix(3)

        guard let best = neighbors.first else { return nil }
        var totalWeight = 0.0
        var x = 0.0
        var z = 0.0
        for neighbor in neighbors {
            // A 1 dBm floor keeps exact matches finite.
            let weight = 1.0 / max(1, neighbor.distance)
            totalWeight += weight
            x += weight * neighbor.reference.position.x
            z += weight * neighbor.reference.position.z
        }
        return KNNPrediction(position: FloorPosition(x: x / totalWeight, z: z / totalWeight),
                             nearestReference: best.reference.label,
                             matchedAccessPoints: best.matchedAccessPoints)
    }

    private static func signals(from accessPoints: [AccessPoint]) -> [String: Int] {
        accessPoints.reduce(into: [:]) { signals, point in
            guard let bssid = point.bssid?.lowercased(), !bssid.isEmpty else { return }
            signals[bssid] = max(signals[bssid] ?? Int.min, point.rssi)
        }
    }

    private struct SavedFingerprint: Decodable {
        let pointId: String
        let xM: Double
        let zM: Double
        let accessPoints: [AccessPoint]
    }

    private struct Fingerprint {
        let reference: FingerprintReference
        let signals: [String: Int]
    }

    private struct Neighbor {
        let reference: FingerprintReference
        let distance: Double
        let matchedAccessPoints: Int
    }
}
