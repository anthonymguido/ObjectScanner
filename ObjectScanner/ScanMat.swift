import UIKit

/// A printable sheet covered in high-contrast, non-repeating marks. Put the object on the plain
/// circle in the middle: the marks give the camera plenty to track, and object masking keeps them
/// out of the model.
enum ScanMat {
    enum Paper: String, CaseIterable, Identifiable {
        case letter, a4
        var id: String { rawValue }
        var title: String { self == .letter ? "US Letter" : "A4" }
        /// Page size in points (1/72 inch).
        var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842) }
    }

    /// Writes the mat as a PDF to a temporary file and returns its URL.
    /// `tiled` makes a 2×2 set of pages to tape together, for bigger objects.
    static func makePDF(paper: Paper, tiled: Bool) throws -> URL {
        let page = paper.size
        let columns = tiled ? 2 : 1
        let canvas = CGSize(width: page.width * CGFloat(columns), height: page.height * CGFloat(columns))
        let marks = layout(canvas: canvas)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page))
        let data = renderer.pdfData { context in
            for row in 0..<columns {
                for column in 0..<columns {
                    context.beginPage()
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.translateBy(x: -CGFloat(column) * page.width, y: -CGFloat(row) * page.height)
                    draw(marks, canvas: canvas, in: cg)
                    cg.restoreGState()
                    if tiled { drawTileLabel(row: row, column: column, page: page, in: cg) }
                }
            }
        }

        let name = "Scan mat (\(paper.title)\(tiled ? ", 4 pages" : "")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Layout

    private enum Shape: CaseIterable { case disc, ring, square, triangle, bar, cross, ell, digit }

    private struct Mark {
        let shape: Shape
        let center: CGPoint
        let size: CGFloat
        let angle: CGFloat
        let digit: Int
    }

    private static let margin: CGFloat = 24

    private static func centerCircle(canvas: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return (center, min(canvas.width, canvas.height) * 0.27)
    }

    /// Scatters marks with a fixed seed, so every printed mat is the same, but no two areas match.
    private static func layout(canvas: CGSize) -> [Mark] {
        var rng = SeededGenerator(seed: 0x5CA_11A7)
        let (center, radius) = centerCircle(canvas: canvas)
        let target = Int(canvas.width * canvas.height / 2600)
        var marks: [Mark] = []
        var attempts = 0
        while marks.count < target, attempts < target * 20 {
            attempts += 1
            let size = CGFloat.random(in: 10...44, using: &rng)
            let p = CGPoint(x: CGFloat.random(in: margin + size...(canvas.width - margin - size), using: &rng),
                            y: CGFloat.random(in: margin + size...(canvas.height - margin - size), using: &rng))
            // Keep the object's circle plain, with a small gap around it.
            if hypot(p.x - center.x, p.y - center.y) < radius + size + 6 { continue }
            // Leave a little white between marks so each stays distinct.
            if marks.contains(where: { hypot($0.center.x - p.x, $0.center.y - p.y) < ($0.size + size) * 0.6 }) { continue }
            marks.append(Mark(shape: Shape.allCases.randomElement(using: &rng)!,
                              center: p, size: size,
                              angle: CGFloat.random(in: 0...(2 * .pi), using: &rng),
                              digit: Int.random(in: 0...9, using: &rng)))
        }
        return marks
    }

    // MARK: Drawing

    private static func draw(_ marks: [Mark], canvas: CGSize, in cg: CGContext) {
        UIColor.white.setFill()
        cg.fill(CGRect(origin: .zero, size: canvas))

        let (center, radius) = centerCircle(canvas: canvas)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(2)
        cg.setLineDash(phase: 0, lengths: [8, 6])
        cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        cg.setLineDash(phase: 0, lengths: [])
        let label = "Place object here" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .medium),
                                                    .foregroundColor: UIColor.lightGray]
        let labelSize = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y + radius - labelSize.height - 12),
                   withAttributes: attrs)

        UIColor.black.setFill()
        UIColor.black.setStroke()
        for mark in marks {
            cg.saveGState()
            cg.translateBy(x: mark.center.x, y: mark.center.y)
            cg.rotate(by: mark.angle)
            drawShape(mark, in: cg)
            cg.restoreGState()
        }
    }

    private static func drawShape(_ mark: Mark, in cg: CGContext) {
        let s = mark.size
        let half = s / 2
        switch mark.shape {
        case .disc:
            cg.fillEllipse(in: CGRect(x: -half, y: -half, width: s, height: s))
        case .ring:
            cg.setLineWidth(max(2, s * 0.18))
            cg.strokeEllipse(in: CGRect(x: -half * 0.8, y: -half * 0.8, width: s * 0.8, height: s * 0.8))
        case .square:
            cg.fill(CGRect(x: -half * 0.8, y: -half * 0.8, width: s * 0.8, height: s * 0.8))
        case .triangle:
            cg.move(to: CGPoint(x: 0, y: -half))
            cg.addLine(to: CGPoint(x: half, y: half))
            cg.addLine(to: CGPoint(x: -half, y: half))
            cg.closePath()
            cg.fillPath()
        case .bar:
            cg.fill(CGRect(x: -half, y: -s * 0.12, width: s, height: s * 0.24))
        case .cross:
            cg.fill(CGRect(x: -half, y: -s * 0.1, width: s, height: s * 0.2))
            cg.fill(CGRect(x: -s * 0.1, y: -half, width: s * 0.2, height: s))
        case .ell:
            cg.fill(CGRect(x: -half, y: -half, width: s * 0.25, height: s))
            cg.fill(CGRect(x: -half, y: half - s * 0.25, width: s * 0.7, height: s * 0.25))
        case .digit:
            let text = "\(mark.digit)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s * 1.1, weight: .black),
                                                        .foregroundColor: UIColor.black]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
        }
    }

    private static func drawTileLabel(row: Int, column: Int, page: CGSize, in cg: CGContext) {
        let name = "Page \(row * 2 + column + 1) of 4: \(row == 0 ? "top" : "bottom") \(column == 0 ? "left" : "right")" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9),
                                                    .foregroundColor: UIColor.gray]
        name.draw(at: CGPoint(x: 8, y: page.height - 14), withAttributes: attrs)
    }
}

/// Small deterministic random generator (SplitMix64), so the mat looks the same on every print.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
