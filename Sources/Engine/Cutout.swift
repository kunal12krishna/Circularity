import CoreImage
import Foundation
import Vision

/// Background removal with Apple's Vision subject lifting (on the Mac, no
/// network): the foreground instances are kept, everything else becomes
/// transparent, and the result is a PNG at the original size.
public enum Cutout {
    /// Whether this Mac can cut out subjects (macOS 14 or later).
    public static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ input: ImageInput, policy: OutputPolicy, output: URL) throws {
        let image = try input.upright()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw JobError.toolFailed("subject detection failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw JobError.toolFailed("no clear subject found in \(input.url.lastPathComponent)")
        }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        } catch {
            throw JobError.toolFailed("couldn't cut out the subject: \(error.localizedDescription)")
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        // Always RGB: gray, CMYK or palette pictures can't be an RGBA8 bitmap in their own space.
        let rgb = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cut = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: rgb) else {
            throw JobError.encodeFailed("the cut-out image")
        }
        try ImageOps.write(cut, as: .png, quality: 1, properties: input.outputProperties(policy: policy.metadata), to: output)
    }
}
