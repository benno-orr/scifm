import Foundation
import PDFKit
import UIKit

/// Pulls panel-label letters and their exact positions from a PDF's text layer
/// (no OCR). Figure panel labels in papers are real selectable text, so this is
/// far more reliable than reading them off a rasterized figure image.
enum PDFLetterExtractor {
    /// Renders one page to an image and returns the standalone single letters
    /// (a–h, the usual panel labels) with pixel rects in that image's space
    /// (top-left origin). The page and the letter rects are produced from the
    /// SAME affine transform, so the overlay always lines up with the render.
    static func page(_ doc: PDFDocument, index: Int, scale: CGFloat = 2.0)
        -> (image: UIImage, boxes: [LabelBox])? {
        guard let page = doc.page(at: index), let ref = page.pageRef else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let pxSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // Maps PDF page space → a bottom-left box of pxSize (handles crop-box
        // offset, rotation, and scale in one transform).
        let t = ref.getDrawingTransform(.cropBox,
                                        rect: CGRect(origin: .zero, size: pxSize),
                                        rotate: 0, preserveAspectRatio: true)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1            // 1pt == 1px, so image.size == the space we map in
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pxSize, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pxSize))
            cg.translateBy(x: 0, y: pxSize.height)   // flip into PDF orientation
            cg.scaleBy(x: 1, y: -1)
            cg.concatenate(t)
            cg.drawPDFPage(ref)
        }

        var boxes: [LabelBox] = []
        if let text = page.string, page.numberOfCharacters > 0 {
            let chars = Array(text)
            let n = min(chars.count, page.numberOfCharacters)
            for i in 0..<n {
                let ch = chars[i]
                guard ch.isLetter else { continue }
                let lower = Character(ch.lowercased())
                guard lower >= "a", lower <= "h" else { continue }
                // Standalone: not part of a longer word/number.
                let prev: Character = i > 0 ? chars[i - 1] : " "
                let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
                guard !prev.isLetter, !prev.isNumber, !next.isLetter, !next.isNumber else { continue }

                let cb = page.characterBounds(at: i)
                guard cb.width > 0, cb.height > 0 else { continue }
                // Same transform as the render, then flip Y to the image's top-left.
                let m = cb.applying(t)
                let rect = CGRect(x: m.minX, y: pxSize.height - m.maxY,
                                  width: m.width, height: m.height)
                boxes.append(LabelBox(char: lower, rect: rect))
            }
        }
        return (image, boxes)
    }
}
