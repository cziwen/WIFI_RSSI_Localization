import SwiftUI

@main
struct WiFiRSSIApp: App {
    var body: some Scene {
        Window("Wi-Fi RSSI 采集器", id: "collector") {
            CollectorView()
        }
        .defaultSize(width: 1040, height: 665)
    }
}

private struct CollectorView: View {
    @StateObject private var model = CollectionModel()
    @AppStorage("quickCollectionMode") private var quickMode = false
    @AppStorage("quickPointA") private var quickPointA = 0
    @AppStorage("quickPointB") private var quickPointB = 8
    @State private var selected: Int?
    @State private var mode = Mode.collection

    private enum Mode {
        case collection, localization, quality
    }

    private var localization: Bool { mode == .localization }

    private var selectedPoint: GridPoint? {
        guard let selected, isAvailable(selected) else { return nil }
        return GridPoint(index: selected)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if mode == .quality {
                    FingerprintQualityView(directory: model.sampleDirectory)
                } else if localization {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fix = model.localizationFix
                        let current = fix?.isCurrent(at: context.date) == true
                        HStack(spacing: 0) {
                            localizationPanel(fix: fix, current: current).frame(width: 344)
                            Divider()
                            LocalizationMap(references: model.training?.references ?? [],
                                            match: current ? fix?.prediction.point.name : nil)
                        }
                    }
                } else {
                    pointPanel.frame(width: 344)
                    Divider()
                    scanPanel
                }
            }
            if mode != .quality {
                Divider()
                footer
            }
        }
        .frame(minWidth: 930, minHeight: 640)
        .onDisappear(perform: model.stop)
        .onChange(of: mode) { model.showMode(localization: $0 == .localization) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Wi-Fi RSSI 采集器").font(.title2.weight(.semibold))
                Text("采集 Wi-Fi 指纹与室内定位").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("工作模式", selection: $mode) {
                Text("采集").tag(Mode.collection)
                Text("实时定位").tag(Mode.localization)
                Text("数据检查").tag(Mode.quality)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            .disabled(model.isRunning)
            Spacer()
            Button(action: model.openSamples) {
                Label("打开样本文件夹", systemImage: "folder")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func localizationPanel(fix: LocalizationFix?, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("\(WiFiKNN.neighborCount)-NN 分类", systemImage: "location.viewfinder")
                .font(.headline)
            if let training = model.training {
                Text("\(WiFiKNN.featureFilter.rawValue) · \(training.featureCount) 个 AP")
                    .foregroundStyle(.secondary)
                Text("指纹库 · \(training.sampleCount) 条指纹 · \(training.references.count) 个参考点")
                    .foregroundStyle(.secondary)
                if training.duplicateCount > 0 {
                    Text("已合并 \(training.duplicateCount) 条重复指纹")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if training.ignoredCount > 0 {
                    Text("已跳过 \(training.ignoredCount) 份无效样本")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !training.canLocate {
                    Text("需要至少两个参考点的有效样本。")
                        .foregroundStyle(.orange)
                }
            }

            Divider()
            Text("预测点位").font(.caption).foregroundStyle(.secondary)
            if let fix, current {
                Text(fix.prediction.point.name)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                ForEach(fix.prediction.closest, id: \.point) { match in
                    let distance = sqrt(match.distance).formatted(.number.precision(.fractionLength(1)))
                    Text("\(match.point.name) · 距离 \(distance) · 重合 \(match.overlap) 个 AP")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.isLocalizing ? "等待有效扫描…" : "启动后随扫描更新")
                    .foregroundStyle(.secondary)
            }
            if let fix {
                Text("上次有效定位 \(fix.time.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.isLocalizing && model.latestScan?.isRapidResponse == true {
                Text("已跳过快速返回，等待下一轮有效扫描。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isLocalizing {
                Button(action: model.stop) {
                    Label(model.isStopping ? "正在停止…" : "停止定位", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isStopping)
            } else {
                Button(action: model.startLocalization) {
                    Label("开始定位", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.training?.canLocate != true)
            }
        }
        .controlSize(.large)
        .padding(20)
        .background(.quaternary.opacity(0.28))
    }

    private var pointPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("教室点位").font(.headline)
            pointModeControls
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(0..<9) { index in
                    pointButton(index)
                }
            }
            .disabled(model.session != nil)

            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if model.session != nil {
                    Button(action: model.stop) {
                        Label(model.isStopping ? "正在停止…" : "停止采集", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isStopping)
                } else {
                    Button {
                        if let selectedPoint {
                            model.start(at: selectedPoint)
                        }
                    } label: {
                        Label("开始采集", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPoint == nil)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .background(.quaternary.opacity(0.28))
    }

    private var pointModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("采集点位数量", selection: $quickMode) {
                Text("2 点快速测试").tag(true)
                Text("9 点采集").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if quickMode {
                HStack(spacing: 12) {
                    quickPointPicker("点位 A", selection: $quickPointA, excluding: quickPointB)
                    quickPointPicker("点位 B", selection: $quickPointB, excluding: quickPointA)
                }
                .controlSize(.small)
            }
        }
        .disabled(model.session != nil)
    }

    private func quickPointPicker(_ label: String, selection: Binding<Int>, excluding other: Int) -> some View {
        Picker(label, selection: selection) {
            ForEach((0..<9).filter { $0 != other }, id: \.self) { index in
                Text(GridPoint(index: index).name).tag(index)
            }
        }
        .pickerStyle(.menu)
    }

    private func isAvailable(_ index: Int) -> Bool {
        !quickMode || index == quickPointA || index == quickPointB
    }

    private func pointButton(_ index: Int) -> some View {
        let point = GridPoint(index: index)
        let available = isAvailable(index)
        let isSelected = available && index == selected
        return Button {
            selected = index
        } label: {
            Text(point.name)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.20),
                                  lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.5)
        .disabled(!available)
        .accessibilityLabel(point.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var scanPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("接入点读数").font(.headline)
                    if let point = model.latestPoint {
                        Text(point.name)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    Text("请求 \(model.requestedRounds) 轮")
                    Text("跳过 \(model.skippedRounds) 轮")
                    Text("已保存 \(model.savedRounds) 轮").fontWeight(.semibold)
                }
                .font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            Divider()

            if let points = model.latestScan?.accessPoints, !points.isEmpty {
                scanTable(points)
            } else {
                VStack(spacing: 9) {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Text(model.isScanning ? "正在扫描附近的 Wi-Fi…" :
                         "选择方块并开始采集后，扫描结果会显示在这里。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = model.message {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func scanTable(_ points: [AccessPoint]) -> some View {
        Table(points.indices.map { ScanRow(id: $0, point: points[$0]) }) {
            TableColumn("网络名称（SSID）") { (row: ScanRow) in
                Text(row.point.ssid ?? "未提供名称").lineLimit(1)
            }.width(min: 110, ideal: 155)
            TableColumn("接入点（BSSID）") { (row: ScanRow) in
                Text(row.point.bssid ?? "—").monospaced().foregroundStyle(.secondary)
            }.width(min: 128, ideal: 150)
            TableColumn("信道") { (row: ScanRow) in
                Text(row.point.channel.map(String.init) ?? "—").monospacedDigit()
            }.width(min: 48, ideal: 56)
            TableColumn("RSSI") { (row: ScanRow) in
                Text("\(row.point.rssi) dBm").monospaced().fontWeight(.semibold)
            }.width(min: 73, ideal: 83)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if model.authorizationNeeded || model.missingBSSID {
                HStack {
                    Label(localization ? "允许定位以读取 BSSID，才能匹配指纹库。" :
                          "允许定位以读取 SSID 和 BSSID。整轮没有 BSSID 时会跳过保存。",
                          systemImage: "location")
                    Spacer()
                    Button(model.authorization == .notDetermined ? "允许定位" : "打开系统设置",
                           action: model.requestLocation)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                Divider()
            }
            HStack {
                Circle().fill(model.message != nil ? Color.orange : !model.isRunning ? .secondary : .green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(status)
                Spacer()
                if let interval = model.latestScanInterval {
                    let seconds = interval.formatted(.number.precision(.fractionLength(2)))
                    Text("API 返回间隔 \(seconds) 秒")
                        .monospacedDigit()
                }
                if let scan = model.latestScan {
                    let time = scan.endedAt.formatted(date: .omitted, time: .standard)
                    let elapsed = scan.endedAt.timeIntervalSince(scan.startedAt)
                        .formatted(.number.precision(.fractionLength(2)))
                    Text("上次 API 返回 \(time) · 耗时 \(elapsed) 秒")
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var status: String {
        if model.isStopping { return "本轮结束后停止" }
        if model.isScanning { return "正在扫描" }
        if model.isRunning { return "等待下一轮" }
        if localization { return "待定位" }
        return model.latestPoint == nil ? "待采集" : "采集已停止"
    }


}

private struct ScanRow: Identifiable {
    let id: Int
    let point: AccessPoint
}
