import AppKit
import CoreLocation
import Foundation
import SwiftUI

struct GridPoint: Hashable, Sendable {
    let index: Int

    var name: String { "P\(index + 1)" }
}

struct CollectionSession: Sendable {
    let id = UUID()
    let point: GridPoint
}

struct SampleStore {
    enum ValidationError: Error {
        case missingBSSID
    }

    enum SaveResult {
        case saved, duplicate, likelyCached
    }

    struct Reading: Equatable {
        let bssid: String
        let rssi: Int
    }

    struct StoredScan: Decodable {
        let pointId: String
        let scanEndedAtMs: Int64?
        let accessPoints: [AccessPoint]

        private enum CodingKeys: String, CodingKey {
            case pointId = "point_id"
            case scanEndedAtMs = "scan_ended_at_ms"
            case accessPoints = "access_points"
        }

    }

    let directory: URL

    init(directory: URL = Bundle.main.bundleURL
        .deletingLastPathComponent().appendingPathComponent("samples", isDirectory: true)) {
        self.directory = directory
    }

    static func scanFiles(in directory: URL) -> [URL] {
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        return (entries?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("scan-")
        }.sorted { $0.path < $1.path }
    }

    func latestFingerprint(at point: GridPoint) -> [Reading]? {
        let decoder = JSONDecoder()
        var latest: (time: Date, fingerprint: [Reading])?
        for file in Self.scanFiles(in: directory) {
            guard let data = try? Data(contentsOf: file),
                  let sample = try? decoder.decode(StoredScan.self, from: data),
                  sample.pointId == point.name else { continue }
            let fingerprint = Self.fingerprint(from: sample.accessPoints)
            guard !fingerprint.isEmpty else { continue }
            let time = sample.scanEndedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if let latest, time < latest.time { continue }
            latest = (time, fingerprint)
        }
        return latest?.fingerprint
    }

    func save(_ scan: WiFiScan, in session: CollectionSession, round: Int,
              previous: inout [Reading]?) throws -> SaveResult {
        let fingerprint = Self.fingerprint(from: scan.accessPoints)
        guard !fingerprint.isEmpty else { throw ValidationError.missingBSSID }
        if previous == fingerprint { return .duplicate }
        // A previous fingerprint is loaded from disk at session start for exact deduplication.
        // The rapid-response check only compares scans taken in this session.
        if round > 1, let previous,
           Self.isLikelyCached(duration: scan.endedAt.timeIntervalSince(scan.startedAt),
                               previous: previous, current: fingerprint) {
            return .likelyCached
        }

        let sessionPath = directory.appendingPathComponent(
            "\(session.point.name)-\(session.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionPath, withIntermediateDirectories: true)
        let file = sessionPath.appendingPathComponent(String(format: "scan-%06d.json", round))
        let sample = Sample(
            sessionId: session.id, pointId: session.point.name, round: round,
            scanStartedAtMs: Int64((scan.startedAt.timeIntervalSince1970 * 1000).rounded()),
            scanEndedAtMs: Int64((scan.endedAt.timeIntervalSince1970 * 1000).rounded()),
            accessPoints: scan.accessPoints)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sample).write(to: file, options: .atomic)
        previous = fingerprint
        return .saved
    }

    static func isLikelyCached(duration: TimeInterval, previous: [Reading], current: [Reading]) -> Bool {
        guard (0...WiFiScan.rapidResponseThreshold).contains(duration) else { return false }
        // A quick cache result can add APs and change a few RSSIs from the last saved scan.
        func strongestByBSSID(_ readings: [Reading]) -> [String: Int] {
            readings.reduce(into: [:]) { signals, reading in
                signals[reading.bssid] = max(signals[reading.bssid] ?? Int.min, reading.rssi)
            }
        }
        let baseline = strongestByBSSID(previous)
        guard baseline.count >= 3 else { return false }
        let latest = strongestByBSSID(current)
        let unchanged = baseline.count { latest[$0.key] == $0.value }
        return unchanged * 10 >= baseline.count * 9
    }

    static func fingerprint(from points: [AccessPoint]) -> [Reading] {
        points.compactMap { point -> Reading? in
            guard let bssid = point.bssid?.lowercased(), !bssid.isEmpty else { return nil }
            return Reading(bssid: bssid, rssi: point.rssi)
        }.sorted { ($0.bssid, $0.rssi) < ($1.bssid, $1.rssi) }
    }

    private struct Sample: Encodable {
        let sessionId: UUID
        let pointId: String
        let round: Int
        let scanStartedAtMs: Int64
        let scanEndedAtMs: Int64
        let accessPoints: [AccessPoint]
    }
}

