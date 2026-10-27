import Foundation
import CoreGraphics

/// Dependency-free lossy WebP (VP8 key frame) encoder. Fallback when ImageIO/FFmpeg cannot encode WebP.
/// Chooses 16×16 luma and 8×8 chroma intra prediction per macroblock, uses the VP8 integer transforms and
/// per-image token probabilities, and stores any alpha losslessly in an ALPH chunk.
/// Format: https://www.rfc-editor.org/rfc/rfc6386 and https://www.rfc-editor.org/rfc/rfc9649
enum WebPLossy {
    static func write(_ image: CGImage, to url: URL, quality: Double) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16383, h <= 16383, w * h <= 40_000_000 else {
            throw OpenTangerineError.invalidInput("WebP requires dimensions up to 16,383 pixels and at most 40 megapixels.")
        }
        let rgba = try WebPLossless.straightRGBA(image)
        // Logos and UI art with few colours are both smaller and exact as lossless.
        var colors = Set<UInt32>()
        for i in stride(from: 0, to: rgba.count, by: 4) where colors.count <= 256 {
            colors.insert(UInt32(rgba[i]) << 24 | UInt32(rgba[i + 1]) << 16 | UInt32(rgba[i + 2]) << 8 | UInt32(rgba[i + 3]))
        }
        if colors.count <= 256 {
            try WebPLossless.write(rgba: rgba, width: w, height: h, to: url)
            return
        }
        var encoder = VP8Encoder(rgba: rgba, width: w, height: h, quality: quality)
        let frame = try encoder.encode()
        guard stride(from: 3, to: rgba.count, by: 4).contains(where: { rgba[$0] != 255 }) else {
            try WebPLossless.riff([("VP8 ", frame)]).write(to: url, options: .atomic)
            return
        }
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        var extended: [UInt8] = [0x10, 0, 0, 0] // alpha flag
        for v in [w - 1, h - 1] { extended += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8(v >> 16)] }
        let alphaChunk = [UInt8(1)] + (try WebPLossless.alphaStream(alpha, width: w, height: h)) // lossless, unfiltered
        try WebPLossless.riff([("VP8X", extended), ("ALPH", alphaChunk), ("VP8 ", frame)]).write(to: url, options: .atomic)
    }

    /// libwebp's quality-to-quantizer curve, so 0–100% behaves like `cwebp -q`.
    static func quantizerIndex(quality: Double) -> Int {
        let q = min(1, max(0, quality))
        let linear = q < 0.75 ? q * 2 / 3 : 2 * q - 1
        return min(127, max(0, Int(127 * (1 - pow(linear, 1 / 3)))))
    }
}

private struct BoolEncoder {
    private(set) var bytes: [UInt8] = []
    private var range: UInt32 = 255
    private var bottom: UInt32 = 0
    private var bitCount = 24

    mutating func put(_ bit: Bool, _ probability: Int) {
        let split = 1 + (((range - 1) * UInt32(probability)) >> 8)
        if bit { bottom = bottom &+ split; range -= split } else { range = split }
        while range < 128 {
            range <<= 1
            if bottom & (1 << 31) != 0 { // carry into bytes already written
                var i = bytes.count - 1
                while bytes[i] == 255 { bytes[i] = 0; i -= 1 }
                bytes[i] += 1
            }
            bottom <<= 1
            bitCount -= 1
            if bitCount == 0 { bytes.append(UInt8(truncatingIfNeeded: bottom >> 24)); bottom &= (1 << 24) - 1; bitCount = 8 }
        }
    }

    mutating func literal(_ value: Int, _ width: Int) {
        for bit in stride(from: width - 1, through: 0, by: -1) { put(value & (1 << bit) != 0, 128) }
    }

    mutating func finish() -> [UInt8] {
        for _ in 0..<32 { put(false, 128) }
        return bytes
    }
}

