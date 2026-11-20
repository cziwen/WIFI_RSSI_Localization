import Charts
import SwiftUI

struct FingerprintQualityView: View {
    let directory: URL

    private let coverageRule = "至少一个已采点位的检出率达到 50% 时保留。"

    @State private var filter = FingerprintFilter.baseline
    @State private var comparison: FingerprintComparison?
    @State private var showFeatures = false
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let report = comparison?.reports[filter] {
                if report.originalCount == 0 {
                    emptyReport(report)
                } else {
                    HStack(spacing: 0) {
                        detail(report)
                        Divider()
                        sidebar(report)
                    }
                }
            } else {
                ProgressView("正在分析本地样本…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: refresh) {
            comparison = nil
            let job = Task.detached(priority: .userInitiated) {
                FingerprintComparison(directory: directory)
            }
            let result = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            if !Task.isCancelled { comparison = result }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("特征筛选方案", selection: $filter) {
                ForEach(FingerprintFilter.allCases) { filter in
                    Text(filterTitle(filter)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 420)
            Spacer()
            Button {
                refresh += 1
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
            }
            .disabled(comparison == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func filterTitle(_ option: FingerprintFilter) -> String {
        guard let report = comparison?.reports[option], report.originalCount > 0 else {
            return option.rawValue
        }
        return "\(option.rawValue) · \(report.featureCount) AP / \(report.sampleCount) 指纹"
    }

    private func emptyReport(_ report: FingerprintQuality) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.dots.scatter").font(.title)
            Text("还没有可分析的 Wi-Fi 指纹").font(.headline)
            if report.invalidFiles > 0 {
                Text("有 \(report.invalidFiles) 个无效扫描文件。请检查点位标签与 BSSID。")
            } else {
                Text("先采集样本，再回到这里检查分布。")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ report: FingerprintQuality) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(showFeatures ? "接入点检出率" : "Wi-Fi 指纹分布").font(.headline)
                Spacer()
                Picker("检查内容", selection: $showFeatures) {
                    Text("二维分布").tag(false)
                    Text("AP 覆盖").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            if showFeatures {
                featureTable(report)
            } else {
                scatter(report)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scatter(_ report: FingerprintQuality) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.plot.isEmpty {
                Text(report.sampleCount == 0 ? "没有样本通过当前筛选。" : "无法计算二维投影。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(report.plot) { sample in
                    PointMark(x: .value("MDS 1", sample.x), y: .value("MDS 2", sample.y))
                        .foregroundStyle(by: .value("采集点位", sample.label))
                        .symbol(by: .value("采集点位", sample.label))
                        .symbolSize(52)
                        .opacity(0.78)
                }
                .chartForegroundStyleScale(domain: (1...9).map { "P\($0)" },
                                           range: [.orange, .blue, .green, .purple, .pink,
                                                   .cyan, .brown, .indigo, .teal])
                .chartLegend(.hidden)
                .chartXAxisLabel("MDS 1")
                .chartYAxisLabel("MDS 2")
                .accessibilityLabel("采集点位的 RSSI 指纹二维分布")
            }
            Text("每个符号是一轮扫描。各方案分别计算二维 MDS，坐标和尺度独立。可以观察不同点位的样本是否重叠。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if report.plot.count < report.sampleCount && !report.plot.isEmpty {
                Text("图中按点位抽取 \(report.plot.count) / \(report.sampleCount) 条，统计覆盖全部样本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func featureTable(_ report: FingerprintQuality) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(report.features) {
                TableColumn("SSID / BSSID") { (feature: FingerprintSelection.Feature) in
                    VStack(alignment: .leading) {
                        Text(feature.ssid ?? "—").lineLimit(1)
                        Text(feature.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.width(min: 137, ideal: 165)
                TableColumn("各点检出率") { (feature: FingerprintSelection.Feature) in
                    let rates = zip(report.points, feature.detections).map { point, count in
                        let rate = Double(count) / Double(point.originalCount)
                        return "\(point.point.name) \(count)/\(point.originalCount)（\(rate.formatted(.percent.precision(.fractionLength(0))))）"
                    }.joined(separator: " · ")
                    Text(rates).font(.caption.monospacedDigit()).lineLimit(2).help(rates)
                }.width(min: 154, ideal: 208)
                TableColumn("最高检出率") { (feature: FingerprintSelection.Feature) in
                    Text(feature.selectionCoverage.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }.width(min: 72, ideal: 86)
                TableColumn("特征状态") { (feature: FingerprintSelection.Feature) in
                    Text(feature.retained ? "保留" : "筛除")
                        .foregroundStyle(feature.retained ? Color.primary : Color.secondary)
                }.width(min: 55, ideal: 61)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("每点检出率 = 该点扫到这个 BSSID 的样本数 ÷ 该点的基础样本数。")
                if filter != .baseline { Text(coverageRule) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sidebar(_ report: FingerprintQuality) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("点位样本").font(.headline)
                if filter != .baseline {
                    Text("清理前 \(report.originalCount) 条指纹 · \(report.features.count) 个 BSSID")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("点位")
                        Text(filter != .baseline ? "保留 / 原有" : "样本")
                        Text("少于 3 AP")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(report.points) { point in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(pointColor(point.point.index)).frame(width: 7, height: 7)
                                Text(point.point.name).fontWeight(.medium)
                            }
                            Text(filter == .baseline ? "\(point.sampleCount)" : "\(point.sampleCount) / \(point.originalCount)")
                            Text("\(point.sparseCount)").foregroundStyle(point.sparseCount > 0 ? Color.orange : Color.secondary)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                if report.points.count < 2 {
                    Label("至少需要两个参考点来比较分布。", systemImage: "exclamationmark.triangle")
                }
                Divider()
                Text("清理记录").font(.headline)
                Text("已跳过 \(report.invalidFiles) 个无效文件，合并 \(report.duplicateFiles) 条同点重复指纹。")
                if filter != .baseline {
                    Text("过滤 \(report.invalidReadings) 个异常读数，移除 \(report.emptyFingerprints) 条空指纹，再合并 \(report.mergedFingerprints) 条重复指纹。")
                    Text("有效读数范围为 −127 到 −1 dBm。\(coverageRule)")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(width: 300)
        .background(.quaternary.opacity(0.28))
    }

    private func pointColor(_ index: Int) -> Color {
        [.orange, .blue, .green, .purple, .pink, .cyan, .brown, .indigo, .teal][index]
    }
}
