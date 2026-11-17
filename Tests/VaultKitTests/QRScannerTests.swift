import CoreImage
import XCTest
@testable import VaultKit

final class QRScannerTests: XCTestCase {
    /// A QR code picture of `text`, on a white page like a screenshot.
    private func qr(_ text: String, scale: CGFloat = 8, page: CGSize? = nil) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        var image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let page {
            let background = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: page))
            image = image.transformed(by: CGAffineTransform(translationX: 40, y: 40)).composited(over: background)
        }
        let context = CIContext()
        return try XCTUnwrap(context.createCGImage(image, from: image.extent))
    }

    func testReadsOtpauthLink() throws {
        let link = "otpauth://totp/GitHub:octo@example.test?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        XCTAssertEqual(QRScanner.outcome(in: try qr(link)), .key(link))
    }

    func testReadsQRInsideALargerScreenshot() throws {
        let link = "otpauth://totp/Acme:bob@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Acme&digits=6&period=30"
        XCTAssertEqual(QRScanner.outcome(in: try qr(link, scale: 5, page: CGSize(width: 1600, height: 1000))), .key(link))
    }

    func testOtherQRCodesAreNotAuthenticatorKeys() throws {
        XCTAssertEqual(QRScanner.outcome(in: try qr("https://example.test/login")), .notAuthenticator)
        // A bare word that happens to be valid Base32 must not be accepted either.
        XCTAssertEqual(QRScanner.outcome(in: try qr("HELLOWORLD")), .notAuthenticator)
    }

    func testGoogleAuthenticatorExportIsRecognised() {
        XCTAssertEqual(QRScanner.classify(["otpauth-migration://offline?data=abc"]), .migrationExport)
    }

    func testBlankImageHasNoQR() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(QRScanner.outcome(in: try XCTUnwrap(context.makeImage())), .noQR)
    }
}
