import Foundation

struct KNNPrediction {
    let point: GridPoint
    let closest: [Match]
    let band: Band
    let scanCount: Int

    enum Band: String {
        case fiveGHz = "5 GHz", all = "全部频段"
    }

    struct Match {
        let point: GridPoint
        let distance: Double
        let overlap: Int
    }

    /// r = RMS distance to the best label / RMS distance to the second-best label. Smaller is surer.
    /// A single matching label gives no runner-up, so it counts as unsure (1).
    var ratio: Double {
        guard closest.count >= 2, closest[1].distance > 0 else { return 1 }
        return (closest[0].distance / closest[1].distance).squareRoot()
    }

    var isConfident: Bool { ratio < WiFiKNN.confidenceThreshold }
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
    /// τ: stop scanning once r < τ. Smaller τ = more rescans, higher accuracy, longer wait.
    static let confidenceThreshold = 0.9
    static let maxScans = 3

    let references: Set<String>
    let sampleCount: Int
    let ignoredCount: Int
    let duplicateCount: Int

    private let fingerprints: [Fingerprint]
    private let knownBSSIDs: Set<String>
    private let fiveGHzFingerprints: [Fingerprint]
    private let fiveGHzBSSIDs: Set<String>

    var featureCount: Int { knownBSSIDs.count }
    var fiveGHzCount: Int { fiveGHzBSSIDs.count }

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
        // ponytail: channels 1/5/9 are shared by 2.4 and 6 GHz; CoreWLAN's channelBand would separate them.
        let fiveGHz = knownBSSIDs.filter { (data.channels[$0] ?? 0) > 14 }
        fiveGHzBSSIDs = fiveGHz
        fiveGHzFingerprints = fingerprints.compactMap { fingerprint in
            let signals = fingerprint.signals.filter { fiveGHz.contains($0.key) }
            return signals.isEmpty ? nil : Fingerprint(point: fingerprint.point, signals: signals)
        }
    }

    /// Averages each AP over the scans that heard it (combining repeated measurements).
    static func combine(_ scans: [[AccessPoint]]) -> [String: Double] {
        var readings: [String: [Int]] = [:]
        for scan in scans {
            for (bssid, rssi) in Fingerprint.signals(from: scan) where Fingerprint.isValidRSSI(rssi) {
                readings[bssid, default: []].append(rssi)
            }
        }
        return readings.mapValues { Double($0.reduce(0, +)) / Double($0.count) }
    }

    /// Matches on 5 GHz first; falls back to all bands when 5 GHz cannot rank at least two labels.
    func predict(scans: [[AccessPoint]]) -> KNNPrediction? {
        let observed = Self.combine(scans)
        if let fiveGHz = match(observed, in: fiveGHzFingerprints, bssids: fiveGHzBSSIDs,
                               band: .fiveGHz, scanCount: scans.count),
           fiveGHz.closest.count >= 2 {
            return fiveGHz
        }
        return match(observed, in: fingerprints, bssids: knownBSSIDs, band: .all, scanCount: scans.count)
    }

    /// A request is finished when the prediction is confident, or no more scans are allowed.
    static func isFinished(_ prediction: KNNPrediction?, scanCount: Int) -> Bool {
        prediction?.isConfident == true || scanCount >= maxScans
    }

    private func match(_ signals: [String: Double], in fingerprints: [Fingerprint], bssids: Set<String>,
                       band: KNNPrediction.Band, scanCount: Int) -> KNNPrediction? {
        let observed = signals.filter { bssids.contains($0.key) }
        let requiredMatches = min(3, bssids.count)
        guard canLocate, requiredMatches > 0, observed.count >= requiredMatches else { return nil }

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
        return KNNPrediction(point: winningMatch.point, closest: Array(closest.prefix(2)),
                             band: band, scanCount: scanCount)
    }
}
