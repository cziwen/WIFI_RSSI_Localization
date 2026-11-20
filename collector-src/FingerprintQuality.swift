import Accelerate
import Foundation

struct FingerprintComparison: Sendable {
    let reports: [FingerprintFilter: FingerprintQuality]

    init(directory: URL) {
        let dataset = FingerprintDataset(directory: directory, collectMetadata: true)
        reports = Dictionary(uniqueKeysWithValues: FingerprintFilter.allCases.map {
            ($0, FingerprintQuality(dataset: dataset, filter: $0))
        })
    }
}

struct FingerprintQuality: Sendable {
    struct PointSummary: Identifiable, Sendable {
        let point: GridPoint
        let originalCount: Int
        let sampleCount: Int
        let sparseCount: Int

        var id: GridPoint { point }
    }

    struct PlotPoint: Identifiable, Sendable {
        let id: Int
        let label: String
        let x: Double
        let y: Double
    }

    let points: [PointSummary]
    let features: [FingerprintSelection.Feature]
    let sampleCount: Int
    let originalCount: Int
    let invalidFiles: Int
    let duplicateFiles: Int
    let invalidReadings: Int
    let emptyFingerprints: Int
    let mergedFingerprints: Int
    let plot: [PlotPoint]

    var featureCount: Int { features.count(where: \.retained) }

    init(dataset: FingerprintDataset, filter: FingerprintFilter) {
        let selection = FingerprintSelection(dataset: dataset, filter: filter)
        features = selection.features.sorted {
            if $0.retained != $1.retained { return $0.retained }
            if $0.selectionCoverage != $1.selectionCoverage { return $0.selectionCoverage > $1.selectionCoverage }
            return $0.id < $1.id
        }

        let selectedGroups = Dictionary(grouping: selection.fingerprints, by: \.point)
        points = selection.points.map { point in
            let group = selectedGroups[point.point] ?? []
            return PointSummary(point: point.point, originalCount: point.count, sampleCount: group.count,
                                sparseCount: group.count(where: { $0.signals.count < 3 }))
        }

        sampleCount = selection.fingerprints.count
        originalCount = dataset.fingerprints.count
        invalidFiles = dataset.ignoredCount
        duplicateFiles = dataset.duplicateCount
        invalidReadings = selection.invalidReadings
        emptyFingerprints = selection.emptyFingerprints
        mergedFingerprints = selection.mergedFingerprints

        // Limit the quadratic projection while retaining representation from small groups.
        let plotLimit = 360
        let orderedGroups = selectedGroups.values.sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0[0].point.index < $1[0].point.index
        }
        var remaining = plotLimit
        let plotted = orderedGroups.enumerated().flatMap { index, group -> [Fingerprint] in
            let count = min(group.count, remaining / (orderedGroups.count - index))
            remaining -= count
            if count == 1 { return [group[group.count / 2]] }
            return (0..<count).map { group[$0 * (group.count - 1) / (count - 1)] }
        }
        plot = Task.isCancelled ? [] : Self.project(plotted)
    }

    /// Classical MDS embeds the classifier's pairwise RSSI distances using two positive eigenvalues.
    /// All pairs are plotted, including those with too little overlap to vote in the classifier.
    private static func project(_ fingerprints: [Fingerprint]) -> [PlotPoint] {
        let count = fingerprints.count
        guard count > 0 else { return [] }
        var matrix = [Double](repeating: 0, count: count * count)
        var means = [Double](repeating: 0, count: count)
        for row in 0..<count {
            if Task.isCancelled { return [] }
            for column in 0..<row {
                let distance = Fingerprint.meanSquaredDistance(fingerprints[row].signals, fingerprints[column].signals)
                matrix[row * count + column] = distance
                matrix[column * count + row] = distance
                means[row] += distance
                means[column] += distance
            }
        }
        means = means.map { $0 / Double(count) }
        let overall = means.reduce(0, +) / Double(count)
        for row in 0..<count {
            for column in 0..<count {
                let index = row * count + column
                matrix[index] = -0.5 * (matrix[index] - means[row] - means[column] + overall)
            }
        }

        var job = Int8(86) // V: eigenvalues and eigenvectors.
        var triangle = Int8(85) // U: read the upper triangle.
        var order = __CLPK_integer(count)
        var leadingDimension = order
        var eigenvalues = [Double](repeating: 0, count: count)
        var workSize = max(1, 3 * order - 1)
        var workspace = [Double](repeating: 0, count: Int(workSize))
        var status: __CLPK_integer = 0
        dsyev_(&job, &triangle, &order, &matrix, &leadingDimension, &eigenvalues,
               &workspace, &workSize, &status)
        guard status == 0 else { return [] }

        let primary = sqrt(max(0, eigenvalues[count - 1]))
        let secondary = count >= 2 ? sqrt(max(0, eigenvalues[count - 2])) : 0
        return fingerprints.indices.map { index in
            PlotPoint(id: index, label: fingerprints[index].point.name,
                      x: matrix[(count - 1) * count + index] * primary,
                      y: count >= 2 ? matrix[(count - 2) * count + index] * secondary : 0)
        }
    }
}
