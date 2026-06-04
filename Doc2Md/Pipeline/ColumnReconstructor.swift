import Foundation
import Vision

struct TextBlock {
    let text: String
    let boundingBox: CGRect  // Vision coordinates: origin at bottom-left, normalized 0-1
    let confidence: Float
}

struct ColumnReconstructor {

    /// Reconstruct text from observations with column awareness
    /// - Parameters:
    ///   - observations: VNRecognizedTextObservation array from Vision
    ///   - forceColumns: if true, always try to detect columns (for cover pages)
    /// - Returns: reconstructed text string
    static func reconstruct(
        observations: [VNRecognizedTextObservation],
        forceColumns: Bool = false
    ) -> String {
        // Convert to TextBlocks
        let blocks = observations.compactMap { obs -> TextBlock? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextBlock(
                text: candidate.string,
                boundingBox: obs.boundingBox,
                confidence: candidate.confidence
            )
        }

        guard !blocks.isEmpty else { return "" }

        // Detect number of columns
        let columns = detectColumns(blocks: blocks)

        if columns.count <= 1 {
            return simpleSort(blocks: blocks)
        }

        // Safety check (v2): a real multi-column page has columns of
        // comparable size. If one column dominates (>80% of blocks) or
        // we somehow detected >4 columns, the detection is probably a
        // false positive (e.g. an inset graphic or a sidebar element
        // creating an artificial X gap). Fall back to simple sort.
        //
        // forceColumns: true overrides this check (used for cover pages
        // where we know multi-column layout is likely).
        if !forceColumns {
            let total = blocks.count
            let largest = columns.map(\.count).max() ?? 0
            if columns.count > 4 || Double(largest) / Double(total) > 0.80 {
                return simpleSort(blocks: blocks)
            }
        }

        // Multi-column: read each column top-to-bottom, then join columns
        return multiColumnSort(columns: columns)
    }

    // MARK: - Column Detection

    /// Detect columns by clustering X positions of text blocks.
    /// Uses gap-based clustering: sort blocks by X center, find large gaps (>15% of page width).
    private static func detectColumns(blocks: [TextBlock]) -> [[TextBlock]] {
        // 1. Compute X-center for each block
        struct IndexedCenter {
            let index: Int
            let xCenter: CGFloat
        }

        let centers = blocks.enumerated().map { i, block in
            IndexedCenter(index: i, xCenter: block.boundingBox.midX)
        }

        // 2. Sort by X-center
        let sorted = centers.sorted { $0.xCenter < $1.xCenter }

        // 3. Find column boundaries: gaps > 15% of page width
        //    Page width in normalized coordinates is 1.0
        let gapThreshold: CGFloat = 0.15
        var boundaries: [Int] = [0]  // start indices into `sorted`

        for i in 1..<sorted.count {
            let gap = sorted[i].xCenter - sorted[i - 1].xCenter
            if gap > gapThreshold {
                boundaries.append(i)
            }
        }

        // 4. If only one column detected, return single group
        if boundaries.count <= 1 {
            return [blocks]
        }

        // 5. Group blocks into columns based on boundaries
        var columns: [[TextBlock]] = []
        for b in 0..<boundaries.count {
            let start = boundaries[b]
            let end = (b + 1 < boundaries.count) ? boundaries[b + 1] : sorted.count
            let columnBlocks = (start..<end).map { blocks[sorted[$0].index] }
            columns.append(columnBlocks)
        }

        return columns
    }

    // MARK: - Simple Sort

    /// Simple sort: top to bottom (descending Y since Vision Y=0 is bottom),
    /// left to right for blocks on the same line.
    private static func simpleSort(blocks: [TextBlock]) -> String {
        let lines = groupIntoLines(blocks: blocks)

        // Sort lines top-to-bottom: higher Y means higher on page in Vision coords
        let sortedLines = lines.sorted { lineA, lineB in
            let yA = lineA.map(\.boundingBox.midY).reduce(0, +) / CGFloat(lineA.count)
            let yB = lineB.map(\.boundingBox.midY).reduce(0, +) / CGFloat(lineB.count)
            return yA > yB  // descending: top of page first
        }

        // Within each line, sort left to right
        let outputLines = sortedLines.map { line in
            line.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
                .map(\.text)
                .joined(separator: " ")
        }

        return outputLines.joined(separator: "\n")
    }

    // MARK: - Multi-Column Sort

    /// Multi-column sort: read each column top-to-bottom, join columns with separator.
    private static func multiColumnSort(columns: [[TextBlock]]) -> String {
        // Sort columns left-to-right by average X position
        let sortedColumns = columns.sorted { colA, colB in
            let avgA = colA.map(\.boundingBox.midX).reduce(0, +) / CGFloat(max(colA.count, 1))
            let avgB = colB.map(\.boundingBox.midX).reduce(0, +) / CGFloat(max(colB.count, 1))
            return avgA < avgB
        }

        let columnTexts = sortedColumns.map { columnBlocks -> String in
            let lines = groupIntoLines(blocks: columnBlocks)

            // Sort lines top-to-bottom (descending Y in Vision coords)
            let sortedLines = lines.sorted { lineA, lineB in
                let yA = lineA.map(\.boundingBox.midY).reduce(0, +) / CGFloat(lineA.count)
                let yB = lineB.map(\.boundingBox.midY).reduce(0, +) / CGFloat(lineB.count)
                return yA > yB
            }

            // Within each line, sort left to right
            let outputLines = sortedLines.map { line in
                line.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
                    .map(\.text)
                    .joined(separator: " ")
            }

            return outputLines.joined(separator: "\n")
        }

        return columnTexts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Line Grouping

    /// Group blocks into lines based on Y proximity.
    /// Two blocks are on the same line if their Y-centers are within 0.8% of each other
    /// (in normalized Vision coordinates).
    private static func groupIntoLines(blocks: [TextBlock]) -> [[TextBlock]] {
        guard !blocks.isEmpty else { return [] }

        let yThreshold: CGFloat = 0.008  // 0.8% of page height

        // Sort blocks by Y descending (top of page first in Vision coords)
        let sorted = blocks.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var lines: [[TextBlock]] = []
        var currentLine: [TextBlock] = [sorted[0]]
        var currentLineY = sorted[0].boundingBox.midY

        for i in 1..<sorted.count {
            let block = sorted[i]
            if abs(block.boundingBox.midY - currentLineY) <= yThreshold {
                // Same line
                currentLine.append(block)
            } else {
                // New line
                lines.append(currentLine)
                currentLine = [block]
                currentLineY = block.boundingBox.midY
            }
        }
        lines.append(currentLine)

        return lines
    }
}
