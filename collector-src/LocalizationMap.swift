import SwiftUI

struct LocalizationMap: View {
    let references: Set<String>
    let prediction: KNNPrediction?

    private let spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("点位网格", systemImage: "square.grid.3x3").font(.headline)
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height, 430)
                let tile = max(0, (size - 2 * spacing) / 3)
                let step = tile + spacing
                ZStack {
                    VStack(spacing: spacing) {
                        ForEach(0..<3) { row in
                            HStack(spacing: spacing) {
                                ForEach(0..<3) { column in
                                    let label = GridPoint(index: row * 3 + column).name
                                    cell(label, size: tile)
                                }
                            }
                        }
                    }

                    if let prediction {
                        Circle()
                            .fill(Color.accentColor)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
                            .frame(width: 18, height: 18)
                            .position(x: tile / 2 + step * prediction.column,
                                      y: tile / 2 + step * prediction.row)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 18) {
                Label("已采集参考点", systemImage: "square")
                Label("估计位置", systemImage: "circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ label: String, size: CGFloat) -> some View {
        let isReference = references.contains(label)
        return Text(label)
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .foregroundStyle(isReference ? Color.primary : Color.secondary)
            .frame(width: size, height: size)
            .background(
                isReference ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isReference ? Color.accentColor.opacity(0.65) :
                                    Color.secondary.opacity(0.22), lineWidth: isReference ? 2 : 1)
            }
            .accessibilityLabel(label)
            .accessibilityValue(isReference ? "已采集参考点" : "未采集")
    }
}