private struct VP8Encoder {
    let width: Int, height: Int, mbw: Int, mbh: Int, yStride: Int, uvStride: Int
    let qIndex: Int
    var srcY: [UInt8], srcU: [UInt8], srcV: [UInt8]
    var recY: [UInt8], recU: [UInt8], recV: [UInt8]
    // Quantizer steps and rounding (in 1/256 of a step) per block type: luma, luma DC (Y2), chroma.
    let y1: (dc: Int32, ac: Int32), y2: (dc: Int32, ac: Int32), uv: (dc: Int32, ac: Int32)
    var tokens = BoolEncoder()
    // Token probabilities: a first pass counts 0/1 branches per entry, then entries that pay for themselves are updated.
    var probabilities = VP8Tables.defaultCoeffProbs
    var branchCounts: [UInt32]? = nil
    var yModes: [UInt8], uvModes: [UInt8], skips: [Bool]
    // Non-zero flags of neighbouring blocks, used as token contexts.
    var topY: [UInt8], topU: [UInt8], topV: [UInt8], topY2: [UInt8]
    var leftY = [UInt8](repeating: 0, count: 4), leftU = [UInt8](repeating: 0, count: 2), leftV = [UInt8](repeating: 0, count: 2)
    var leftY2: UInt8 = 0
    // Per-macroblock scratch.
    var predY = [Int32](repeating: 0, count: 256), candidate = [Int32](repeating: 0, count: 256)
    var predU = [Int32](repeating: 0, count: 64), predV = [Int32](repeating: 0, count: 64)
    var candidateU = [Int32](repeating: 0, count: 64), candidateV = [Int32](repeating: 0, count: 64)
    var levelsY = [Int32](repeating: 0, count: 256), levelsY2 = [Int32](repeating: 0, count: 16)
    var levelsU = [Int32](repeating: 0, count: 64), levelsV = [Int32](repeating: 0, count: 64)
    var block = [Int32](repeating: 0, count: 16), coefficients = [Int32](repeating: 0, count: 256)

