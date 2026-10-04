import CoreGraphics
import Foundation
import Vision

/// Reads a handwritten atom label ("O", "OH", "NH₂", "Cl", …) from the letter cluster the
/// structure recognizer found. Page-level OCR misses lone letters, so each cluster is read on its
/// own: its shape (enclosed holes, width) decides the common cases (O / OH / N / NH) and Vision,
/// run on the isolated, enlarged letters, settles the rest. Unsure reads are flagged so Inky can
/// correct them from the image.
enum AtomLabelReader {
    struct Reading: Equatable, Sendable {
        /// As written, normalized ("OH", "NH2", "Cl").
        var text: String
        /// Element symbol of the atom ("O"), or "?" when unreadable.
        var element: String
        /// Hydrogens written in the label ("OH" → 1).
        var writtenHydrogens: Int
        var confident: Bool
    }

    /// Labels Inky understands as one atom, with the heavy atom and its written H's.
    static let vocabulary: [String: (element: String, hydrogens: Int)] = [
        "O": ("O", 0), "OH": ("O", 1), "HO": ("O", 1),
        "N": ("N", 0), "NH": ("N", 1), "HN": ("N", 1), "NH2": ("N", 2), "H2N": ("N", 2), "NH3": ("N", 3),
        "S": ("S", 0), "SH": ("S", 1), "HS": ("S", 1),
        "F": ("F", 0), "Cl": ("Cl", 0), "Br": ("Br", 0), "I": ("I", 0),
        "P": ("P", 0), "B": ("B", 0), "Si": ("Si", 0),
        "C": ("C", 0), "CH": ("C", 1), "CH2": ("C", 2), "H2C": ("C", 2), "CH3": ("C", 3), "H3C": ("C", 3),
        "Na": ("Na", 0), "Li": ("Li", 0), "Mg": ("Mg", 0), "H": ("H", 0),
    ]

    static func parse(_ label: String) -> Reading? {
        let cleaned = label.replacingOccurrences(of: "₂", with: "2").replacingOccurrences(of: "₃", with: "3")
            .filter { !$0.isWhitespace && $0 != "+" && $0 != "-" && $0 != "−" }
        guard let entry = vocabulary[cleaned] else { return nil }
        return Reading(text: cleaned, element: entry.element, writtenHydrogens: entry.hydrogens, confident: true)
    }

    /// Shape-only read from the ink: one hole → O (wide → OH/HO), no hole → N (wide → NH).
    static func shapeReading(bitmap: InkBitmap, box: CGRect, bondDirections: [CGFloat]) -> Reading {
        let holes = bitmap.holes(in: box, minPixels: max(4, Int(box.width * box.height * 0.01)))
        let aspect = box.width / max(1, box.height)
        if holes.count == 1 {
            if aspect < 1.45 { return Reading(text: "O", element: "O", writtenHydrogens: 0, confident: true) }
            // The O sits on the side its bond comes from (directions point from this atom to its
            // neighbours); otherwise the hole's side tells.
            let bondOnLeft = bondDirections.contains { cos($0) < -0.3 }
            let bondOnRight = bondDirections.contains { cos($0) > 0.3 }
            let text = bondOnLeft ? "OH" : bondOnRight ? "HO" : (holes[0] < 0.5 ? "OH" : "HO")
            return Reading(text: text, element: "O", writtenHydrogens: 1, confident: true)
        }
        if holes.isEmpty {
            return aspect < 1.2
                ? Reading(text: "N", element: "N", writtenHydrogens: 0, confident: false)
                : Reading(text: "NH", element: "N", writtenHydrogens: 1, confident: false)
        }
        return Reading(text: "?", element: "?", writtenHydrogens: 0, confident: false)
    }

