import Foundation
import CoreGraphics

/// Dependency-free WebP lossless (VP8L) encoder. Fallback when ImageIO/FFmpeg cannot encode WebP at 100% quality,
/// and the compressor for the alpha plane of lossy files. Uses the subtract-green and spatial-predictor transforms,
/// canonical prefix codes and run-length backward references to the left and above pixels.
/// Format: https://www.rfc-editor.org/rfc/rfc9649
enum WebPLossless {
    static func write(_ image: CGImage, to url: URL) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 40_000_000 else {
            throw OpenTangerineError.invalidInput("WebP requires dimensions up to 16,384 pixels and at most 40 megapixels.")
        }
        try write(rgba: try straightRGBA(image), width: w, height: h, to: url)
    }

    static func write(rgba: [UInt8], width w: Int, height h: Int, to url: URL) throws {
        var argb = [UInt32](repeating: 0, count: w * h)
        var hasAlpha = false
        for i in 0..<(w * h) {
            let a = UInt32(rgba[i * 4 + 3])
            if a != 255 { hasAlpha = true }
            argb[i] = a << 24 | UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2])
        }
        var bits = BitWriter()
        bits.put(0x2f, 8); bits.put(w - 1, 14); bits.put(h - 1, 14); bits.put(hasAlpha ? 1 : 0, 1); bits.put(0, 3)
        try encode(&argb, width: w, height: h, subtractGreen: true, into: &bits)
        bits.finish()
        try riff([("VP8L", bits.bytes)]).write(to: url, options: .atomic)
    }

    /// Header-less VP8L stream carrying `alpha` in the green channel, as stored in an ALPH chunk with compression 1.
    static func alphaStream(_ alpha: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        var argb = alpha.map { 0xff00_0000 | UInt32($0) << 8 }
        var bits = BitWriter()
        try encode(&argb, width: width, height: height, subtractGreen: false, into: &bits)
        bits.finish()
        return bits.bytes
    }

    /// 8-bit sRGB RGBA with straight (non-premultiplied) alpha.
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw OpenTangerineError.encodeFailed("WebP pixel buffer") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            guard alpha != 255 else { continue }
            for channel in 0..<3 {
                pixels[i + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[i + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return pixels
    }

    static func riff(_ chunks: [(String, [UInt8])]) -> Data {
        func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> ($0 * 8)) & 255) } }
        var body = Array("WEBP".utf8)
        for (tag, payload) in chunks {
            body += Array(tag.utf8) + le32(payload.count) + payload
            if payload.count & 1 != 0 { body.append(0) }
        }
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    // MARK: - Transforms

    private static func encode(_ argb: inout [UInt32], width: Int, height: Int, subtractGreen: Bool, into bits: inout BitWriter) throws {
        if subtractGreen {
            bits.put(1, 1); bits.put(2, 2)
            for i in argb.indices {
                let p = argb[i], green = (p >> 8) & 0xff
                argb[i] = (p & 0xff00_ff00) | ((((p >> 16) &- green) & 0xff) << 16) | (((p & 0xff) &- green) & 0xff)
            }
        }
        let sizeBits = 4
        bits.put(1, 1); bits.put(0, 2); bits.put(sizeBits - 2, 3)
        let (modes, residual) = try predict(argb, width: width, height: height, sizeBits: sizeBits)
        try writeImage(modes, width: (width + (1 << sizeBits) - 1) >> sizeBits, main: false, into: &bits)
        bits.put(0, 1) // no further transforms
        try writeImage(residual, width: width, main: true, into: &bits)
    }

    /// Chooses one predictor per tile by smallest absolute residual, returning the mode sub-image and residuals.
    private static func predict(_ px: [UInt32], width w: Int, height h: Int, sizeBits: Int) throws -> (modes: [UInt32], residual: [UInt32]) {
        let tile = 1 << sizeBits, tilesWide = (w + tile - 1) >> sizeBits, tilesHigh = (h + tile - 1) >> sizeBits
        var modes = [UInt32](repeating: 0, count: tilesWide * tilesHigh)
        var residual = [UInt32](repeating: 0, count: w * h)
        func cost(_ v: UInt32) -> Int {
            var total = 0
            for shift in stride(from: UInt32(0), to: 32, by: 8) { let c = Int((v >> shift) & 0xff); total += c < 128 ? c : 256 - c }
            return total
        }
        for ty in 0..<tilesHigh {
            try Task.checkCancellation()
            for tx in 0..<tilesWide {
                let ys = ty * tile, ye = min(h, ys + tile), xs = tx * tile, xe = min(w, xs + tile)
                var best = 11, bestCost = Int.max
                for mode in [1, 2, 7, 11, 12] {
                    var total = 0
                    for y in ys..<ye { for x in xs..<xe { total += cost(subPixels(px[y * w + x], prediction(mode, px, x, y, w))) } }
                    if total < bestCost { best = mode; bestCost = total }
                }
                modes[ty * tilesWide + tx] = 0xff00_0000 | UInt32(best) << 8
                for y in ys..<ye { for x in xs..<xe { residual[y * w + x] = subPixels(px[y * w + x], prediction(best, px, x, y, w)) } }
            }
        }
        return (modes, residual)
    }

    @inline(__always) private static func prediction(_ mode: Int, _ px: [UInt32], _ x: Int, _ y: Int, _ w: Int) -> UInt32 {
        let i = y * w + x
        if y == 0 { return x == 0 ? 0xff00_0000 : px[i - 1] }
        if x == 0 { return px[i - w] }
        let left = px[i - 1], top = px[i - w], topLeft = px[i - w - 1]
        switch mode {
        case 1: return left
        case 2: return top
        case 7: return (((left ^ top) & 0xfefe_fefe) >> 1) &+ (left & top)
        case 11:
            // Select: pick whichever of left/top is closer to the gradient estimate left + top - topLeft.
            var towardLeft = 0, towardTop = 0
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                let l = Int((left >> shift) & 0xff), t = Int((top >> shift) & 0xff), tl = Int((topLeft >> shift) & 0xff)
                towardLeft += abs(t - tl); towardTop += abs(l - tl)
            }
            return towardLeft < towardTop ? left : top
        default:
            var result: UInt32 = 0
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                let v = Int((left >> shift) & 0xff) + Int((top >> shift) & 0xff) - Int((topLeft >> shift) & 0xff)
                result |= UInt32(min(255, max(0, v))) << shift
            }
            return result
        }
    }

    @inline(__always) private static func subPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alphaGreen = 0x00ff_00ff &+ (a & 0xff00_ff00) &- (b & 0xff00_ff00)
        let redBlue = 0xff00_ff00 &+ (a & 0x00ff_00ff) &- (b & 0x00ff_00ff)
        return (alphaGreen & 0xff00_ff00) | (redBlue & 0x00ff_00ff)
    }

    // MARK: - Entropy coding

    private enum Token { case literal(UInt32), copy(length: Int, distanceCode: Int) }

    /// Greedy run-length matcher; distance code 1 copies from the row above, 2 from the previous pixel.
    private static func tokenize(_ px: [UInt32], width: Int, _ body: (Token) -> Void) throws {
        var i = 0, nextCheck = 0
        while i < px.count {
            if i >= nextCheck { try Task.checkCancellation(); nextCheck = i + 65536 }
            let limit = min(4096, px.count - i)
            var left = 0, above = 0
            if i >= 1 { while left < limit && px[i + left] == px[i + left - 1] { left += 1 } }
            if i >= width { while above < limit && px[i + above] == px[i + above - width] { above += 1 } }
            if max(left, above) >= 3 {
                let length = max(left, above)
                body(.copy(length: length, distanceCode: above >= left ? 1 : 2))
                i += length
            } else {
                body(.literal(px[i]))
                i += 1
            }
        }
    }

    /// LZ77 prefix coding of a 1-based length or distance code.
    @inline(__always) private static func prefix(_ value: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let d = value - 1
        if d < 4 { return (d, 0, 0) }
        let high = Int.bitWidth - 1 - d.leadingZeroBitCount
        let extraBits = high - 1
        return (2 * high + ((d >> extraBits) & 1), extraBits, d & ((1 << extraBits) - 1))
    }

    private static func writeImage(_ px: [UInt32], width: Int, main: Bool, into bits: inout BitWriter) throws {
        bits.put(0, 1) // no color cache
        if main { bits.put(0, 1) } // one prefix-code group for the whole image
        var green = [Int](repeating: 0, count: 280), red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256), alpha = [Int](repeating: 0, count: 256), distance = [Int](repeating: 0, count: 40)
        try tokenize(px, width: width) { token in
            switch token {
            case let .literal(p):
                green[Int((p >> 8) & 0xff)] += 1; red[Int((p >> 16) & 0xff)] += 1
                blue[Int(p & 0xff)] += 1; alpha[Int(p >> 24)] += 1
            case let .copy(length, distanceCode):
                green[256 + prefix(length).code] += 1; distance[prefix(distanceCode).code] += 1
            }
        }
        let codes = [green, red, blue, alpha, distance].map { PrefixCode(counts: $0, limit: 15) }
        for code in codes { code.writeDefinition(into: &bits) }
        try tokenize(px, width: width) { token in
            switch token {
            case let .literal(p):
                codes[0].write(Int((p >> 8) & 0xff), into: &bits); codes[1].write(Int((p >> 16) & 0xff), into: &bits)
                codes[2].write(Int(p & 0xff), into: &bits); codes[3].write(Int(p >> 24), into: &bits)
            case let .copy(length, distanceCode):
                let l = prefix(length), d = prefix(distanceCode)
                codes[0].write(256 + l.code, into: &bits); bits.put(l.extra, l.extraBits)
                codes[4].write(d.code, into: &bits); bits.put(d.extra, d.extraBits)
            }
        }
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var pending: UInt64 = 0
        private var count = 0
        mutating func put(_ value: Int, _ width: Int) {
            pending |= UInt64(truncatingIfNeeded: value) << UInt64(count)
            count += width
            while count >= 8 { bytes.append(UInt8(truncatingIfNeeded: pending)); pending >>= 8; count -= 8 }
        }
        mutating func finish() { if count > 0 { bytes.append(UInt8(truncatingIfNeeded: pending)); pending = 0; count = 0 } }
    }

    /// Canonical, length-limited prefix code. A code with one used symbol costs zero bits per symbol.
    private struct PrefixCode {
        let lengths: [UInt8]
        let codes: [Int]
        let used: [Int]

        init(counts: [Int], limit: Int) {
            used = counts.indices.filter { counts[$0] > 0 }
            lengths = Self.lengths(counts, used: used, limit: limit)
            codes = Self.canonical(lengths)
        }

        @inline(__always) func write(_ symbol: Int, into bits: inout BitWriter) {
            if used.count > 1 { bits.put(codes[symbol], Int(lengths[symbol])) }
        }

        func writeDefinition(into bits: inout BitWriter) {
            if used.count <= 2, used.allSatisfy({ $0 < 256 }) {
                bits.put(1, 1) // simple code
                let symbols = used.isEmpty ? [0] : used
                bits.put(symbols.count - 1, 1)
                if symbols[0] < 2 { bits.put(0, 1); bits.put(symbols[0], 1) } else { bits.put(1, 1); bits.put(symbols[0], 8) }
                if symbols.count == 2 { bits.put(symbols[1], 8) }
                return
            }
            bits.put(0, 1) // normal code
            var tokens: [(symbol: Int, extraBits: Int, extra: Int)] = []
            var previous = 8, i = 0
            while i < lengths.count {
                let value = Int(lengths[i])
                var run = 1
                while i + run < lengths.count && lengths[i + run] == lengths[i] { run += 1 }
                i += run
                if value == 0 {
                    while run >= 11 { let n = min(run, 138); tokens.append((18, 7, n - 11)); run -= n }
                    if run >= 3 { tokens.append((17, 3, run - 3)); run = 0 }
                } else {
                    if value != previous { tokens.append((value, 0, 0)); previous = value; run -= 1 }
                    while run >= 3 { let n = min(run, 6); tokens.append((16, 2, n - 3)); run -= n }
                }
                tokens += Array(repeating: (value, 0, 0), count: run)
            }
            var counts = [Int](repeating: 0, count: 19)
            for token in tokens { counts[token.symbol] += 1 }
            let lengthCode = PrefixCode(counts: counts, limit: 7)
            let order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            let stored = max(4, (order.lastIndex { lengthCode.lengths[$0] > 0 } ?? 0) + 1)
            bits.put(stored - 4, 4)
            for k in 0..<stored { bits.put(Int(lengthCode.lengths[order[k]]), 3) }
            bits.put(0, 1) // code lengths cover the whole alphabet
            for token in tokens {
                lengthCode.write(token.symbol, into: &bits)
                bits.put(token.extra, token.extraBits)
            }
        }

        private static func lengths(_ counts: [Int], used: [Int], limit: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: counts.count)
            if used.count == 1 { result[used[0]] = 1 }
            guard used.count > 1 else { return result }
            var floor = 1
            while true {
                // Huffman tree over the used symbols; raising the weight floor flattens it until it fits the limit.
                var weight = used.map { max(counts[$0], floor) }
                var parent = [Int](repeating: -1, count: used.count * 2)
                var active = Array(used.indices)
                while active.count > 1 {
                    var picked: [Int] = []
                    for _ in 0..<2 {
                        var best = 0
                        for k in active.indices where weight[active[k]] < weight[active[best]] { best = k }
                        picked.append(active.remove(at: best))
                    }
                    parent[picked[0]] = weight.count; parent[picked[1]] = weight.count
                    active.append(weight.count)
                    weight.append(weight[picked[0]] + weight[picked[1]])
                }
                var depths: [Int] = []
                for leaf in used.indices {
                    var depth = 0, node = leaf
                    while parent[node] >= 0 { node = parent[node]; depth += 1 }
                    depths.append(depth)
                }
                if depths.max()! <= limit {
                    for (k, symbol) in used.enumerated() { result[symbol] = UInt8(depths[k]) }
                    return result
                }
                floor *= 2
            }
        }

        /// Deflate-style canonical codes, bit-reversed because VP8L packs bits least significant first.
        private static func canonical(_ lengths: [UInt8]) -> [Int] {
            var perLength = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { perLength[Int(length)] += 1 }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1..<16 { code = (code + perLength[bits - 1]) << 1; next[bits] = code }
            return lengths.map { length in
                guard length > 0 else { return 0 }
                let value = next[Int(length)]
                next[Int(length)] += 1
                var reversed = 0
                for bit in 0..<Int(length) where value & (1 << bit) != 0 { reversed |= 1 << (Int(length) - 1 - bit) }
                return reversed
            }
        }
    }
}
