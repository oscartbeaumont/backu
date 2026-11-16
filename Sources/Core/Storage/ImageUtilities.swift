import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ImageUtilities {
    static func jpegData(from image: PlatformImage, quality: CGFloat = 0.82, maxPixel: Int? = nil) -> Data? {
        #if canImport(UIKit)
        let source = maxPixel.map { resized(image, maxPixel: $0) } ?? image
        return source.jpegData(compressionQuality: quality)
        #elseif canImport(AppKit)
        guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if let maxPixel {
            cgImage = resize(cgImage, maxPixel: maxPixel) ?? cgImage
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    #if canImport(UIKit)
    static func resized(_ image: UIImage, maxPixel: Int) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > CGFloat(maxPixel) else { return image }
        let scale = CGFloat(maxPixel) / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif

    static func resize(_ cgImage: CGImage, maxPixel: Int) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let largest = max(width, height)
        guard largest > maxPixel else { return cgImage }
        let scale = CGFloat(maxPixel) / CGFloat(largest)
        let newWidth = max(1, Int(CGFloat(width) * scale))
        let newHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    static func platformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    static func pngData(from image: PlatformImage) -> Data? {
        #if canImport(UIKit)
        return image.pngData()
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        #endif
    }
}
