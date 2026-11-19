import SwiftUI

@main
struct WiFiRSSIApp: App {
    var body: some Scene {
        Window("Wi-Fi RSSI 采集器", id: "collector") {
            CollectorView()
        }
        .defaultSize(width: 1040, height: 635)
    }
}

private struct CollectorView: View {
    @StateObject private var model = CollectionModel()
    @AppStorage("xSpacingM") private var xSpacingInput = "1"
    @AppStorage("zSpacingM") private var zSpacingInput = "1"
    @AppStorage("quickCollectionMode") private var quickMode = false
    @AppStorage("quickPointA") private var quickPointA = 0
    @AppStorage("quickPointB") private var quickPointB = 8
    @State private var selected: Int?
    @State private var localization = false

    private var xSpacing: Double { Double(xSpacingInput) ?? 0 }
    private var zSpacing: Double { Double(zSpacingInput) ?? 0 }

    private var validSpacing: Bool {
        xSpacing.isFinite && zSpacing.isFinite && xSpacing > 0 && zSpacing > 0 &&
            xSpacing <= Double.greatestFiniteMagnitude / 2 && zSpacing <= Double.greatestFiniteMagnitude / 2
    }

    private var selectedPoint: GridPoint? {
        guard let selected, isAvailable(selected), validSpacing else { return nil }
        return point(selected)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if localization {
                    localizationPanel.frame(width: 344)
                    Divider()
                    LocalizationMap(references: model.training?.references ?? [], prediction: model.prediction)
                } else {
                    pointPanel.frame(width: 344)
                    Divider()
                    scanPanel
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 930, minHeight: 605)
        .onDisappear(perform: model.stop)
        .onChange(of: localization) { model.showMode(localization: $0) }
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
            Picker("工作模式", selection: $localization) {
                Text("采集").tag(false)
                Text("实时定位").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .disabled(model.isRunning)
            Spacer()
            Button(action: model.openSamples) {
                Label("打开样本文件夹", systemImage: "folder")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var localizationPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("加权 KNN（k = 3）", systemImage: "location.viewfinder")
                .font(.headline)
            if let training = model.training {
                Text("指纹库 · \(training.sampleCount) 轮 · \(training.references.count) 个参考点")
                    .foregroundStyle(.secondary)
                if training.ignoredCount > 0 {
                    Text("已跳过 \(training.ignoredCount) 份无效样本")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !training.canLocate {
                    Text("需要至少两个不同坐标的有效样本。")
                        .foregroundStyle(.orange)
                }
            }

            Divider()
            Text("估计坐标 (X, Z)").font(.caption).foregroundStyle(.secondary)
            if let prediction = model.prediction {
                Text(coordinate(prediction.position))
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("最相似参考点 \(prediction.nearestReference) · 重合 AP \(prediction.matchedAccessPoints) 个")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.isLocalizing ? "等待有效扫描…" : "启动后随扫描更新")
                    .foregroundStyle(.secondary)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.training?.references.count == 2 {
                Text("两个参考点时，估计位置会沿两点之间的虚线移动。")
                    .font(.caption).foregroundStyle(.secondary)
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
            HStack {
                Text("教室点位").font(.headline)
                Spacer()
                Text("X 向右 · Z 向下").font(.caption).foregroundStyle(.secondary)
            }
            pointModeControls
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(0..<9) { index in
                    pointButton(index)
                }
            }
            .disabled(model.session != nil)

            HStack(spacing: 14) {
                spacingField("X 间距", value: $xSpacingInput)
                spacingField("Z 间距", value: $zSpacingInput)
            }
            .disabled(model.session != nil)
            Text(validSpacing ? "坐标单位为米。采集时将 Mac 放在所选方块的实测中心。" : "X 和 Z 间距都必须是大于零的数。")
                .font(.caption)
                .foregroundStyle(validSpacing ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
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
                        if let selectedPoint { model.start(at: selectedPoint) }
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
                Text(point(index).name).tag(index)
            }
        }
        .pickerStyle(.menu)
    }

    private func isAvailable(_ index: Int) -> Bool {
        !quickMode || index == quickPointA || index == quickPointB
    }

    private func pointButton(_ index: Int) -> some View {
        let point = point(index)
        let available = isAvailable(index)
        let isSelected = available && index == selected
        return Button {
            selected = index
        } label: {
            VStack(spacing: 4) {
                Text(point.name).font(.system(.body, design: .monospaced).weight(.semibold))
                Text(validSpacing ? coordinate(point) : "—")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
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
        .accessibilityLabel("\(point.name) \(validSpacing ? coordinate(point) : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func spacingField(_ title: String, value: Binding<String>) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 45, maxWidth: 65)
            Text("m").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scanPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("接入点读数").font(.headline)
                    if let point = model.latestPoint {
                        Text("\(point.name) · \(coordinate(point)) m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("已保存 \(model.savedRounds) 轮")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
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
                if let scan = model.latestScan {
                    let time = scan.endedAt.formatted(date: .omitted, time: .standard)
                    let elapsed = scan.endedAt.timeIntervalSince(scan.startedAt)
                        .formatted(.number.precision(.fractionLength(2)))
                    Text("上次扫描 \(time) · 耗时 \(elapsed) 秒")
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

    private func point(_ index: Int) -> GridPoint {
        GridPoint(index: index, xM: Double(index % 3) * xSpacing, zM: Double(index / 3) * zSpacing)
    }

    private func coordinate(_ point: GridPoint) -> String {
        coordinate(FloorPosition(x: point.xM, z: point.zM))
    }

    private func coordinate(_ point: FloorPosition) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
        return "(\(point.x.formatted(format)), \(point.z.formatted(format)))"
    }
}

private struct ScanRow: Identifiable {
    let id: Int
    let point: AccessPoint
}
