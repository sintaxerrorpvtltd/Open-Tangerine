import AppKit
import ImageIO

@main struct ImageConversionTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTangerine-images-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        // Asymmetric, partially transparent pixels catch channel swaps, alpha loss and vertical flips.
        func rgba(_ image: CGImage) -> [UInt8] {
            let c = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
        }
        for (w,h) in [(1,1),(17,19),(80,64)] {
            let c = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let pixels=c.data!.assumingMemoryBound(to:UInt8.self)
            for i in 0..<(w*h) { let a = (i*37+128)%256; pixels[i*4]=UInt8((i*13)%max(1,a)); pixels[i*4+1]=UInt8((i*7)%max(1,a)); pixels[i*4+2]=UInt8((i*29)%max(1,a)); pixels[i*4+3]=UInt8(a) }
            let original = c.makeImage()!, output = root.appendingPathComponent("lossless-\(w).webp")
            try WebPLossless.write(original,to:output)
            let decoded = try ImageIOBridge.load(output)
            precondition(decoded.width == w && decoded.height == h)
            let lhs=rgba(original), rhs=rgba(decoded)
            precondition(zip(lhs,rhs).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "WebP RGBA roundtrip mismatch")
            if FFmpeg.isAvailable { try await FFmpeg.run(["-i",output.path,"-f","null","-"],purpose:"Independent WebP decode") }
            count += 1
        }
        func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var squared = 0.0, n = 0.0
            for i in a.indices where i % 4 != 3 { let d = Double(Int(a[i]) - Int(b[i])); squared += d * d; n += 1 }
            return 10 * log10(255 * 255 / max(squared / n, 1e-9))
        }
        // Lossy fallback: photo-like content must shrink well below raw size, decode faithfully and keep alpha exact.
        for (w,h,transparent) in [(640,480,false),(333,517,true)] {
            let c = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let pixels=c.data!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let i=(y*w+x)*4, a = transparent ? UInt8(x < w/3 ? 0 : x < 2*w/3 ? 128 : 255) : 255
                let noise = (x*7919 + y*104729) % 9
                let rgb = [UInt8(min(255, x*255/w + noise)), UInt8(min(255, y*255/h + noise)), UInt8((x+y)*128/(w+h) + 60)]
                for k in 0..<3 { pixels[i+k] = UInt8(Int(rgb[k]) * Int(a) / 255) }
                pixels[i+3]=a
            } }
            let original = c.makeImage()!, output = root.appendingPathComponent("lossy-\(w).webp")
            try WebPLossy.write(original,to:output,quality:0.9)
            let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! Int
            let decoded = try ImageIOBridge.load(output)
            precondition(decoded.width == w && decoded.height == h)
            let lhs=rgba(original), rhs=rgba(decoded)
            precondition(size < w*h*4/8, "Lossy WebP is too large: \(size) bytes")
            precondition(psnr(lhs,rhs) > 35, "Lossy WebP fidelity too low: \(psnr(lhs,rhs)) dB")
            precondition(stride(from:3,to:lhs.count,by:4).allSatisfy { lhs[$0] == rhs[$0] }, "WebP alpha changed")
            if FFmpeg.isAvailable { try await FFmpeg.run(["-i",output.path,"-f","null","-"],purpose:"Independent WebP decode") }
            count += 1
        }
        // Few-colour graphics take the exact lossless path.
        let graphic = CGContext(data:nil,width:120,height:90,bitsPerComponent:8,bytesPerRow:480,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        graphic.setFillColor(CGColor(red:1,green:0.5,blue:0,alpha:1)); graphic.fill(CGRect(x:0,y:0,width:120,height:90))
        graphic.setFillColor(CGColor(red:0,green:0.3,blue:0.9,alpha:1)); graphic.fill(CGRect(x:30,y:20,width:50,height:40))
        let graphicURL = root.appendingPathComponent("graphic.webp")
        try WebPLossy.write(graphic.makeImage()!,to:graphicURL,quality:0.5)
        let graphicBack = try ImageIOBridge.load(graphicURL)
        precondition(rgba(graphic.makeImage()!) == rgba(graphicBack), "Few-colour WebP is not exact")
        count += 1
        let c = CGContext(data:nil,width:80,height:64,bitsPerComponent:8,bytesPerRow:320,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:0.2,green:0.6,blue:0.8,alpha:1)); c.fill(CGRect(x:0,y:0,width:80,height:64))
        let image=c.makeImage()!
        var fixtures: [(FileFormat,URL)] = []
        let encoders=await FFmpeg.availableEncoders()
        for format: FileFormat in [.png,.jpg,.tiff,.bmp,.webp,.heic,.avif] {
            if format == .avif && !ImageIOBridge.canEncodeNatively(.avif) && !encoders.contains("libaom-av1") && !encoders.contains("libsvtav1") { print("SKIP AVIF: encoder unavailable"); continue }
            let url=root.appendingPathComponent("fixture.\(format.fileExtension)")
            do { try await ImageIOBridge.writeAnyFormat(image,to:url,format:format); fixtures.append((format,url)) }
            catch { if format == .heic { print("BLOCKED native HEIC encoder: \(error.localizedDescription)") } else { throw error } }
        }
        for (sourceFormat,source) in fixtures {
            for (target,_) in fixtures where target != sourceFormat {
                let output=root.appendingPathComponent("\(sourceFormat)-to-\(target).\(target.fileExtension)")
                try await Engines.convert(ConversionRequest(source:source,sourceFormat:sourceFormat,target:target,destination:output,progress:{_ in}))
                let decoded=try ImageIOBridge.load(output)
                precondition(decoded.width==80 && decoded.height==64)
                count += 1
                print("PASS \(sourceFormat) -> \(target)")
            }
        }
        if let path = ProcessInfo.processInfo.environment["OT_TEST_HEIC"] {
            let input = URL(fileURLWithPath: path), output = root.appendingPathComponent("actual-heic.webp")
            let original = try ImageIOBridge.load(input)
            try await Engines.convert(ConversionRequest(source:input,sourceFormat:.heic,target:.webp,destination:output,progress:{_ in}))
            let decoded=try ImageIOBridge.load(output)
            precondition(decoded.width == original.width && decoded.height == original.height)
            let lhs=rgba(original), rhs=rgba(decoded)
            precondition(ImageIOBridge.canEncodeNatively(.webp) || psnr(lhs,rhs) > 35)
            count += 1
            print("PASS user HEIC -> WebP, dimensions and \(String(format: "%.1f", psnr(lhs,rhs))) dB PSNR")
        }
        precondition(FFmpeg.summarize("Unknown encoder 'libwebp'\nError opening output files: Encoder not found").contains("Unknown encoder"))
        print("IMAGE CONVERSION RESULT: \(count) passed")
    }
}
