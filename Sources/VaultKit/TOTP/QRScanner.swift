import CoreImage
import Foundation
import ImageIO
import Vision

/// Reads 2FA setup QR codes (`otpauth://…`) out of an image: a screenshot, a saved file or a pasted picture.
public enum QRScanner {
    public enum Outcome: Equatable, Sendable {
        /// The `otpauth://` (or `steam://`) link inside the QR code.
        case key(String)
        /// No QR code was found in the image.
        case noQR
        /// A QR code was found, but it is not a 2FA setup code.
        case notAuthenticator
        /// Google Authenticator's bulk "export accounts" code, which VaultBar does not read.
        case migrationExport
    }

    /// Text of every QR code in the image.
    public static func payloads(in image: CGImage) -> [String] {
        let viaVision = vision(image)
        return viaVision.isEmpty ? coreImage(image) : viaVision
    }

    public static func outcome(in image: CGImage) -> Outcome {
        classify(payloads(in: image))
    }

    public static func classify(_ payloads: [String]) -> Outcome {
        if payloads.isEmpty { return .noQR }
        for text in payloads {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            if (lower.hasPrefix("otpauth://") || lower.hasPrefix("steam://")), TOTP(parsing: value) != nil { return .key(value) }
        }
        if payloads.contains(where: { $0.lowercased().hasPrefix("otpauth-migration://") }) { return .migrationExport }
        return .notAuthenticator
    }

    /// Decodes an image file (png, jpg, heic, …). Nil when it is not a readable image.
    public static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func vision(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    private static func coreImage(_ image: CGImage) -> [String] {
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
