import Foundation
import simd

/// Turns a scanned model into a solid, watertight STL ready for a slicer:
/// cuts off the table, keeps the object, closes every hole, flattens the bottom, sizes it in mm.
///
/// How: the model is drawn into a 3D grid of tiny cubes (voxels). Holes up to a few voxels wide are
/// closed, everything the outside air can't reach counts as solid, loose bits are dropped, and a new
/// surface is wrapped around the solid (surface nets). A surface built that way is always closed.
enum PrintExporter {
    struct Options {
        var resin = false          // finer grid
        var keepBase = false       // keep everything down to the lowest point (for dioramas)
        var targetSizeMM: Float?   // longest side; nil = real size
    }

    struct Report {
        var sizeMM: SIMD3<Float>
        var triangles: Int
        var voxelMM: Float
        var tableRemoved: Bool
        var piecesDropped: Int

        var summary: String {
            var s = String(format: "%.1f × %.1f × %.1f mm, %@ triangles, detail %.2f mm. Watertight ✓",
                           sizeMM.x, sizeMM.y, sizeMM.z, triangles.formatted() as NSString, voxelMM)
            if tableRemoved { s += ". Table removed" }
            if piecesDropped > 0 { s += ". \(piecesDropped) loose bit\(piecesDropped == 1 ? "" : "s") removed" }
            return s + "."
        }
    }

    enum ExportError: LocalizedError {
        case empty
        var errorDescription: String? { "Nothing solid was left after cleaning up the model. Try Keep base." }
    }

    static func makePrintFile(model: URL, output: URL, options: Options,
                              progress: @escaping (String) -> Void) throws -> Report {
        progress("Reading the model…")
        var mesh = try MeshIO.loadTriangles(from: model)

        // Object Capture models are in meters with Y up. Guard against centimeter files.
        var (lo, hi) = mesh.bounds
        if simd_reduce_max(hi - lo) > 3 {
            for i in mesh.positions.indices { mesh.positions[i] *= 0.01 }
            (lo, hi) = mesh.bounds
        }

        progress("Finding the table…")
        let floor = options.keepBase ? (y: lo.y, found: false) : findFloor(mesh, lo: lo, hi: hi)

        progress("Filling in the solid…")
        let grid = VoxelGrid(lo: SIMD3(lo.x, floor.y, lo.z), hi: hi, cells: options.resin ? 320 : 256, pad: 4)
        defer { grid.free() }
        grid.rasterize(mesh, minY: floor.y)
        grid.closeAndFill(radius: 2)

        progress("Removing loose bits…")
        let dropped = grid.keepMainPieces()
        guard grid.solidCount > 0 else { throw ExportError.empty }

        progress("Building the surface…")
        var surface = grid.surfaceNets()
        guard surface.triangleCount > 0 else { throw ExportError.empty }
        taubinSmooth(&surface, iterations: 2)

        // To millimeters, Z up (slicers' convention), centered, sitting on z = 0.
        let (slo, shi) = surface.bounds
        let real = (shi - slo) * 1000
        var scale: Float = 1000
        if let target = options.targetSizeMM, target > 0 { scale *= target / simd_reduce_max(real) }
        let center = (slo + shi) / 2
        for i in surface.positions.indices {
            let p = (surface.positions[i] - SIMD3(center.x, slo.y, center.z)) * scale
            surface.positions[i] = SIMD3(p.x, -p.z, p.y)
        }

        progress("Saving…")
        try MeshIO.writeSTL(surface, to: output)
        let size = surface.bounds
        return Report(sizeMM: size.max - size.min, triangles: surface.triangleCount,
                      voxelMM: grid.voxel * scale, tableRemoved: floor.found, piecesDropped: dropped)
    }

    // MARK: Table detection

