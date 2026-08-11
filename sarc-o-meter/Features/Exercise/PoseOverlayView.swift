import SwiftUI
import MediaPipeTasksVision

struct PoseOverlayView: View {
    let landmarks: [[NormalizedLandmark]]
    let imageSize: CGSize

    // Koneksi skeleton (33 titik pose MediaPipe)
    static let connections: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,7),(0,4),(4,5),(5,6),(6,8),(9,10),   // wajah
        (11,12),(11,23),(12,24),(23,24),                          // torso
        (11,13),(13,15),(15,17),(15,19),(15,21),(17,19),          // lengan kiri
        (12,14),(14,16),(16,18),(16,20),(16,22),(18,20),          // lengan kanan
        (23,25),(25,27),(27,29),(27,31),(29,31),                  // kaki kiri
        (24,26),(26,28),(28,30),(28,32),(30,32)                   // kaki kanan
    ]

    // Sendi tubuh bawah yang diberi label sudut.
    // a & c = titik ujung ruas, vertex = sendi (tempat label muncul)
    struct AngleJoint {
        let a: Int
        let vertex: Int
        let c: Int
    }
    static let angleJoints: [AngleJoint] = [
        .init(a: 11, vertex: 23, c: 25),   // pinggul kiri
        .init(a: 12, vertex: 24, c: 26),   // pinggul kanan
        .init(a: 23, vertex: 25, c: 27),   // lutut kiri
        .init(a: 24, vertex: 26, c: 28),   // lutut kanan
        .init(a: 25, vertex: 27, c: 31),   // pergelangan kaki kiri
        .init(a: 26, vertex: 28, c: 32)    // pergelangan kaki kanan
    ]

    // Kumpulan indeks titik sendi yang punya label derajat
    static let angleVertices: Set<Int> = Set(angleJoints.map { $0.vertex })

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                for person in landmarks {
                    // Garis skeleton
                    for (a, b) in Self.connections where a < person.count && b < person.count {
                        var path = Path()
                        path.move(to: point(person[a], geo.size))
                        path.addLine(to: point(person[b], geo.size))
                        context.stroke(path, with: .color(.green), lineWidth: 3)
                    }

                    // Titik joint — sendi bersudut jadi oranye & lebih besar
                    for (index, lm) in person.enumerated() {
                        let p = point(lm, geo.size)
                        let isAngleJoint = Self.angleVertices.contains(index)
                        let size: CGFloat = isAngleJoint ? 12 : 8
                        let color: Color = isAngleJoint ? .orange : .red
                        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2,
                                       width: size, height: size)
                        context.fill(Path(ellipseIn: r), with: .color(color))
                    }

                    // Label derajat di sendi tubuh bawah
                    for joint in Self.angleJoints {
                        guard joint.a < person.count,
                              joint.vertex < person.count,
                              joint.c < person.count else { continue }

                        let deg = angle(person[joint.a],
                                        person[joint.vertex],
                                        person[joint.c])
                        let p = point(person[joint.vertex], geo.size)

                        let label = Text("\(Int(deg.rounded()))°")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)

                        // Kotak latar gelap biar teks kebaca
                        let bg = CGRect(x: p.x + 8, y: p.y - 10, width: 42, height: 20)
                        context.fill(Path(roundedRect: bg, cornerRadius: 4),
                                     with: .color(.black.opacity(0.6)))
                        context.draw(label, at: CGPoint(x: p.x + 29, y: p.y),
                                     anchor: .center)
                    }
                }
            }
        }
    }

    // Sudut (derajat) di titik `b`, dibentuk oleh ruas b→a dan b→c
    private func angle(_ a: NormalizedLandmark,
                       _ b: NormalizedLandmark,
                       _ c: NormalizedLandmark) -> Double {
        let a1 = atan2(Double(a.y - b.y), Double(a.x - b.x))
        let a2 = atan2(Double(c.y - b.y), Double(c.x - b.x))
        var deg = abs(a1 - a2) * 180 / .pi
        if deg > 180 { deg = 360 - deg }
        return deg
    }

    // Normalisasi [0..1] -> koordinat layar (aspect-fill)
    private func point(_ lm: NormalizedLandmark, _ viewSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let imgAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        var scale: CGFloat = 1, offsetX: CGFloat = 0, offsetY: CGFloat = 0
        if imgAspect > viewAspect {
            scale = viewSize.height / imageSize.height
            offsetX = (viewSize.width - imageSize.width * scale) / 2
        } else {
            scale = viewSize.width / imageSize.width
            offsetY = (viewSize.height - imageSize.height * scale) / 2
        }
        let x = CGFloat(lm.x) * imageSize.width * scale + offsetX
        let y = CGFloat(lm.y) * imageSize.height * scale + offsetY
        return CGPoint(x: x, y: y)
    }
}
