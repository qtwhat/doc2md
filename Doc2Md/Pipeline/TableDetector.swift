import Foundation
import Vision
import CoreGraphics

// MARK: - Table Detector
//
// Heuristic: scan OCR observations for clusters that look like a tabular
// grid (multiple rows with consistent column X-positions). If found,
// extract those observations and re-emit them as a Markdown table.
//
// Targeted at:
//   - Medical / lab reports with rows like "AO 31mm (<38mm)" stacked in
//     2- or 4-column grids (the hospital echocardiogram report this
//     project was tested against)
//   - Scientific tables with numeric values
//
// Conservative by design: only emits a table when the grid evidence is
// strong (>= 3 rows, >= 2 columns, columns aligned within tolerance).
// Otherwise leaves the observations to flow through the regular
// reconstruction path.

enum TableDetector {

    struct DetectedTable {
        /// Indices into the original observation array that belong to the
        /// table. The caller can subtract these from the flow text.
        let observationIndices: Set<Int>
        /// Rendered Markdown table.
        let markdown: String
        /// Top Y coordinate (Vision space — higher = top of page).
        /// Used by callers to splice the table back into the document at
        /// the right place.
        let topY: CGFloat
    }

    /// Scan observations for tabular clusters. Returns zero or more
    /// detected tables. Observations are NOT modified.
    static func detect(observations: [VNRecognizedTextObservation]) -> [DetectedTable] {
        let blocks: [(idx: Int, rect: CGRect, text: String)] =
            observations.enumerated().compactMap { i, obs in
                guard let s = obs.topCandidates(1).first?.string,
                      !s.trimmingCharacters(in: .whitespaces).isEmpty
                else { return nil }
                return (i, obs.boundingBox, s)
            }
        guard blocks.count >= 6 else { return [] }    // need a few cells minimum

        // Group blocks into rows by Y proximity. Vision coords: Y in [0,1],
        // origin bottom-left. Two blocks are on the "same row" if their Y
        // centers are within rowTolerance.
        let rowTolerance: CGFloat = 0.012
        var rows: [[(idx: Int, rect: CGRect, text: String)]] = []
        let sortedByY = blocks.sorted { $0.rect.midY > $1.rect.midY }
        for b in sortedByY {
            if let lastRow = rows.last,
               let firstInRow = lastRow.first,
               abs(firstInRow.rect.midY - b.rect.midY) < rowTolerance {
                rows[rows.count - 1].append(b)
            } else {
                rows.append([b])
            }
        }

        // Sort each row left-to-right
        for i in 0..<rows.count {
            rows[i].sort { $0.rect.midX < $1.rect.midX }
        }

        // Find runs of consecutive rows with the same column count (>= 2)
        // and aligned column X-centers.
        var tables: [DetectedTable] = []
        var i = 0
        while i < rows.count {
            let cols = rows[i].count
            guard cols >= 2 else { i += 1; continue }

            // Find how many consecutive rows share this column count and
            // column alignment.
            let refCenters = rows[i].map(\.rect.midX)
            var j = i + 1
            while j < rows.count, rows[j].count == cols {
                let centers = rows[j].map(\.rect.midX)
                if !columnsAligned(refCenters, centers, tolerance: 0.04) { break }
                j += 1
            }

            // Need >= 3 rows for a credible table (header + 2 data rows,
            // or 3 data rows). Single-pair stacks are too noisy.
            let runRows = Array(rows[i..<j])
            if runRows.count >= 3 {
                let md = renderTable(runRows)
                let indices = Set(runRows.flatMap { $0.map(\.idx) })
                let topY = runRows.first?.first?.rect.maxY ?? 0
                tables.append(DetectedTable(
                    observationIndices: indices,
                    markdown: md,
                    topY: topY
                ))
                i = j
            } else {
                i += 1
            }
        }
        return tables
    }

    // MARK: - Helpers

    private static func columnsAligned(_ a: [CGFloat], _ b: [CGFloat],
                                       tolerance: CGFloat) -> Bool {
        guard a.count == b.count else { return false }
        for (ax, bx) in zip(a, b) where abs(ax - bx) > tolerance {
            return false
        }
        return true
    }

    private static func renderTable(_ rows: [[(idx: Int, rect: CGRect, text: String)]]) -> String {
        guard let cols = rows.first?.count, cols > 0 else { return "" }

        // Escape cell contents
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|")
             .replacingOccurrences(of: "\n", with: " ")
             .trimmingCharacters(in: .whitespaces)
        }

        let headerRow = rows[0].map { escape($0.text) }
        var md = "| " + headerRow.joined(separator: " | ") + " |\n"
        md += "| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |\n"
        for row in rows.dropFirst() {
            let cells = row.map { escape($0.text) }
            md += "| " + cells.joined(separator: " | ") + " |\n"
        }
        return md
    }
}
