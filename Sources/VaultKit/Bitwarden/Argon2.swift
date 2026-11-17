import Foundation

/// BLAKE2b (RFC 7693), unkeyed. Argon2 is built on it.
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    private static func compress(_ h: inout [UInt64], _ block: [UInt64], t: UInt64, last: Bool) {
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = h[i]; v[i + 8] = iv[i] }
        v[12] ^= t
        if last { v[14] = ~v[14] }
        @inline(__always) func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 63)
        }
        for round in 0..<12 {
            let s = sigma[round % 10]
            g(0, 4, 8, 12, block[s[0]], block[s[1]]); g(1, 5, 9, 13, block[s[2]], block[s[3]])
            g(2, 6, 10, 14, block[s[4]], block[s[5]]); g(3, 7, 11, 15, block[s[6]], block[s[7]])
            g(0, 5, 10, 15, block[s[8]], block[s[9]]); g(1, 6, 11, 12, block[s[10]], block[s[11]])
            g(2, 7, 8, 13, block[s[12]], block[s[13]]); g(3, 4, 9, 14, block[s[14]], block[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    static func hash(_ input: Data, length: Int) -> Data {
        precondition((1...64).contains(length))
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(length)
        let bytes = [UInt8](input)
        var offset = 0
        func word(_ b: [UInt8]) -> [UInt64] {
            (0..<16).map { w in
                var x: UInt64 = 0
                for k in 0..<8 { x |= UInt64(b[w * 8 + k]) << UInt64(8 * k) }
                return x
            }
        }
        while bytes.count - offset > 128 {
            compress(&h, word(Array(bytes[offset..<(offset + 128)])), t: UInt64(offset + 128), last: false)
            offset += 128
        }
        var tail = Array(bytes[offset...])
        let total = UInt64(bytes.count)
        tail += [UInt8](repeating: 0, count: 128 - tail.count)
        compress(&h, word(tail), t: total, last: true)
        var out = Data()
        for w in h { for k in 0..<8 { out.append(UInt8((w >> UInt64(8 * k)) & 0xFF)) } }
        return out.prefix(length)
    }
}

/// Argon2 (RFC 9106). Bitwarden uses Argon2id; the data-independent and
/// data-dependent variants are included so the RFC test vectors can check the core.
public enum Argon2 {
    public enum Variant: Int { case d = 0, i = 1, id = 2 }

    private static func le32(_ x: Int) -> Data {
        var v = UInt32(truncatingIfNeeded: x).littleEndian
        return Data(bytes: &v, count: 4)
    }

    /// H' (variable-length hash).
    private static func hPrime(_ input: Data, length: Int) -> Data {
        if length <= 64 { return Blake2b.hash(le32(length) + input, length: length) }
        let r = (length + 31) / 32 - 2
        var v = Blake2b.hash(le32(length) + input, length: 64)
        var out = v.prefix(32)
        for _ in 1..<r {
            v = Blake2b.hash(v, length: 64)
            out += v.prefix(32)
        }
        v = Blake2b.hash(v, length: length - 32 * r)
        return out + v
    }

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    @inline(__always) private static func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF); d = rotr(d ^ a, 32)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF); b = rotr(b ^ c, 24)
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF); d = rotr(d ^ a, 16)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF); b = rotr(b ^ c, 63)
    }

    @inline(__always) private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i: [Int]) {
        var x0 = v[i[0]], x1 = v[i[1]], x2 = v[i[2]], x3 = v[i[3]], x4 = v[i[4]], x5 = v[i[5]], x6 = v[i[6]], x7 = v[i[7]]
        var x8 = v[i[8]], x9 = v[i[9]], x10 = v[i[10]], x11 = v[i[11]], x12 = v[i[12]], x13 = v[i[13]], x14 = v[i[14]], x15 = v[i[15]]
        gb(&x0, &x4, &x8, &x12); gb(&x1, &x5, &x9, &x13); gb(&x2, &x6, &x10, &x14); gb(&x3, &x7, &x11, &x15)
        gb(&x0, &x5, &x10, &x15); gb(&x1, &x6, &x11, &x12); gb(&x2, &x7, &x8, &x13); gb(&x3, &x4, &x9, &x14)
        v[i[0]] = x0; v[i[1]] = x1; v[i[2]] = x2; v[i[3]] = x3; v[i[4]] = x4; v[i[5]] = x5; v[i[6]] = x6; v[i[7]] = x7
        v[i[8]] = x8; v[i[9]] = x9; v[i[10]] = x10; v[i[11]] = x11; v[i[12]] = x12; v[i[13]] = x13; v[i[14]] = x14; v[i[15]] = x15
    }

    private static let rowIndices: [[Int]] = {
        var rows: [[Int]] = []
        for r in 0..<8 {
            var row: [Int] = []
            for k in 0..<16 { row.append(16 * r + k) }
            rows.append(row)
        }
        return rows
    }()

    private static let colIndices: [[Int]] = {
        var cols: [[Int]] = []
        for c in 0..<8 {
            var col: [Int] = []
            for r in 0..<8 {
                let base: Int = 16 * r + 2 * c
                col.append(base)
                col.append(base + 1)
            }
            cols.append(col)
        }
        return cols
    }()

    /// G(X, Y): the block compression function. `xorInto` XORs onto the existing destination (passes after the first).
    private static func fillBlock(_ x: UnsafePointer<UInt64>, _ y: UnsafePointer<UInt64>, _ out: UnsafeMutablePointer<UInt64>, xorInto: Bool) {
        var r = [UInt64](repeating: 0, count: 128)
        r.withUnsafeMutableBufferPointer { rp in
            let p = rp.baseAddress!
            for k in 0..<128 { p[k] = x[k] ^ y[k] }
            var q = [UInt64](repeating: 0, count: 128)
            for k in 0..<128 { q[k] = p[k] }
            for row in rowIndices { permute(p, row) }
            for col in colIndices { permute(p, col) }
            for k in 0..<128 {
                let value = p[k] ^ q[k]
                out[k] = xorInto ? out[k] ^ value : value
            }
        }
    }

    public static func hash(password: Data, salt: Data, iterations: Int, memoryKiB: Int, parallelism: Int, length: Int,
                            variant: Variant, secret: Data = Data(), associatedData: Data = Data()) throws -> Data {
        guard iterations >= 1, parallelism >= 1, memoryKiB >= 8 * parallelism, length >= 4, salt.count >= 8
        else { throw CryptoError.unsupported("Argon2 parameters") }

        var h0Input = Data()
        for value in [parallelism, length, memoryKiB, iterations, 0x13, variant.rawValue] { h0Input.append(le32(value)) }
        for part in [password, salt, secret, associatedData] {
            h0Input.append(le32(part.count))
            h0Input.append(part)
        }
        let h0 = Blake2b.hash(h0Input, length: 64)

        let blockCount = 4 * parallelism * (memoryKiB / (4 * parallelism))
        let laneLength = blockCount / parallelism
        let segmentLength = laneLength / 4
        var memory = [UInt64](repeating: 0, count: blockCount * 128)

        func load(_ bytes: Data, into block: Int) {
            bytes.withUnsafeBytes { raw in
                for w in 0..<128 { memory[block * 128 + w] = raw.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self).littleEndian }
            }
        }
        for lane in 0..<parallelism {
            load(hPrime(h0 + le32(0) + le32(lane), length: 1024), into: lane * laneLength)
            load(hPrime(h0 + le32(1) + le32(lane), length: 1024), into: lane * laneLength + 1)
        }

        let zero = [UInt64](repeating: 0, count: 128)
        memory.withUnsafeMutableBufferPointer { mem in
            let base = mem.baseAddress!
            zero.withUnsafeBufferPointer { zeroBuf in
                for pass in 0..<iterations {
                    for slice in 0..<4 {
                        for lane in 0..<parallelism {
                            let independent = variant == .i || (variant == .id && pass == 0 && slice < 2)
                            var addressBlock = [UInt64](repeating: 0, count: 128)
                            var inputBlock = [UInt64](repeating: 0, count: 128)
                            if independent {
                                inputBlock[0] = UInt64(pass); inputBlock[1] = UInt64(lane); inputBlock[2] = UInt64(slice)
                                inputBlock[3] = UInt64(blockCount); inputBlock[4] = UInt64(iterations); inputBlock[5] = UInt64(variant.rawValue)
                            }
                            func nextAddresses() {
                                inputBlock[6] += 1
                                inputBlock.withUnsafeBufferPointer { inp in
                                    addressBlock.withUnsafeMutableBufferPointer { adr in
                                        fillBlock(zeroBuf.baseAddress!, inp.baseAddress!, adr.baseAddress!, xorInto: false)
                                        let copy = Array(adr)
                                        copy.withUnsafeBufferPointer { fillBlock(zeroBuf.baseAddress!, $0.baseAddress!, adr.baseAddress!, xorInto: false) }
                                    }
                                }
                            }
                            var startIndex = 0
                            if pass == 0 && slice == 0 {
                                startIndex = 2
                                if independent { nextAddresses() }
                            }
                            var current = lane * laneLength + slice * segmentLength + startIndex
                            var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
                            for index in startIndex..<segmentLength {
                                if current % laneLength == 1 { previous = current - 1 }
                                let pseudoRandom: UInt64
                                if independent {
                                    if index % 128 == 0 { nextAddresses() }
                                    pseudoRandom = addressBlock[index % 128]
                                } else {
                                    pseudoRandom = base[previous * 128]
                                }
                                let j1 = pseudoRandom & 0xFFFF_FFFF
                                let j2 = pseudoRandom >> 32
                                var refLane = Int(j2 % UInt64(parallelism))
                                if pass == 0 && slice == 0 { refLane = lane }
                                let sameLane = refLane == lane
                                let areaSize: Int
                                if pass == 0 {
                                    if slice == 0 { areaSize = index - 1 }
                                    else if sameLane { areaSize = slice * segmentLength + index - 1 }
                                    else { areaSize = slice * segmentLength + (index == 0 ? -1 : 0) }
                                } else {
                                    if sameLane { areaSize = laneLength - segmentLength + index - 1 }
                                    else { areaSize = laneLength - segmentLength + (index == 0 ? -1 : 0) }
                                }
                                var rel = (j1 * j1) >> 32
                                rel = (UInt64(areaSize) * rel) >> 32
                                let relPos = UInt64(areaSize) - 1 - rel
                                let start = (pass != 0 && slice != 3) ? (slice + 1) * segmentLength : 0
                                let refIndex = (start + Int(relPos)) % laneLength
                                let refBlock = refLane * laneLength + refIndex
                                fillBlock(base + previous * 128, base + refBlock * 128, base + current * 128, xorInto: pass != 0)
                                previous = current
                                current += 1
                            }
                        }
                    }
                }
            }
        }

        var final = [UInt64](repeating: 0, count: 128)
        for lane in 0..<parallelism {
            let last = lane * laneLength + laneLength - 1
            for w in 0..<128 { final[w] ^= memory[last * 128 + w] }
        }
        var bytes = Data()
        for w in final { for k in 0..<8 { bytes.append(UInt8((w >> UInt64(8 * k)) & 0xFF)) } }
        return hPrime(bytes, length: length)
    }
}