    /// The table shows up as a large flat, upward-facing area low in the model.
    private static func findFloor(_ mesh: TriangleMesh, lo: SIMD3<Float>, hi: SIMD3<Float>) -> (y: Float, found: Bool) {
        let height = hi.y - lo.y
        guard height > 0 else { return (lo.y, false) }
        let bins = 200
        var weights = [Float](repeating: 0, count: bins)
        var totalUp: Float = 0
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            guard len > 0, cross.y / len > 0.85 else { continue }
            let y = (a.y + b.y + c.y) / 3
            let bin = min(bins - 1, max(0, Int((y - lo.y) / height * Float(bins))))
            weights[bin] += len / 2
            totalUp += len / 2
        }
        let searchTo = bins * 35 / 100
        guard totalUp > 0, let best = (0..<searchTo).max(by: { weights[$0] < weights[$1] }) else { return (lo.y, false) }
        // Count the peak and its neighbors (a slightly tilted or bumpy table spreads over a few bins).
        let peak = (max(0, best - 1)...min(bins - 1, best + 1)).reduce(Float(0)) { $0 + weights[$1] }
        guard peak > totalUp * 0.15 else { return (lo.y, false) }
        // Cut just above the table's surface.
        return (lo.y + Float(best + 2) / Float(bins) * height, true)
    }

    // MARK: Smoothing

    /// Taubin smoothing: smooths the voxel steps without shrinking the model.
    private static func taubinSmooth(_ mesh: inout TriangleMesh, iterations: Int) {
        let n = mesh.positions.count
        var neighbors = [[UInt32]](repeating: [], count: n)
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            neighbors[Int(a)].append(b); neighbors[Int(a)].append(c)
            neighbors[Int(b)].append(a); neighbors[Int(b)].append(c)
            neighbors[Int(c)].append(a); neighbors[Int(c)].append(b)
        }
        func step(_ factor: Float) {
            let old = mesh.positions
            for i in 0..<n where !neighbors[i].isEmpty {
                var avg = SIMD3<Float>.zero
                for j in neighbors[i] { avg += old[Int(j)] }
                avg /= Float(neighbors[i].count)
                mesh.positions[i] = old[i] + factor * (avg - old[i])
            }
        }
        for _ in 0..<iterations {
            step(0.5)
            step(-0.53)
        }
    }
}

// MARK: - Voxel grid

/// A 3D grid of bytes over the model's box. Index = x + nx * (y + ny * z).
private final class VoxelGrid {
    let nx: Int, ny: Int, nz: Int
    let origin: SIMD3<Float>
    let voxel: Float
    /// Layers below this y index are under the floor and never solid.
    let floorLayer: Int
    private var a: UnsafeMutableBufferPointer<UInt8>
    private var b: UnsafeMutableBufferPointer<UInt8>

    var count: Int { nx * ny * nz }
    var solidCount: Int { a.reduce(0) { $0 + ($1 == 1 ? 1 : 0) } }

    init(lo: SIMD3<Float>, hi: SIMD3<Float>, cells: Int, pad: Int) {
        let extent = simd_max(hi - lo, SIMD3(repeating: 1e-4))
        voxel = simd_reduce_max(extent) / Float(cells)
        let dims = SIMD3<Int>(Int((extent.x / voxel).rounded(.up)), Int((extent.y / voxel).rounded(.up)),
                              Int((extent.z / voxel).rounded(.up))) &+ (2 * pad)
        nx = dims.x; ny = dims.y; nz = dims.z
        origin = lo - Float(pad) * voxel
        floorLayer = pad
        let total = dims.x * dims.y * dims.z
        a = .allocate(capacity: total); a.initialize(repeating: 0)
        b = .allocate(capacity: total); b.initialize(repeating: 0)
    }

    func free() {
        a.deallocate()
        b.deallocate()
    }

    @inline(__always) private func index(_ x: Int, _ y: Int, _ z: Int) -> Int { x + nx * (y + ny * z) }

    /// Center of voxel (x, y, z) in model space.
    @inline(__always) private func center(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        origin + (SIMD3(x, y, z) + 0.5) * voxel
    }

    // MARK: Surface → solid

    /// Marks every voxel the model's surface passes through (above the floor) in `a`.
    func rasterize(_ mesh: TriangleMesh, minY: Float) {
        let inv = 1 / voxel
        for t in 0..<mesh.triangleCount {
            let p0 = mesh.positions[Int(mesh.indices[t * 3])]
            let p1 = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let p2 = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            if max(p0.y, p1.y, p2.y) < minY { continue }
            let longest = max(simd_length(p1 - p0), simd_length(p2 - p0), simd_length(p2 - p1))
            let steps = min(1024, max(1, Int((longest * inv * 2).rounded(.up))))
            let e1 = (p1 - p0) / Float(steps), e2 = (p2 - p0) / Float(steps)
            for i in 0...steps {
                for j in 0...(steps - i) {
                    let p = p0 + e1 * Float(i) + e2 * Float(j)
                    if p.y < minY { continue }
                    let g = (p - origin) * inv
                    let x = Int(g.x), y = Int(g.y), z = Int(g.z)
                    guard x >= 0, y >= floorLayer, z >= 0, x < nx, y < ny, z < nz else { continue }
                    a[index(x, y, z)] = 1
                }
            }
        }
    }

