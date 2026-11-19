import SwiftUI

struct LocalizationMap: View {
    let references: [FingerprintReference]
    let prediction: KNNPrediction?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("位置平面图", systemImage: "map").font(.headline)
                Spacer()
                Text("X 向右 · Z 向下 · 米").font(.caption).foregroundStyle(.secondary)
            }
            if references.isEmpty {
                Text("采集样本后，参考点会出现在平面图上。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let layout = MapLayout(references: references, size: geometry.size)
                    ZStack {
                        floor(layout)
                        if references.count == 2 {
                            Path { path in
                                path.move(to: layout.project(references[0].position))
                                path.addLine(to: layout.project(references[1].position))
                            }
                            .stroke(Color.secondary.opacity(0.53), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                            .accessibilityHidden(true)
                        }
                        ForEach(references, id: \.self) { reference in
                            referenceMarker(reference, layout: layout)
                        }
                        if let prediction {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 18, height: 18)
                                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                                .shadow(color: Color.accentColor.opacity(0.45), radius: 6)
                                .position(layout.project(prediction.position))
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            HStack(spacing: 18) {
                Label("参考点", systemImage: "circle")
                Label("估计位置", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func floor(_ layout: MapLayout) -> some View {
        let rect = layout.floor
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.05))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Path { path in
                for index in 0...2 {
                    let fraction = CGFloat(index) / 2
                    let x = rect.minX + rect.width * fraction
                    let y = rect.minY + rect.height * fraction
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.secondary.opacity(0.23), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func referenceMarker(_ reference: FingerprintReference, layout: MapLayout) -> some View {
        let center = layout.project(reference.position)
        return ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay { Circle().strokeBorder(Color.secondary, lineWidth: 1.5) }
                .frame(width: 11, height: 11)
                .position(center)
            Text(reference.label)
                .font(.caption.weight(.semibold).monospaced())
                .position(x: center.x, y: center.y - 19)
        }
    }

    private struct MapLayout {
        let minX: Double
        let minZ: Double
        let scale: CGFloat
        let floor: CGRect

        init(references: [FingerprintReference], size: CGSize) {
            let x = references.map(\.position.x)
            let z = references.map(\.position.z)
            minX = min(x.min() ?? 0, 0)
            minZ = min(z.min() ?? 0, 0)
            let width = max(1, (x.max() ?? 0) - minX)
            let height = max(1, (z.max() ?? 0) - minZ)
            scale = min(max(1, size.width - 70) / width, max(1, size.height - 70) / height)
            let displayWidth = width * scale
            let displayHeight = height * scale
            floor = CGRect(x: (size.width - displayWidth) / 2, y: (size.height - displayHeight) / 2,
                           width: displayWidth, height: displayHeight)
        }

        func project(_ position: FloorPosition) -> CGPoint {
            CGPoint(x: floor.minX + (position.x - minX) * scale,
                    y: floor.minY + (position.z - minZ) * scale)
        }
    }
}