    init(rgba: [UInt8], width: Int, height: Int, quality: Double) {
        self.width = width; self.height = height
        mbw = (width + 15) / 16; mbh = (height + 15) / 16
        yStride = mbw * 16; uvStride = mbw * 8
        qIndex = WebPLossy.quantizerIndex(quality: quality)
        let dc = Int32(VP8Tables.dcQuant[qIndex]), ac = Int32(VP8Tables.acQuant[qIndex])
        y1 = (dc, ac); y2 = (dc * 2, max(8, ac * 155 / 100)); uv = (min(132, dc), ac)
        srcY = [UInt8](repeating: 0, count: yStride * mbh * 16)
        srcU = [UInt8](repeating: 0, count: uvStride * mbh * 8); srcV = srcU
        recY = srcY; recU = srcU; recV = srcU
        yModes = [UInt8](repeating: 0, count: mbw * mbh); uvModes = yModes
        skips = [Bool](repeating: false, count: mbw * mbh)
        topY = [UInt8](repeating: 0, count: mbw * 4); topU = [UInt8](repeating: 0, count: mbw * 2); topV = topU
        topY2 = [UInt8](repeating: 0, count: mbw)
        // BT.601 limited-range YUV 4:2:0 with libwebp's rounding; edges are replicated to whole macroblocks.
        for y in 0..<(mbh * 16) {
            let row = min(y, height - 1) * width
            for x in 0..<yStride {
                let p = (row + min(x, width - 1)) * 4
                let luma = 16839 * Int(rgba[p]) + 33059 * Int(rgba[p + 1]) + 6420 * Int(rgba[p + 2])
                srcY[y * yStride + x] = UInt8((luma + (1 << 15) + (16 << 16)) >> 16)
            }
        }
        func clipUV(_ v: Int) -> UInt8 { UInt8(min(255, max(0, (v + (1 << 17) + (128 << 18)) >> 18))) }
        for y in 0..<(mbh * 8) {
            for x in 0..<uvStride {
                var r = 0, g = 0, b = 0
                for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let p = (min(y * 2 + dy, height - 1) * width + min(x * 2 + dx, width - 1)) * 4
                    r += Int(rgba[p]); g += Int(rgba[p + 1]); b += Int(rgba[p + 2])
                }
                srcU[y * uvStride + x] = clipUV(-9719 * r - 19081 * g + 28800 * b)
                srcV[y * uvStride + x] = clipUV(28800 * r - 24116 * g - 4684 * b)
            }
        }
    }

    mutating func encode() throws -> [UInt8] {
        branchCounts = [UInt32](repeating: 0, count: probabilities.count * 2)
        try encodeMacroblocks()
        let updates = optimizedProbabilities(branchCounts!)
        branchCounts = nil
        try encodeMacroblocks()
        let tokenPartition = tokens.finish()

        var header = BoolEncoder()
        header.literal(0, 1); header.literal(0, 1)            // colour space, clamping
        header.literal(0, 1)                                    // no segmentation
        header.literal(0, 1); header.literal(min(63, Int(y1.ac) / 4), 6); header.literal(0, 3) // normal loop filter
        header.literal(0, 1)                                    // no loop-filter deltas
        header.literal(0, 2)                                    // one token partition
        header.literal(qIndex, 7); for _ in 0..<5 { header.literal(0, 1) } // no quantizer deltas
        header.literal(0, 1)                                    // refresh_entropy_probs
        for (i, p) in VP8Tables.coeffUpdateProbs.enumerated() {
            header.put(updates[i] != nil, Int(p))
            if let value = updates[i] { header.literal(Int(value), 8) }
        }
        let coded = skips.filter { !$0 }.count
        let probSkipFalse = min(255, max(1, (coded * 256 + skips.count / 2) / skips.count))
        header.literal(1, 1); header.literal(probSkipFalse, 8)
        for i in 0..<(mbw * mbh) {
            header.put(skips[i], probSkipFalse)
            let y = Int(yModes[i]) // 0 DC, 1 V, 2 H, 3 TM
            header.put(true, 145)
            if y < 2 { header.put(false, 156); header.put(y == 1, 163) } else { header.put(true, 156); header.put(y == 3, 128) }
            let c = Int(uvModes[i])
            header.put(c != 0, 142)
            if c != 0 { header.put(c != 1, 114); if c != 1 { header.put(c == 3, 183) } }
        }
        let firstPartition = header.finish()
        guard firstPartition.count < 1 << 19 else { throw OpenTangerineError.encodeFailed("WebP: image header too large") }

        let tag = firstPartition.count << 5 | 1 << 4 // key frame, version 0, shown
        var frame: [UInt8] = [UInt8(tag & 255), UInt8((tag >> 8) & 255), UInt8(tag >> 16), 0x9d, 0x01, 0x2a,
                              UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)]
        frame.reserveCapacity(frame.count + firstPartition.count + tokenPartition.count)
        frame += firstPartition
        frame += tokenPartition
        return frame
    }

    private mutating func encodeMacroblocks() throws {
        tokens = BoolEncoder()
        topY = topY.map { _ in 0 }; topU = topU.map { _ in 0 }; topV = topV.map { _ in 0 }; topY2 = topY2.map { _ in 0 }
        for my in 0..<mbh {
            try Task.checkCancellation()
            leftY = [0, 0, 0, 0]; leftU = [0, 0]; leftV = [0, 0]; leftY2 = 0
            for mx in 0..<mbw { encodeMacroblock(mx, my) }
        }
    }

    /// Picks a new probability for every entry whose saving outweighs the cost of signalling it.
    private mutating func optimizedProbabilities(_ counts: [UInt32]) -> [UInt8?] {
        func bits(_ p: Double, _ zeros: Double, _ ones: Double) -> Double { -(zeros * log2(p / 256) + ones * log2(1 - p / 256)) }
        return (0..<probabilities.count).map { i in
            let zeros = Double(counts[i * 2]), ones = Double(counts[i * 2 + 1])
            guard zeros + ones > 0 else { return nil }
            let candidate = min(255, max(1, (256 * zeros / (zeros + ones)).rounded()))
            let update = Double(VP8Tables.coeffUpdateProbs[i])
            let saving = bits(Double(probabilities[i]), zeros, ones) - bits(candidate, zeros, ones)
            guard saving > 8 + bits(update, 0, 1) - bits(update, 1, 0) else { return nil }
            probabilities[i] = UInt8(candidate)
            return UInt8(candidate)
        }
    }

    // MARK: - Macroblock

    private mutating func encodeMacroblock(_ mx: Int, _ my: Int) {
        let index = my * mbw + mx, hasTop = my > 0, hasLeft = mx > 0
        let modes = [0] + (hasTop ? [1] : []) + (hasLeft ? [2] : []) + (hasTop && hasLeft ? [3] : [])

        // Luma: pick the 16×16 mode with the smallest residual, then code DCs through the Y2 Walsh–Hadamard block.
        let x0 = mx * 16, y0 = my * 16
        var bestY = 0, bestCost = Int.max
        for mode in modes {
            Self.predict(mode, recY, stride: yStride, x: x0, y: y0, size: 16, hasTop: hasTop, hasLeft: hasLeft, into: &candidate)
            let cost = Self.sad(srcY, yStride, x0, y0, candidate, 16)
            if cost < bestCost { bestCost = cost; bestY = mode; predY = candidate }
        }
        for b in 0..<16 {
            let bx = (b & 3) * 4, by = (b >> 2) * 4
            for r in 0..<4 { for c in 0..<4 {
                block[r * 4 + c] = Int32(srcY[(y0 + by + r) * yStride + x0 + bx + c]) - predY[(by + r) * 16 + bx + c]
            } }
            Self.forwardDCT(block, into: &coefficients, at: b * 16)
        }
        for b in 0..<16 { block[b] = coefficients[b * 16] }
        Self.forwardWHT(block, into: &levelsY2)
        for i in 0..<16 { levelsY2[i] = Self.quantize(levelsY2[i], i == 0 ? y2.dc : y2.ac, i == 0 ? 96 : 108) }
        for b in 0..<16 {
            levelsY[b * 16] = 0
            for i in 1..<16 { levelsY[b * 16 + i] = Self.quantize(coefficients[b * 16 + i], y1.ac, 110) }
        }
        for i in 0..<16 { block[i] = levelsY2[i] * (i == 0 ? y2.dc : y2.ac) }
        Self.inverseWHT(block, into: &coefficients) // coefficients[0..<16] now holds each block's DC
        let dcs = Array(coefficients[0..<16])
        for b in 0..<16 {
            block[0] = dcs[b]
            for i in 1..<16 { block[i] = levelsY[b * 16 + i] * y1.ac }
            Self.reconstruct(block, prediction: predY, predStride: 16, px: (b & 3) * 4, py: (b >> 2) * 4,
                             into: &recY, stride: yStride, x: x0 + (b & 3) * 4, y: y0 + (b >> 2) * 4)
        }

        // Chroma: one 8×8 mode shared by U and V.
        let cx = mx * 8, cy = my * 8
        var bestUV = 0
        bestCost = Int.max
        for mode in modes {
            Self.predict(mode, recU, stride: uvStride, x: cx, y: cy, size: 8, hasTop: hasTop, hasLeft: hasLeft, into: &candidateU)
            Self.predict(mode, recV, stride: uvStride, x: cx, y: cy, size: 8, hasTop: hasTop, hasLeft: hasLeft, into: &candidateV)
            let cost = Self.sad(srcU, uvStride, cx, cy, candidateU, 8) + Self.sad(srcV, uvStride, cx, cy, candidateV, 8)
            if cost < bestCost { bestCost = cost; bestUV = mode; predU = candidateU; predV = candidateV }
        }
        encodeChroma(v: false, x: cx, y: cy)
        encodeChroma(v: true, x: cx, y: cy)

        yModes[index] = UInt8(bestY); uvModes[index] = UInt8(bestUV)
        let skip = !levelsY2.contains { $0 != 0 } && !levelsY.contains { $0 != 0 }
            && !levelsU.contains { $0 != 0 } && !levelsV.contains { $0 != 0 }
        skips[index] = skip
        if skip {
            for k in 0..<4 { topY[mx * 4 + k] = 0; leftY[k] = 0 }
            for k in 0..<2 { topU[mx * 2 + k] = 0; topV[mx * 2 + k] = 0; leftU[k] = 0; leftV[k] = 0 }
            topY2[mx] = 0; leftY2 = 0
            return
        }
        let y2nz = writeBlock(levelsY2, at: 0, type: 1, first: 0, context: Int(topY2[mx] + leftY2))
        topY2[mx] = y2nz; leftY2 = y2nz
        for by in 0..<4 { for bx in 0..<4 {
            let nz = writeBlock(levelsY, at: (by * 4 + bx) * 16, type: 0, first: 1, context: Int(topY[mx * 4 + bx] + leftY[by]))
            topY[mx * 4 + bx] = nz; leftY[by] = nz
        } }
        for by in 0..<2 { for bx in 0..<2 {
            let nz = writeBlock(levelsU, at: (by * 2 + bx) * 16, type: 2, first: 0, context: Int(topU[mx * 2 + bx] + leftU[by]))
            topU[mx * 2 + bx] = nz; leftU[by] = nz
        } }
        for by in 0..<2 { for bx in 0..<2 {
            let nz = writeBlock(levelsV, at: (by * 2 + bx) * 16, type: 2, first: 0, context: Int(topV[mx * 2 + bx] + leftV[by]))
            topV[mx * 2 + bx] = nz; leftV[by] = nz
        } }
    }

    private mutating func encodeChroma(v: Bool, x: Int, y: Int) {
        let source = v ? srcV : srcU, prediction = v ? predV : predU
        for b in 0..<4 {
            let bx = (b & 1) * 4, by = (b >> 1) * 4
            for r in 0..<4 { for c in 0..<4 {
                block[r * 4 + c] = Int32(source[(y + by + r) * uvStride + x + bx + c]) - prediction[(by + r) * 8 + bx + c]
            } }
            Self.forwardDCT(block, into: &coefficients, at: 0)
            for i in 0..<16 {
                let level = Self.quantize(coefficients[i], i == 0 ? uv.dc : uv.ac, i == 0 ? 110 : 115)
                if v { levelsV[b * 16 + i] = level } else { levelsU[b * 16 + i] = level }
                block[i] = level * (i == 0 ? uv.dc : uv.ac)
            }
            if v {
                Self.reconstruct(block, prediction: prediction, predStride: 8, px: bx, py: by, into: &recV, stride: uvStride, x: x + bx, y: y + by)
            } else {
                Self.reconstruct(block, prediction: prediction, predStride: 8, px: bx, py: by, into: &recU, stride: uvStride, x: x + bx, y: y + by)
            }
        }
    }

    // MARK: - Prediction and transforms

    /// VP8 intra prediction from reconstructed neighbours. V needs a top row, H a left column, TM both.
    private static func predict(_ mode: Int, _ rec: [UInt8], stride: Int, x: Int, y: Int, size n: Int, hasTop: Bool, hasLeft: Bool, into out: inout [Int32]) {
        switch mode {
        case 1:
            for r in 0..<n { for c in 0..<n { out[r * n + c] = Int32(rec[(y - 1) * stride + x + c]) } }
        case 2:
            for r in 0..<n { let left = Int32(rec[(y + r) * stride + x - 1]); for c in 0..<n { out[r * n + c] = left } }
        case 3:
            let corner = Int32(rec[(y - 1) * stride + x - 1])
            for r in 0..<n {
                let left = Int32(rec[(y + r) * stride + x - 1])
                for c in 0..<n { out[r * n + c] = min(255, max(0, left + Int32(rec[(y - 1) * stride + x + c]) - corner)) }
            }
        default:
            let shift = n == 16 ? 4 : 3
            var sum: Int32 = 0
            if hasTop { for c in 0..<n { sum += Int32(rec[(y - 1) * stride + x + c]) } }
            if hasLeft { for r in 0..<n { sum += Int32(rec[(y + r) * stride + x - 1]) } }
            let value: Int32
            switch (hasTop, hasLeft) {
            case (true, true): value = (sum + Int32(n)) >> Int32(shift + 1)
            case (false, false): value = 128
            default: value = (sum + Int32(n / 2)) >> Int32(shift)
            }
            for i in 0..<(n * n) { out[i] = value }
        }
    }

    private static func sad(_ src: [UInt8], _ stride: Int, _ x: Int, _ y: Int, _ pred: [Int32], _ n: Int) -> Int {
        var total: Int32 = 0
        for r in 0..<n { for c in 0..<n { total += abs(Int32(src[(y + r) * stride + x + c]) - pred[r * n + c]) } }
        return Int(total)
    }

    @inline(__always) private static func quantize(_ value: Int32, _ step: Int32, _ bias: Int32) -> Int32 {
        let level = min(2047, (abs(value) + (step * bias >> 8)) / step)
        return value < 0 ? -level : level
    }

    private static func forwardDCT(_ input: [Int32], into out: inout [Int32], at offset: Int) {
        var tmp = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let p = i * 4
            let a = (input[p] + input[p + 3]) * 8, b = (input[p + 1] + input[p + 2]) * 8
            let c = (input[p + 1] - input[p + 2]) * 8, d = (input[p] - input[p + 3]) * 8
            tmp[p] = a + b; tmp[p + 2] = a - b
            tmp[p + 1] = (c * 2217 + d * 5352 + 14500) >> 12
            tmp[p + 3] = (d * 2217 - c * 5352 + 7500) >> 12
        }
        for i in 0..<4 {
            let a = tmp[i] + tmp[12 + i], b = tmp[4 + i] + tmp[8 + i]
            let c = tmp[4 + i] - tmp[8 + i], d = tmp[i] - tmp[12 + i]
            out[offset + i] = (a + b + 7) >> 4
            out[offset + 8 + i] = (a - b + 7) >> 4
            out[offset + 4 + i] = ((c * 2217 + d * 5352 + 12000) >> 16) + (d != 0 ? 1 : 0)
            out[offset + 12 + i] = (d * 2217 - c * 5352 + 51000) >> 16
        }
    }

    private static func forwardWHT(_ input: [Int32], into out: inout [Int32]) {
        var tmp = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let p = i * 4
            let a = (input[p] + input[p + 2]) * 4, d = (input[p + 1] + input[p + 3]) * 4
            let c = (input[p + 1] - input[p + 3]) * 4, b = (input[p] - input[p + 2]) * 4
            tmp[p] = a + d + (a != 0 ? 1 : 0); tmp[p + 1] = b + c; tmp[p + 2] = b - c; tmp[p + 3] = a - d
        }
        for i in 0..<4 {
            let a = tmp[i] + tmp[8 + i], d = tmp[4 + i] + tmp[12 + i]
            let c = tmp[4 + i] - tmp[12 + i], b = tmp[i] - tmp[8 + i]
            for (k, v) in [a + d, b + c, b - c, a - d].enumerated() { out[k * 4 + i] = (v + (v < 0 ? 1 : 0) + 3) >> 3 }
        }
    }

    /// Exact decoder inverse WHT (RFC 6386 §14.3).
    private static func inverseWHT(_ input: [Int32], into out: inout [Int32]) {
        var tmp = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let a = input[i] + input[12 + i], b = input[4 + i] + input[8 + i]
            let c = input[4 + i] - input[8 + i], d = input[i] - input[12 + i]
            tmp[i] = a + b; tmp[4 + i] = c + d; tmp[8 + i] = a - b; tmp[12 + i] = d - c
        }
        for i in 0..<4 {
            let p = i * 4
            let a = tmp[p] + tmp[p + 3], b = tmp[p + 1] + tmp[p + 2]
            let c = tmp[p + 1] - tmp[p + 2], d = tmp[p] - tmp[p + 3]
            out[p] = (a + b + 3) >> 3; out[p + 1] = (c + d + 3) >> 3; out[p + 2] = (a - b + 3) >> 3; out[p + 3] = (d - c + 3) >> 3
        }
    }

    /// Exact decoder inverse DCT (RFC 6386 §14.4) added to the prediction, so encoder and decoder stay in sync.
    private static func reconstruct(_ input: [Int32], prediction: [Int32], predStride: Int, px: Int, py: Int,
                                    into rec: inout [UInt8], stride: Int, x: Int, y: Int) {
        func mul1(_ v: Int32) -> Int32 { ((v * 20091) >> 16) + v }
        func mul2(_ v: Int32) -> Int32 { (v * 35468) >> 16 }
        var tmp = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let a = input[i] + input[8 + i], b = input[i] - input[8 + i]
            let c = mul2(input[4 + i]) - mul1(input[12 + i]), d = mul1(input[4 + i]) + mul2(input[12 + i])
            tmp[i] = a + d; tmp[12 + i] = a - d; tmp[4 + i] = b + c; tmp[8 + i] = b - c
        }
        for r in 0..<4 {
            let p = r * 4
            let a = tmp[p] + tmp[p + 2], b = tmp[p] - tmp[p + 2]
            let c = mul2(tmp[p + 1]) - mul1(tmp[p + 3]), d = mul1(tmp[p + 1]) + mul2(tmp[p + 3])
            let row = [(a + d + 4) >> 3, (b + c + 4) >> 3, (b - c + 4) >> 3, (a - d + 4) >> 3]
            for c in 0..<4 {
                let value = prediction[(py + r) * predStride + px + c] + row[c]
                rec[(y + r) * stride + x + c] = UInt8(min(255, max(0, value)))
            }
        }
    }

    // MARK: - Tokens

    /// Codes one block's coefficients (or only counts branches in the first pass); returns 1 when any were non-zero.
    private mutating func writeBlock(_ levels: [Int32], at offset: Int, type: Int, first: Int, context: Int) -> UInt8 {
        var last = -1
        for i in stride(from: 15, through: first, by: -1) where levels[offset + VP8Tables.zigzag[i]] != 0 { last = i; break }
        var ctx = context, i = first, afterZero = false
        func branch(_ bit: Bool, _ node: Int) {
            let entry = ((type * 8 + VP8Tables.bands[i]) * 3 + ctx) * 11 + node
            if branchCounts != nil { branchCounts![entry * 2 + (bit ? 1 : 0)] += 1 } else { tokens.put(bit, Int(probabilities[entry])) }
        }
        func fixed(_ bit: Bool, _ probability: Int) { if branchCounts == nil { tokens.put(bit, probability) } }
        while i <= last {
            if !afterZero { branch(true, 0) } // not end-of-block
            let value = levels[offset + VP8Tables.zigzag[i]]
            if value == 0 {
                branch(false, 1); ctx = 0; afterZero = true; i += 1
                continue
            }
            branch(true, 1)
            let magnitude = Int(abs(value))
            if magnitude == 1 {
                branch(false, 2)
            } else {
                branch(true, 2)
                if magnitude <= 4 {
                    branch(false, 3)
                    branch(magnitude != 2, 4)
                    if magnitude != 2 { branch(magnitude == 4, 5) }
                } else {
                    branch(true, 3)
                    let category = VP8Tables.categories.lastIndex { magnitude >= $0.base }!
                    branch(category >= 2, 6)
                    if category < 2 {
                        branch(category == 1, 7)
                    } else {
                        branch(category >= 4, 8)
                        branch(category & 1 == 1, category < 4 ? 9 : 10)
                    }
                    let (base, probs) = VP8Tables.categories[category]
                    for (k, p) in probs.enumerated() { fixed((magnitude - base) & (1 << (probs.count - 1 - k)) != 0, Int(p)) }
                }
            }
            fixed(value < 0, 128)
            ctx = magnitude == 1 ? 1 : 2; afterZero = false; i += 1
        }
        if i < 16 { branch(false, 0) } // end-of-block
        return last >= 0 ? 1 : 0
    }
}