    /// Closes holes up to about 2 × radius voxels wide, then fills: solid = what the outside can't reach.
    /// Result in `a`: 1 = solid, 0 = empty.
    func closeAndFill(radius r: Int) {
        // Thicken the surface so small holes are plugged.
        filter(from: &a, to: &b, radius: r, outside: 0, combine: { max($0, $1) })

        // b: 1 = wall. The floor layer is a wall everywhere, so the open bottom left by the cut is sealed.
        for z in 0..<nz { for x in 0..<nx { for y in 0..<floorLayer { b[index(x, y, z)] = 1 } } }

        // Flood the outside air (2) from the grid's sides and top.
        var stack: [Int32] = []
        func push(_ i: Int) {
            if b[i] == 0 { b[i] = 2; stack.append(Int32(i)) }
        }
        for z in 0..<nz {
            for y in floorLayer..<ny {
                push(index(0, y, z)); push(index(nx - 1, y, z))
            }
            for x in 0..<nx { push(index(x, ny - 1, z)) }
        }
        for y in floorLayer..<ny {
            for x in 0..<nx { push(index(x, y, 0)); push(index(x, y, nz - 1)) }
        }
        while let top = stack.popLast() {
            forEachNeighbor(Int(top), push)
        }

        // Solid = not outside. Below the floor counts as solid while shrinking back, so the bottom stays flat.
        for i in 0..<count { a[i] = b[i] == 2 ? 0 : 1 }
        filter(from: &a, to: &b, radius: r, outside: 0, combine: { min($0, $1) })
        for z in 0..<nz { for x in 0..<nx { for y in 0..<floorLayer { b[index(x, y, z)] = 0 } } }
        swap(&a, &b)
    }

    /// Keeps the biggest solid piece (and any piece at least 10% of its size). Returns how many were dropped.
    func keepMainPieces() -> Int {
        // a: 1 = solid. Label pieces by flooding: mark 3 while measuring.
        var sizes: [(seed: Int, size: Int)] = []
        var stack: [Int32] = []
        for start in 0..<count where a[start] == 1 {
            var size = 0
            a[start] = 3
            stack.append(Int32(start))
            while let top = stack.popLast() {
                size += 1
                forEachNeighbor(Int(top)) { n in
                    if a[n] == 1 { a[n] = 3; stack.append(Int32(n)) }
                }
            }
            sizes.append((start, size))
        }
        guard let biggest = sizes.map(\.size).max() else { return 0 }
        let keep = sizes.filter { $0.size * 10 >= biggest }
        for piece in keep {
            a[piece.seed] = 4
            stack.append(Int32(piece.seed))
            while let top = stack.popLast() {
                forEachNeighbor(Int(top)) { n in
                    if a[n] == 3 { a[n] = 4; stack.append(Int32(n)) }
                }
            }
        }
        for i in 0..<count { a[i] = a[i] == 4 ? 1 : 0 }
        return sizes.count - keep.count
    }

    // MARK: Solid → surface

