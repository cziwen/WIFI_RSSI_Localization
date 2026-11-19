import CoreWLAN
import Foundation

struct AccessPoint: Codable, Sendable {
    let ssid: String?
    let bssid: String?
    let rssi: Int
    let channel: Int?

    private enum CodingKeys: String, CodingKey {
        case ssid, bssid, rssi, channel
    }

    init(_ network: CWNetwork) {
        ssid = network.ssid.flatMap { $0.isEmpty ? nil : $0 }
        bssid = network.bssid.flatMap { $0.isEmpty ? nil : $0 }
        rssi = network.rssiValue
        channel = network.wlanChannel?.channelNumber
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ssid, forKey: .ssid)
        try fields.encode(bssid, forKey: .bssid)
        try fields.encode(rssi, forKey: .rssi)
        try fields.encodeIfPresent(channel, forKey: .channel)
    }
}

struct WiFiScan: Sendable {
    let startedAt: Date
    let endedAt: Date
    let accessPoints: [AccessPoint]

    var hasBSSID: Bool {
        accessPoints.contains { !($0.bssid?.isEmpty ?? true) }
    }
}

struct WiFiScanner {
    private let queue = DispatchQueue(label: "local.wifirssi.collector.scan")

    func scan() async throws -> WiFiScan {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard let interface = CWWiFiClient.shared().interface() else {
                        throw ScanError.noInterface
                    }
                    guard interface.powerOn() else { throw ScanError.wifiOff }
                    let startedAt = Date()
                    let networks = try interface.scanForNetworks(withName: nil)
                    let endedAt = Date()
                    let accessPoints = networks.map(AccessPoint.init).sorted { $0.rssi > $1.rssi }
                    return WiFiScan(startedAt: startedAt, endedAt: endedAt, accessPoints: accessPoints)
                })
            }
        }
    }

    private enum ScanError: LocalizedError {
        case noInterface, wifiOff

        var errorDescription: String? {
            switch self {
            case .noInterface: return "找不到 Wi-Fi 接口。"
            case .wifiOff: return "Wi-Fi 已关闭。请在控制中心打开 Wi-Fi。"
            }
        }
    }
}
