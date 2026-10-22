import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image conversions and Images → PDF with ImageIO and CoreGraphics.
enum ConverterImages {
    /// Decodes the first frame upright (EXIF orientation applied), scaled so
    /// the longest side is at most `maxPixelSize` (nil = full size).
    static func loadUpright(_ url: URL, maxPixelSize: Int?) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConverterError.unreadable(url.lastPathComponent)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longest = max(width, height, 1)
        let target = maxPixelSize.map { min($0, longest) } ?? longest
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConverterError.unreadable(url.lastPathComponent)
        }
        return (image, properties)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Copy of `image` composited on white (for JPEG, which has no alpha).
    static func flattened(_ image: CGImage) -> CGImage {
        guard hasAlpha(image),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, to url: URL, format: ConverterImageFormat, quality: Double, dpi: Double? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConverterError.unsupported("This Mac can't write \(format.title)")
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1) }
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        let output = format == .jpg ? flattened(image) : image
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConverterError.writeFailed(url.lastPathComponent) }
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, flattened(image),
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Image → image

    static func convert(
        _ input: URL,
        to format: ConverterImageFormat,
        maxPixelSize: Int?,
        options: ConverterOptions,
        in directory: URL
    ) throws -> ConverterOutput {
        try Task.checkCancellation()
        let (image, properties) = try loadUpright(input, maxPixelSize: maxPixelSize.map { max(16, $0) })
        let base = ConverterEngine.baseName(input)
        let name = maxPixelSize == nil ? base : "\(base)-\(max(image.width, image.height))px"
        let out = ConverterEngine.uniqueURL(in: directory, name: name, ext: format.fileExtension)
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double
        try write(image, to: out, format: format, quality: options.imageQuality, dpi: dpi)
        let from = input.pathExtension.uppercased()
        let summary = maxPixelSize == nil
            ? "\(from) → \(format.title) · \(image.width)×\(image.height)"
            : "Resized to \(image.width)×\(image.height)"
        return ConverterOutput(files: [out], summary: summary, bytesBefore: ConverterEngine.fileSize(input),
                               bytesAfter: ConverterEngine.fileSize(out))
    }

    // MARK: Images → PDF

    /// One page per image. `.fit` sizes the page to the image (at its DPI);
    /// A4/Letter centre it with a margin, landscape for wide images. JPEGs
    /// are embedded as-is; other lossy-friendly formats are encoded once as
    /// JPEG; PNG/TIFF (screenshots, alpha) stay lossless.
    static func writePDF(
        from inputs: [URL],
        pageSize: ConverterPageSize,
        to url: URL,
        progress: ConverterProgress
    ) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextCreator: "SparkV"]
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, info as CFDictionary) else {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let (image, properties) = try loadUpright(input, maxPixelSize: nil)
                let embedded = embeddable(image, input: input, properties: properties)
                let dpi = max((properties[kCGImagePropertyDPIWidth] as? Double) ?? 72, 72)
                let natural = CGSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
                var page: CGRect
                var drawRect: CGRect
                if let paper = pageSize.size {
                    let landscape = natural.width > natural.height
                    page = CGRect(origin: .zero, size: landscape ? CGSize(width: paper.height, height: paper.width) : paper)
                    let margin: CGFloat = 24
                    let available = page.insetBy(dx: margin, dy: margin)
                    let scale = min(available.width / natural.width, available.height / natural.height, 1)
                    let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                    drawRect = CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2,
                                      width: size.width, height: size.height)
                } else {
                    page = CGRect(origin: .zero, size: natural)
                    drawRect = page
                }
                context.beginPage(mediaBox: &page)
                context.interpolationQuality = .high
                context.draw(embedded, in: drawRect)
                context.endPage()
            }
            progress(Double(index + 1) / Double(inputs.count))
        }
        context.closePDF()
        closed = true
    }

    /// The image to put in the PDF: a JPEG-backed CGImage where possible so
    /// Quartz writes DCT data instead of a huge Flate bitmap.
    private static func embeddable(_ image: CGImage, input: URL, properties: [CFString: Any]) -> CGImage {
        let ext = input.pathExtension.lowercased()
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        if ["jpg", "jpeg"].contains(ext), orientation == 1,
           let provider = CGDataProvider(url: input as CFURL),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return jpeg
        }
        // Decoded thumbnails carry an alpha channel even for opaque photos,
        // so go by the file's own HasAlpha flag (absent = opaque).
        let alpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let lossless = ["png", "tif", "tiff", "gif", "bmp"].contains(ext) || alpha
        if !lossless, let data = encodeJPEG(image, quality: 0.9),
           let provider = CGDataProvider(data: data as CFData),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return jpeg
        }
        return image
    }
}