enum VP8Tables {
    static let zigzag = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
    static let bands = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0]
    /// DCT_CAT1…DCT_CAT6: smallest magnitude and extra-bit probabilities.
    static let categories: [(base: Int, probs: [UInt8])] = [
        (5, [159]), (7, [165, 145]), (11, [173, 148, 140]), (19, [176, 155, 140, 135]),
        (35, [180, 157, 141, 134, 130]), (67, [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]),
    ]
    /// RFC 6386 §14.1 quantizer step tables.
    static let dcQuant: [Int16] = [
        4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
        18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
        44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
        59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
        75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
        91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
        122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
    ]
    static let acQuant: [Int16] = [
        4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
        20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
        52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
        78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108,
        110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
        155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
        213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
    ]
    /// RFC 6386 §13.5, default token probabilities [4 types][8 bands][3 contexts][11 nodes].
    static let defaultCoeffProbs: [UInt8] = [
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
        189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128,
        106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
        1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128,
        181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
        78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128,
        1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
        184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128,
        77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
        1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128,
        170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
        37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128,
        1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
        207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128,
        102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
        1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128,
        177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
        80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128,
        1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62,
        131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
        68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128,
        1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
        184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128,
        81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
        1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128,
        99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
        23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128,
        1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
        109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128,
        44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
        1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128,
        94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
        22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128,
        1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
        124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128,
        35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
        1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128,
        121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
        45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128,
        1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
        203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128,
        137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
        253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128,
        175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
        73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128,
        1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
        239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128,
        155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
        1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128,
        201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
        69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128,
        1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
        223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128,
        141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
        1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128,
        190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
        149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128,
        213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
        55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
        202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255,
        126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
        61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128,
        1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
        166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128,
        39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
        1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128,
        124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
        24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128,
        1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
        149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128,
        28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
        1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128,
        123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
        20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128,
        1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
        168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128,
        47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
        1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128,
        141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
        42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128,
        1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
        238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    ]
    /// RFC 6386 §13.4, probabilities of the per-entry "update" flags.
    static let coeffUpdateProbs: [UInt8] = [
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255,
        249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255,
        234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255,
        250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
        254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
        234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255,
        255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
        255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255,
        234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
        251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255,
        255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
        255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
        248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255,
        255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
        255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255,
        248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255,
        255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255,
        250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    ]
}