    /// Surface nets: one vertex per cell the surface crosses, one quad per crossed grid edge.
    /// The solid is blurred first (3×3×3) so the surface is smooth instead of blocky.
    func surfaceNets() -> TriangleMesh {
        // Blur: a (0/1) → b → a → b, sums up to 27.
        filter(from: &a, to: &b, radius: 1, outside: 0, combine: { $0 &+ $1 }, axes: [0])
        filter(from: &b, to: &a, radius: 1, outside: 0, combine: { $0 &+ $1 }, axes: [1])
        filter(from: &a, to: &b, radius: 1, outside: 0, combine: { $0 &+ $1 }, axes: [2])
        let field = b
        let iso: Float = 13.5
        func value(_ x: Int, _ y: Int, _ z: Int) -> Float { Float(field[index(x, y, z)]) }
        func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool { value(x, y, z) > iso }

        var mesh = TriangleMesh()
        let cx = nx - 1, cy = ny - 1, cz = nz - 1   // cells per axis
        var previous = [Int32](repeating: -1, count: cx * cy)
        var current = [Int32](repeating: -1, count: cx * cy)

        let corners: [SIMD3<Int>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]

        func addQuad(_ q: [Int32], outward: SIMD3<Float>) {
            guard q.allSatisfy({ $0 >= 0 }) else { return }
            let p = q.map { mesh.positions[Int($0)] }
            let normal = simd_cross(p[1] - p[0], p[2] - p[0]) + simd_cross(p[2] - p[0], p[3] - p[0])
            let order: [Int32] = simd_dot(normal, outward) >= 0 ? q : [q[0], q[3], q[2], q[1]]
            mesh.indices += [UInt32(order[0]), UInt32(order[1]), UInt32(order[2]),
                             UInt32(order[0]), UInt32(order[2]), UInt32(order[3])]
        }

        for z in 0..<cz {
            // Vertices for this slice of cells.
            for y in 0..<cy {
                for x in 0..<cx {
                    var values = SIMD8<Float>()
                    var mask = 0
                    for (c, o) in corners.enumerated() {
                        values[c] = value(x + o.x, y + o.y, z + o.z)
                        if values[c] > iso { mask |= 1 << c }
                    }
                    guard mask != 0, mask != 255 else { current[x + cx * y] = -1; continue }
                    var sum = SIMD3<Float>.zero
                    var crossings: Float = 0
                    for (e0, e1) in edges where (values[e0] > iso) != (values[e1] > iso) {
                        let t = (iso - values[e0]) / (values[e1] - values[e0])
                        let p0 = SIMD3<Float>(corners[e0]), p1 = SIMD3<Float>(corners[e1])
                        sum += p0 + (p1 - p0) * t
                        crossings += 1
                    }
                    let local = sum / crossings
                    current[x + cx * y] = Int32(mesh.positions.count)
                    mesh.positions.append(center(Float(x) + local.x, Float(y) + local.y, Float(z) + local.z))
                }
            }

            // Edges along z between grid planes z and z+1: all four cells are in this slice.
            for y in 1..<cy {
                for x in 1..<cx where inside(x, y, z) != inside(x, y, z + 1) {
                    let q = [current[(x - 1) + cx * (y - 1)], current[x + cx * (y - 1)],
                             current[x + cx * y], current[(x - 1) + cx * y]]
                    addQuad(q, outward: SIMD3(0, 0, inside(x, y, z) ? 1 : -1))
                }
            }
            // Edges along x and y on grid plane z: cells in slices z-1 and z.
            if z >= 1 {
                for y in 1..<cy {
                    for x in 0..<cx where inside(x, y, z) != inside(x + 1, y, z) {
                        let q = [previous[x + cx * (y - 1)], previous[x + cx * y],
                                 current[x + cx * y], current[x + cx * (y - 1)]]
                        addQuad(q, outward: SIMD3(inside(x, y, z) ? 1 : -1, 0, 0))
                    }
                }
                for y in 0..<cy {
                    for x in 1..<cx where inside(x, y, z) != inside(x, y + 1, z) {
                        let q = [previous[(x - 1) + cx * y], previous[x + cx * y],
                                 current[x + cx * y], current[(x - 1) + cx * y]]
                        addQuad(q, outward: SIMD3(0, inside(x, y, z) ? 1 : -1, 0))
                    }
                }
            }
            swap(&previous, &current)
        }
        return mesh
    }

    // MARK: Helpers

    private func forEachNeighbor(_ i: Int, _ body: (Int) -> Void) {
        let x = i % nx, y = (i / nx) % ny, z = i / (nx * ny)
        if x > 0 { body(i - 1) }
        if x < nx - 1 { body(i + 1) }
        if y > 0 { body(i - nx) }
        if y < ny - 1 { body(i + nx) }
        if z > 0 { body(i - nx * ny) }
        if z < nz - 1 { body(i + nx * ny) }
    }

    /// Separable box filter (max = grow, min = shrink, + = sum) along the given axes, `radius` voxels each way.
    /// Runs from `src` into `dst`; with several axes it ping-pongs and leaves the result in `dst`.
    private func filter(from src: inout UnsafeMutableBufferPointer<UInt8>, to dst: inout UnsafeMutableBufferPointer<UInt8>,
                        radius r: Int, outside: UInt8, combine: (UInt8, UInt8) -> UInt8, axes: [Int] = [0, 1, 2]) {
        var input = src, output = dst
        for (n, axis) in axes.enumerated() {
            let stride = axis == 0 ? 1 : axis == 1 ? nx : nx * ny
            let length = axis == 0 ? nx : axis == 1 ? ny : nz
            for i in 0..<count {
                let pos = axis == 0 ? i % nx : axis == 1 ? (i / nx) % ny : i / (nx * ny)
                var acc = input[i]
                for d in 1...r {
                    acc = combine(acc, pos - d >= 0 ? input[i - d * stride] : outside)
                    acc = combine(acc, pos + d < length ? input[i + d * stride] : outside)
                }
                output[i] = acc
            }
            if n < axes.count - 1 { swap(&input, &output) }
        }
        // Make sure the final result ends up in dst.
        if output.baseAddress != dst.baseAddress {
            for i in 0..<count { dst[i] = output[i] }
        }
    }
}
