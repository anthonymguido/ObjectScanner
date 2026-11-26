import Foundation
import ModelIO
import simd

/// A plain triangle mesh: positions plus three indices per triangle.
struct TriangleMesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

/// Loading models with ModelIO and writing print files.
enum MeshIO {
    enum LoadError: LocalizedError {
        case noGeometry
        var errorDescription: String? { "The model has no triangles to work with." }
    }

    /// All triangles of a USDZ/OBJ/etc. in world space (each mesh's transforms applied).
    static func loadTriangles(from url: URL) throws -> TriangleMesh {
        let asset = MDLAsset(url: url)
        var result = TriangleMesh()
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3)
            else { continue }
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let base = UInt32(result.positions.count)
            let start = positions.dataStart
            let stride = positions.stride
            result.positions.reserveCapacity(result.positions.count + mesh.vertexCount)
            for i in 0..<mesh.vertexCount {
                let p = start.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
                let v = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                result.positions.append(SIMD3(v.x, v.y, v.z))
            }
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                let map = submesh.indexBuffer.map()
                let count = submesh.indexCount
                switch submesh.indexType {
                case .uInt32:
                    let p = map.bytes.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<count { result.indices.append(base + p[i]) }
                case .uInt16:
                    let p = map.bytes.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<count { result.indices.append(base + UInt32(p[i])) }
                case .uInt8:
                    let p = map.bytes.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<count { result.indices.append(base + UInt32(p[i])) }
                default:
                    continue
                }
            }
        }
        guard result.triangleCount > 0 else { throw LoadError.noGeometry }
        return result
    }

    /// Triangle count of a model file, or nil if it can't be read.
    static func triangleCount(of url: URL) -> Int? {
        try? loadTriangles(from: url).triangleCount
    }

    /// Binary STL. Positions must already be in millimeters, Z up.
    static func writeSTL(_ mesh: TriangleMesh, to url: URL) throws {
        let count = mesh.triangleCount
        var data = Data(capacity: 84 + count * 50)
        var header = Data("Object Scanner print file (mm)".utf8)
        header.append(Data(repeating: 0, count: 80 - header.count))
        data.append(header)
        appendLE(UInt32(count), to: &data)
        for t in 0..<count {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : .zero
            for v in [n, a, b, c] {
                appendLE(v.x.bitPattern, to: &data)
                appendLE(v.y.bitPattern, to: &data)
                appendLE(v.z.bitPattern, to: &data)
            }
            appendLE(UInt16(0), to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
