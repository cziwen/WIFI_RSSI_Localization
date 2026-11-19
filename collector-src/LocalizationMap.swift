import SwiftUI

struct LocalizationMap: View {
    let references: Set<String>
    let match: String?

    private let spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("点位网格", systemImage: "square.grid.3x3").font(.headline)
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height, 430)
                let tile = max(0, (size - 2 * spacing) / 3)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 18) {
                Label("已采集参考点", systemImage: "square")
                Label("最相似点位", systemImage: "checkmark.square.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ label: String, size: CGFloat) -> some View {
        let isMatch = label == match
        let isReference = references.contains(label)
        return Text(label)
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .foregroundStyle(isMatch ? Color.white : isReference ? Color.primary : Color.secondary)
            .frame(width: size, height: size)
            .background(
                isMatch ? Color.accentColor : isReference ? Color.accentColor.opacity(0.12) :
                    Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isReference ? Color.accentColor.opacity(0.65) :
                                    Color.secondary.opacity(0.22), lineWidth: isReference ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isMatch {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(isMatch ? "最相似点位" : isReference ? "已采集参考点" : "未采集")
            .accessibilityAddTraits(isMatch ? .isSelected : [])
    }
}
