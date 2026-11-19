import AppKit
import CoreLocation
import Foundation
import SwiftUI

struct GridPoint: Sendable {
    let index: Int
    let xM: Double
    let zM: Double

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

    let directory: URL

    init(directory: URL = Bundle.main.bundleURL
        .deletingLastPathComponent().appendingPathComponent("samples", isDirectory: true)) {
        self.directory = directory
    }

    func save(_ scan: WiFiScan, in session: CollectionSession, round: Int) throws {
        guard scan.hasBSSID else { throw ValidationError.missingBSSID }

        let sessionPath = directory.appendingPathComponent(
            "\(session.point.name)-\(session.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionPath, withIntermediateDirectories: true)
        let file = sessionPath.appendingPathComponent(String(format: "scan-%06d.json", round))
        let sample = Sample(
            sessionId: session.id, pointId: session.point.name, round: round,
            xM: session.point.xM, zM: session.point.zM,
            scanStartedAtMs: Int64((scan.startedAt.timeIntervalSince1970 * 1000).rounded()),
            scanEndedAtMs: Int64((scan.endedAt.timeIntervalSince1970 * 1000).rounded()),
            accessPoints: scan.accessPoints)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sample).write(to: file, options: .atomic)
    }

    private struct Sample: Encodable {
        let sessionId: UUID
        let pointId: String
        let round: Int
        let xM: Double
        let zM: Double
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
    @Published private(set) var prediction: KNNPrediction?
    @Published private(set) var isStopping = false
    @Published private(set) var isScanning = false
    @Published private(set) var latestScan: WiFiScan?
    @Published private(set) var savedRounds = 0
    @Published private(set) var latestPoint: GridPoint?
    @Published private(set) var message: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let scanner = WiFiScanner()
    private let store = SampleStore()
    private let location = CLLocationManager()
    private var scanTask: Task<Void, Never>?

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
        savedRounds = 0
        message = nil

        scanTask = Task { [weak self] in
            await self?.run(.collection(newSession))
        }
    }

    func showMode(localization: Bool) {
        latestScan = nil
        message = nil
        prediction = nil
        if localization { training = WiFiKNN(directory: store.directory) }
    }

    func startLocalization() {
        guard !isRunning else { return }
        let model = WiFiKNN(directory: store.directory)
        training = model
        guard model.canLocate else { return }
        isLocalizing = true
        prediction = nil
        latestScan = nil
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

        var delayAfterScan: Duration {
            switch self {
            case .collection: return .seconds(3)
            case .localization: return .seconds(1)
            }
        }
    }

    private func run(_ mode: ScanMode) async {
        defer {
            session = nil
            isLocalizing = false
            isStopping = false
            isScanning = false
            scanTask = nil
        }

        while !Task.isCancelled {
            isScanning = true
            var scan: WiFiScan?
            do {
                scan = try await scanner.scan()
            } catch {
                message = "扫描失败，将自动重试。\(error.localizedDescription)"
                prediction = nil
            }
            isScanning = false

            if let scan {
                latestScan = scan
                switch mode {
                case .collection(let current):
                    do {
                        try save(scan, in: current)
                    } catch {
                        message = "保存失败，采集已停止。\(error.localizedDescription)"
                        return
                    }
                case .localization(let model):
                    if Task.isCancelled { return }
                    prediction = model.predict(accessPoints: scan.accessPoints)
                    if !scan.hasBSSID {
                        message = "本轮没有 BSSID。请检查 macOS 定位权限。"
                    } else if prediction == nil {
                        message = "本轮与指纹库重合的接入点太少，等待下一次扫描。"
                    } else {
                        message = nil
                    }
                }
            }

            let delay = scan?.hasBSSID == true ? mode.delayAfterScan : .seconds(3)
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func save(_ scan: WiFiScan, in current: CollectionSession) throws {
        if scan.accessPoints.isEmpty {
            message = "本轮未检测到接入点，已跳过。请检查 Wi-Fi 和定位权限，程序会自动重试。"
            return
        }
        let nextRound = savedRounds + 1
        do {
            try store.save(scan, in: current, round: nextRound)
            savedRounds = nextRound
            message = nil
        } catch SampleStore.ValidationError.missingBSSID {
            message = "本轮没有 BSSID，已跳过。请在系统设置的「隐私与安全性 → 定位服务」检查 Wi-Fi RSSI Collector 的权限。"
        }
    }
}
