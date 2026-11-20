import Foundation

struct KNNPrediction {
    let point: GridPoint
    let closest: [Match]

    struct Match {
        let point: GridPoint
        let distance: Double
        let overlap: Int
    }
}

struct LocalizationFix {
    private static let maxAge: TimeInterval = 25
    let prediction: KNNPrediction
    let time: Date

    func isCurrent(at date: Date) -> Bool {
        date.timeIntervalSince(time) <= Self.maxAge
    }
}

struct WiFiKNN {
    static let neighborCount = 1
    static let featureFilter = FingerprintFilter.anyPoint

    let references: Set<String>
    let sampleCount: Int
    let ignoredCount: Int
    let duplicateCount: Int

    private let fingerprints: [Fingerprint]
    private let knownBSSIDs: Set<String>

    var featureCount: Int { knownBSSIDs.count }

    var canLocate: Bool { references.count >= 2 }

    init(directory: URL) {
        let data = FingerprintDataset(directory: directory)
        let selection = FingerprintSelection(dataset: data, filter: Self.featureFilter)
        fingerprints = selection.fingerprints
        sampleCount = fingerprints.count
        ignoredCount = data.ignoredCount + selection.emptyFingerprints
        duplicateCount = data.duplicateCount + selection.mergedFingerprints
        references = Set(fingerprints.map { $0.point.name })
        knownBSSIDs = selection.retainedBSSIDs
    }

    func updateLocation(with scan: WiFiScan, previous: LocalizationFix?) -> LocalizationFix? {
        guard scan.hasBSSID else { return nil }
        guard !scan.isRapidResponse else { return previous }
        return predict(accessPoints: scan.accessPoints).map {
            LocalizationFix(prediction: $0, time: scan.endedAt)
        }
    }

    func predict(accessPoints: [AccessPoint]) -> KNNPrediction? {
        let observed = Fingerprint.signals(from: accessPoints).filter {
            knownBSSIDs.contains($0.key) && Fingerprint.isValidRSSI($0.value)
        }
        let requiredMatches = min(3, knownBSSIDs.count)
        guard canLocate, observed.count >= requiredMatches else { return nil }

        var bestByPoint: [GridPoint: KNNPrediction.Match] = [:]
        var winningMatch: KNNPrediction.Match?
        for fingerprint in fingerprints {
            let overlap = observed.keys.count { fingerprint.signals[$0] != nil }
            guard overlap >= requiredMatches else { continue }
            let distance = Fingerprint.meanSquaredDistance(observed, fingerprint.signals)
            if distance < (bestByPoint[fingerprint.point]?.distance ?? .infinity) {
                let match = KNNPrediction.Match(point: fingerprint.point, distance: distance, overlap: overlap)
                bestByPoint[fingerprint.point] = match
                if distance < (winningMatch?.distance ?? .infinity) { winningMatch = match }
            }
        }

        guard let winningMatch else { return nil }
        let closest = bestByPoint.values.sorted {
            if $0.point == $1.point { return false }
            if $0.point == winningMatch.point { return true }
            if $1.point == winningMatch.point { return false }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.point.index < $1.point.index
        }
        return KNNPrediction(point: winningMatch.point, closest: Array(closest.prefix(2)))
    }
}