    /// Written order follows the bond: the heavy atom is on the side its bond comes from ("OH" with
    /// the bond on the left, "HO" with it on the right), whatever OCR read.
    static func ordered(_ reading: Reading, bondDirections: [CGFloat]) -> Reading {
        guard reading.writtenHydrogens > 0, reading.element != "C" || reading.text.count > 1 else { return reading }
        let left = bondDirections.contains { cos($0) < -0.3 }, right = bondDirections.contains { cos($0) > 0.3 }
        let h = reading.writtenHydrogens > 1 ? "H\(reading.writtenHydrogens)" : "H"
        var r = reading
        // Bonds on one side decide; otherwise the usual way of writing it (heavy atom first).
        r.text = (left == right || left) ? reading.element + h : h + reading.element
        return r
    }

    /// Maps OCR candidates onto the vocabulary, forgiving the usual handwriting confusions.
    static func normalizeOCR(_ raw: String) -> String? {
        var s = ""
        for c in raw {
            switch c {
            case "0", "o", "Q", "D", "°", "•", "○", "О", "о": s.append("O")  // incl. Cyrillic О/о
            case "Н", "н", "#": s.append("H")                                 // Cyrillic Н
            case "И", "М": s.append("N")
            case "l", "|": s.append("l")
            case "₂", "z", "Z": s.append(s.isEmpty ? "Z" : "2")
            case "₃": s.append("3")
            default: if c.isLetter || c.isNumber { s.append(c) }
            }
        }
        // Element symbols keep their case ("Cl", "Br"); single letters are capitals.
        let candidates = [s, s.uppercased(), s.prefix(1).uppercased() + s.dropFirst().lowercased()]
        for c in candidates where vocabulary[c] != nil { return c }
        // Extra junk around a known label ("zOH", "HN.").
        for key in vocabulary.keys.sorted(by: { $0.count > $1.count }) where key.count >= 2 && s.uppercased().contains(key.uppercased()) {
            return key
        }
        return nil
    }

    /// Full read: shape + Vision. Vision wins when it names a label consistent with the shape.
    static func read(bitmap: InkBitmap, box: CGRect, bondDirections: [CGFloat]) async -> Reading {
        let shape = shapeReading(bitmap: bitmap, box: box, bondDirections: bondDirections)
        let ocr = await recognize(bitmap: bitmap, box: box)
        guard let text = ocr, let reading = parse(text) else { return shape }
        let holes = bitmap.holes(in: box, minPixels: max(4, Int(box.width * box.height * 0.01))).count
        // "O" needs a hole; "N", "S", "Cl", "F" have none; disagreeing reads defer to the shape.
        let needsHole = ["O", "P", "B"].contains(reading.element)
        if needsHole == (holes > 0) || !shape.confident {
            return reading
        }
        return shape
    }

    /// Vision on the isolated letters, enlarged onto a clean white tile.
    static func recognize(bitmap: InkBitmap, box: CGRect) async -> String? {
        guard let tile = tileImage(bitmap: bitmap, box: box) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            var best: String?
            for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = level
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.2
                request.customWords = Array(vocabulary.keys)
                guard (try? VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])) != nil else { continue }
                for observation in request.results ?? [] {
                    for candidate in observation.topCandidates(5) {
                        if let label = normalizeOCR(candidate.string) { best = label; break }
                    }
                    if best != nil { break }
                }
                if best != nil { break }
            }
            return best
        }.value
    }

    /// The letters' pixels, black on white, ~120 px tall with padding.
    static func tileImage(bitmap: InkBitmap, box: CGRect) -> CGImage? {
        let pad = max(box.width, box.height) * 0.3
        let src = box.insetBy(dx: -pad, dy: -pad).integral
        let scale = max(1, 120 / max(1, src.height))
        let w = Int(src.width * scale), h = Int(src.height * scale)
        guard w > 4, h > 4, w < 4000, h < 4000 else { return nil }
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let sy = Int(src.minY + CGFloat(y) / scale)
            for x in 0..<w {
                let sx = Int(src.minX + CGFloat(x) / scale)
                if bitmap[sx, sy] { gray[y * w + x] = 0 }
            }
        }
        return gray.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
