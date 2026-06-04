import Foundation
import ImageIO
import CoreGraphics

// MARK: - Metadata Extractor
//
// Pulls EXIF / TIFF / GPS / IPTC metadata from images via CGImageSource and
// formats it as a small Markdown table block. Designed for archival use —
// even if OCR finds no text, the image is at least documented by capture
// date, camera, dimensions, and GPS (if present).
//
// We mirror the subset that Microsoft markitdown extracts via exiftool, so
// downstream LLM pipelines that have learned that convention will work.

enum MetadataExtractor {

    /// Extract a flat key→value dict of human-readable image metadata. Empty
    /// dict means either the file isn't a recognized image, or it has no
    /// useful metadata (very common for screenshots and rendered images).
    static func extractImageMetadata(url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }

        var out: [(String, String)] = []

        // Image dimensions (always available)
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            out.append(("ImageSize", "\(w) × \(h)"))
        }

        // TIFF dict — Artist, Make, Model
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let v = tiff[kCGImagePropertyTIFFMake] as? String { out.append(("Make", v)) }
            if let v = tiff[kCGImagePropertyTIFFModel] as? String { out.append(("Model", v)) }
            if let v = tiff[kCGImagePropertyTIFFArtist] as? String { out.append(("Artist", v)) }
            if let v = tiff[kCGImagePropertyTIFFCopyright] as? String { out.append(("Copyright", v)) }
            if let v = tiff[kCGImagePropertyTIFFSoftware] as? String { out.append(("Software", v)) }
        }

        // EXIF dict — DateTimeOriginal, lens info
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let v = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                out.append(("DateTimeOriginal", v))
            }
            if let v = exif[kCGImagePropertyExifLensModel] as? String {
                out.append(("LensModel", v))
            }
            if let f = exif[kCGImagePropertyExifFocalLength] as? Double {
                out.append(("FocalLength", String(format: "%.1f mm", f)))
            }
            if let n = exif[kCGImagePropertyExifFNumber] as? Double {
                out.append(("Aperture", String(format: "f/%.1f", n)))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                out.append(("ISO", "\(iso)"))
            }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                let display = t < 1 ? "1/\(Int(1.0 / t))s" : String(format: "%.1fs", t)
                out.append(("ExposureTime", display))
            }
        }

        // GPS dict — coordinates and altitude
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                out.append(("GPSPosition",
                            String(format: "%.5f°%@, %.5f°%@", lat, latRef, lon, lonRef)))
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                out.append(("GPSAltitude", String(format: "%.0f m", alt)))
            }
        }

        // IPTC — title / description / keywords (rare in phone photos,
        // common in stock images and DAM exports).
        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let v = iptc[kCGImagePropertyIPTCObjectName] as? String {
                out.append(("Title", v))
            }
            if let v = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String {
                out.append(("Description", v))
            }
            if let kw = iptc[kCGImagePropertyIPTCKeywords] as? [String], !kw.isEmpty {
                out.append(("Keywords", kw.joined(separator: ", ")))
            }
        }

        return out
    }

    /// Render a key→value list as a two-column Markdown table.
    static func renderAsMarkdownTable(_ items: [(String, String)]) -> String {
        guard !items.isEmpty else { return "" }
        var s = "| Property | Value |\n| --- | --- |\n"
        for (k, v) in items {
            // Escape pipes inside values to avoid breaking the table layout.
            let safe = v.replacingOccurrences(of: "|", with: "\\|")
            s += "| \(k) | \(safe) |\n"
        }
        return s
    }
}
