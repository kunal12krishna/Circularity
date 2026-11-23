import CoreGraphics
import Foundation
import Vision

/// Smart crop for social (Tools → Social): the biggest frame of the chosen
/// shape that keeps what draws the eye, found with Apple's on-device
/// attention-based saliency (no permission, nothing uploaded).
public enum SmartCrop {
    /// The shapes people post in.
    public enum Shape: String, CaseIterable, Sendable, Codable {
        case square, portrait, wide, story

        /// Width ÷ height.
        public var aspect: Double {
            switch self {
            case .square: 1
            case .portrait: 4.0 / 5
            case .wide: 16.0 / 9
            case .story: 9.0 / 16
            }
        }

        public var ratio: String {
            switch self {
            case .square: "1:1"
            case .portrait: "4:5"
            case .wide: "16:9"
            case .story: "9:16"
            }
        }

        public var use: String {
            switch self {
            case .square: "Instagram, profile pictures"
            case .portrait: "Instagram portrait posts"
            case .wide: "YouTube thumbnails, X, LinkedIn"
            case .story: "Stories, Reels, TikTok, Shorts"
            }
        }
    }

    /// Where the eye goes, as a normalised rect (0…1, top-left origin): the most confident
    /// object Vision finds (objectness), else the most confident area of attention, else the middle.
    /// One subject, not the union of all of them: a union between two things can land on neither.
    static func focus(of image: CGImage) -> CGRect {
        func best(_ request: VNImageBasedRequest) -> CGRect? {
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let objects = ((request.results?.first as? VNSaliencyImageObservation)?.salientObjects ?? [])
                .filter { $0.boundingBox.width > 0.01 && $0.boundingBox.height > 0.01 }
            return objects.max { $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height).squareRoot()
                < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height).squareRoot() }?.boundingBox
        }
        guard let box = best(VNGenerateObjectnessBasedSaliencyImageRequest()) ?? best(VNGenerateAttentionBasedSaliencyImageRequest()) else {
            return CGRect(x: 1.0 / 3, y: 1.0 / 3, width: 1.0 / 3, height: 1.0 / 3)
        }
        // Vision's origin is bottom-left.
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// The crop (normalised, top-left origin) of `aspect` in an image of `size`, as big as it can be,
    /// centred on `focus` and moved, never shrunk, to stay inside the picture.
    public static func rect(size: CGSize, aspect: Double, focus: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = Double(size.width / size.height)
        // Normalised crop size: full width or full height, whichever runs out first.
        let w: Double, h: Double
        if aspect >= imageAspect { w = 1; h = imageAspect / aspect } else { h = 1; w = aspect / imageAspect }
        let cx = Double(focus.midX), cy = Double(focus.midY)
        let x = min(max(cx - w / 2, 0), 1 - w), y = min(max(cy - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// For the dialog's preview: the crop each shape would make of this picture.
    public static func preview(_ url: URL, shapes: [Shape] = Shape.allCases) -> (image: CGImage, crops: [Shape: CGRect])? {
        guard let input = try? ImageInput.open(url), let image = try? input.upright(maxPixel: 1200) else { return nil }
        let f = focus(of: image)
        let size = CGSize(width: image.width, height: image.height)
        return (image, Dictionary(uniqueKeysWithValues: shapes.map { ($0, rect(size: size, aspect: $0.aspect, focus: f)) }))
    }

    /// The crop for one picture (saliency on a small copy; the crop itself is full resolution).
    static func rect(for input: ImageInput, shape: Shape) throws -> CGRect {
        let small = try input.upright(maxPixel: 1200)
        return rect(size: CGSize(width: small.width, height: small.height), aspect: shape.aspect, focus: focus(of: small))
    }
}