@MainActor
final class CollectionModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var session: CollectionSession?
    @Published private(set) var isLocalizing = false
    @Published private(set) var training: WiFiKNN?
    @Published private(set) var localizationFix: LocalizationFix?
    @Published private(set) var isStopping = false
    @Published private(set) var isScanning = false
    @Published private(set) var latestScan: WiFiScan?
    @Published private(set) var latestScanInterval: TimeInterval?
    @Published private(set) var requestedRounds = 0
    @Published private(set) var skippedRounds = 0
    @Published private(set) var savedRounds = 0
    @Published private(set) var latestPoint: GridPoint?
    @Published private(set) var message: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// The point the Mac is really at during a live test. When set, each finished request is logged.
    @Published var truthPoint: GridPoint?
    /// Requests logged since the last start. The run stops by itself at `trialsPerPoint`.
    @Published private(set) var loggedTrials = 0
    static let trialsPerPoint = 5
    /// Prediction from the scans so far while the request is still unsure.
    @Published private(set) var pendingPrediction: KNNPrediction?
    @Published private(set) var pendingScanCount = 0
    /// Also treat a 5 GHz / all-band disagreement as unsure.
    @Published var requireBandAgreement = false

    private let scanner = WiFiScanner()
    private let store = SampleStore()
    private let location = CLLocationManager()
    private var scanTask: Task<Void, Never>?
    /// Last scan used for localization; an identical result is a cached repeat (same rule as collection).
    private var lastLocalizationReadings: [SampleStore.Reading]?
    private var pendingScans: [WiFiScan] = [] {
        didSet { pendingScanCount = pendingScans.count }
    }

    var liveTestDirectory: URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("live-tests", isDirectory: true)
    }

    var isRunning: Bool { session != nil || isLocalizing }

    override init() {
        super.init()
        location.delegate = self
        authorization = location.authorizationStatus
    }

    var authorizationNeeded: Bool {
        authorization != .authorizedAlways
    }

    var missingBSSID: Bool {
        guard let latestScan, !latestScan.accessPoints.isEmpty else { return false }
        return !latestScan.hasBSSID
    }

    func start(at point: GridPoint) {
        guard !isRunning else { return }
        let newSession = CollectionSession(point: point)
        session = newSession
        latestPoint = point
        latestScan = nil
        latestScanInterval = nil
        requestedRounds = 0
        skippedRounds = 0
        savedRounds = 0
        message = nil

        scanTask = Task { [weak self] in
            await self?.run(.collection(newSession))
        }
    }

    func showMode(localization: Bool) {
        latestScan = nil
        latestScanInterval = nil
        message = nil
        localizationFix = nil
        if localization { training = WiFiKNN(directory: store.directory) }
    }

    func startLocalization() {
        guard !isRunning else { return }
        let model = WiFiKNN(directory: store.directory)
        training = model
        guard model.canLocate else { return }
        isLocalizing = true
        localizationFix = nil
        pendingScans = []
        pendingPrediction = nil
        loggedTrials = 0
        lastLocalizationReadings = nil
        latestScan = nil
        latestScanInterval = nil
        message = nil
        scanTask = Task { [weak self] in
            await self?.run(.localization(model))
        }
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        // The hardware scan may finish after cancellation. Its point remains locked until it is saved.
        scanTask?.cancel()
    }

    var sampleDirectory: URL { store.directory }

    func openSamples() {
        let directory = store.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    func requestLocation() {
        if authorization == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorization = location.authorizationStatus
        }
    }

    private enum ScanMode {
        case collection(CollectionSession)
        case localization(WiFiKNN)
    }

    private func run(_ mode: ScanMode) async {
        defer {
            session = nil
            isLocalizing = false
            isStopping = false
            isScanning = false
            scanTask = nil
        }

        var previous: [SampleStore.Reading]?
        if case .collection(let current) = mode {
            previous = store.latestFingerprint(at: current.point)
        }

        while !Task.isCancelled {
            if case .collection = mode { requestedRounds += 1 }
            isScanning = true
            var scan: WiFiScan?
            do {
                scan = try await scanner.scan()
            } catch {
                if case .collection = mode { skippedRounds += 1 }
                message = "扫描失败，将自动重试。\(error.localizedDescription)"
                localizationFix = nil
            }
            isScanning = false

            if let scan {
                latestScanInterval = latestScan.map { max(0, scan.endedAt.timeIntervalSince($0.endedAt)) }
                latestScan = scan
                switch mode {
                case .collection(let current):
                    do {
                        try save(scan, in: current, previous: &previous)
                    } catch {
                        skippedRounds += 1
                        message = "保存失败，采集已停止。\(error.localizedDescription)"
                        return
                    }
                case .localization:
                    if Task.isCancelled { return }
                    locate(with: scan)
                }
            }

            guard scan?.hasBSSID != true else { continue }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    /// One request = 1…maxScans scans. Rescan while unsure, then publish the fix and start a new request.
    private func locate(with scan: WiFiScan) {
        guard let model = training else { return }
        guard scan.hasBSSID else {
            message = "本轮没有 BSSID。请检查 macOS 定位权限。"
            return
        }
        guard !scan.isRapidResponse else {
            message = nil
            return
        }
        let readings = SampleStore.fingerprint(from: scan.accessPoints)
        guard readings != lastLocalizationReadings else {
            message = "本轮与上一次扫描完全相同（疑似缓存），已跳过。"
            return
        }
        lastLocalizationReadings = readings
        pendingScans.append(scan)
        let prediction = model.predict(scans: pendingScans.map(\.accessPoints))
        message = prediction == nil ? "与指纹库重合的接入点太少。" : nil
        guard WiFiKNN.isFinished(prediction, scanCount: pendingScans.count,
                                 requireAgreement: requireBandAgreement) else {
            pendingPrediction = prediction
            return
        }
        if let prediction {
            localizationFix = LocalizationFix(prediction: prediction, time: scan.endedAt)
        }
        logTrial(prediction, unsure: prediction?.isConfident(requireAgreement: requireBandAgreement) != true)
        pendingScans = []
        pendingPrediction = nil
        if truthPoint != nil, loggedTrials >= Self.trialsPerPoint {
            NSSound(named: "Glass")?.play()
            stop()
        }
    }

    private func logTrial(_ prediction: KNNPrediction?, unsure: Bool) {
        guard let truthPoint, let first = pendingScans.first, let last = pendingScans.last else { return }
        func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        let trial = LiveTrial(
            truth: truthPoint.name, predicted: prediction?.point.name,
            correct: prediction?.point == truthPoint, ratio: prediction?.ratio,
            band: prediction?.band.rawValue, scanCount: pendingScans.count,
            threshold: WiFiKNN.confidenceThreshold,
            bandAgreementRequired: requireBandAgreement, bandsAgree: prediction?.bandsAgree,
            unsure: unsure,
            latencyS: last.endedAt.timeIntervalSince(first.startedAt),
            scans: pendingScans.map {
                LiveTrial.Scan(startedAtMs: ms($0.startedAt), endedAtMs: ms($0.endedAt),
                               accessPoints: $0.accessPoints)
            })
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = .sortedKeys
            var line = try encoder.encode(trial)
            line.append(0x0A)
            try FileManager.default.createDirectory(at: liveTestDirectory, withIntermediateDirectories: true)
            let day = first.startedAt.formatted(.iso8601.year().month().day())
            let file = liveTestDirectory.appendingPathComponent("live-\(day).jsonl")
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
            loggedTrials += 1
        } catch {
            message = "实时测试记录写入失败：\(error.localizedDescription)"
        }
    }

    private struct LiveTrial: Encodable {
        struct Scan: Encodable {
            let startedAtMs: Int64
            let endedAtMs: Int64
            let accessPoints: [AccessPoint]
        }

        let truth: String
        let predicted: String?
        let correct: Bool
        let ratio: Double?
        let band: String?
        let scanCount: Int
        let threshold: Double
        let bandAgreementRequired: Bool
        let bandsAgree: Bool?
        /// Still unsure after the last scan.
        let unsure: Bool
        let latencyS: Double
        let scans: [Scan]
    }

    private func save(_ scan: WiFiScan, in current: CollectionSession,
                      previous: inout [SampleStore.Reading]?) throws {
        if scan.accessPoints.isEmpty {
            skippedRounds += 1
            message = "本轮未检测到接入点，已跳过。请检查 Wi-Fi 和定位权限，程序会自动重试。"
            return
        }
        let nextRound = savedRounds + 1
        do {
            switch try store.save(scan, in: current, round: nextRound, previous: &previous) {
            case .saved:
                savedRounds = nextRound
                message = nil
            case .duplicate:
                skippedRounds += 1
                message = nil
            case .likelyCached:
                skippedRounds += 1
                message = "本轮返回过快，且绝大多数接入点读数与上一条样本相同，已跳过疑似缓存。"
            }
        } catch SampleStore.ValidationError.missingBSSID {
            skippedRounds += 1
            message = "本轮没有 BSSID，已跳过。请在系统设置的「隐私与安全性 → 定位服务」检查 Wi-Fi RSSI Collector 的权限。"
        }
    }
}
