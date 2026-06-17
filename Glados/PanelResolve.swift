import Foundation
import UIKit

/// A small downsampled RGB grid of an image, for cheap mean-color sampling over
/// image-space rectangles (used to resolve panel-box overlaps by content).
struct ColorGrid {
    let w: Int
    let h: Int
    private let rgb: [Float]          // w*h*3, 0…1, row 0 = image top
    let imageSize: CGSize

    init?(_ image: UIImage, maxDim: Int = 240) {
        guard let cg = image.cgImage, image.size.width > 0, image.size.height > 0 else { return nil }
        let aspect = CGFloat(cg.width) / CGFloat(max(1, cg.height))
        let gw = aspect >= 1 ? maxDim : max(1, Int((CGFloat(maxDim) * aspect).rounded()))
        let gh = aspect >= 1 ? max(1, Int((CGFloat(maxDim) / aspect).rounded())) : maxDim

        var data = [UInt8](repeating: 0, count: gw * gh * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: gw, height: gh, bitsPerComponent: 8,
                                  bytesPerRow: gw * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw flipped so buffer row 0 is the image's top.
        ctx.translateBy(x: 0, y: CGFloat(gh))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gw, height: gh))

        var f = [Float](repeating: 0, count: gw * gh * 3)
        for i in 0..<(gw * gh) {
            f[i * 3] = Float(data[i * 4]) / 255
            f[i * 3 + 1] = Float(data[i * 4 + 1]) / 255
            f[i * 3 + 2] = Float(data[i * 4 + 2]) / 255
        }
        w = gw; h = gh; rgb = f; imageSize = image.size
    }

    /// Mean color over an image-space rect (top-left origin). White if empty.
    func mean(_ rect: CGRect) -> (Float, Float, Float) {
        let sx = CGFloat(w) / imageSize.width, sy = CGFloat(h) / imageSize.height
        let x0 = max(0, Int((rect.minX * sx).rounded(.down)))
        let x1 = min(w, max(x0 + 1, Int((rect.maxX * sx).rounded(.up))))
        let y0 = max(0, Int((rect.minY * sy).rounded(.down)))
        let y1 = min(h, max(y0 + 1, Int((rect.maxY * sy).rounded(.up))))
        guard x1 > x0, y1 > y0 else { return (1, 1, 1) }
        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
        for yy in y0..<y1 {
            for xx in x0..<x1 {
                let i = (yy * w + xx) * 3
                r += rgb[i]; g += rgb[i + 1]; b += rgb[i + 2]; n += 1
            }
        }
        return (r / n, g / n, b / n)
    }
}

private func colorDist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
    let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
    return dr * dr + dg * dg + db * db
}

/// Resolves overlaps between panel rects: for each significantly-overlapping
/// pair, splits the shared region at the line where the content changes from one
/// panel to the other (so the overlap is assigned to the panel it resembles),
/// trimming both rects to meet there.
func resolvePanelOverlaps(_ input: [CGRect], grid: ColorGrid) -> [CGRect] {
    var rects = input
    let n = rects.count
    guard n > 1 else { return rects }

    for i in 0..<(n - 1) {
        for j in (i + 1)..<n {
            let ov = rects[i].intersection(rects[j])
            guard !ov.isNull, ov.width > 1, ov.height > 1 else { continue }
            let minArea = min(rects[i].width * rects[i].height, rects[j].width * rects[j].height)
            guard minArea > 0, ov.width * ov.height > minArea * 0.03 else { continue }

            if ov.height >= ov.width {
                // Side by side → vertical split.
                let left = rects[i].minX <= rects[j].minX ? i : j
                let right = left == i ? j : i
                let s = verticalSplit(rects[left], rects[right], ov: ov, grid: grid)
                let rMaxX = rects[right].maxX
                rects[left].size.width = max(1, s - rects[left].minX)
                rects[right].origin.x = s
                rects[right].size.width = max(1, rMaxX - s)
            } else {
                // Stacked → horizontal split.
                let top = rects[i].minY <= rects[j].minY ? i : j
                let bottom = top == i ? j : i
                let s = horizontalSplit(rects[top], rects[bottom], ov: ov, grid: grid)
                let bMaxY = rects[bottom].maxY
                rects[top].size.height = max(1, s - rects[top].minY)
                rects[bottom].origin.y = s
                rects[bottom].size.height = max(1, bMaxY - s)
            }
        }
    }
    return rects
}

/// The x within the overlap where columns stop resembling the left panel and
/// start resembling the right one.
private func verticalSplit(_ left: CGRect, _ right: CGRect, ov: CGRect, grid: ColorGrid) -> CGFloat {
    let exclL = ov.minX - left.minX
    let exclR = right.maxX - ov.maxX
    let refL = exclL > 2 ? grid.mean(CGRect(x: left.minX, y: ov.minY, width: exclL, height: ov.height))
                         : grid.mean(CGRect(x: ov.minX, y: ov.minY, width: ov.width * 0.2, height: ov.height))
    let refR = exclR > 2 ? grid.mean(CGRect(x: ov.maxX, y: ov.minY, width: exclR, height: ov.height))
                         : grid.mean(CGRect(x: ov.maxX - ov.width * 0.2, y: ov.minY, width: ov.width * 0.2, height: ov.height))

    let step = max(1, ov.width / 48)
    var x = ov.minX
    while x < ov.maxX {
        let m = grid.mean(CGRect(x: x, y: ov.minY, width: step, height: ov.height))
        if colorDist(m, refR) < colorDist(m, refL) { return x }
        x += step
    }
    return ov.maxX
}

/// The y within the overlap where rows stop resembling the top panel and start
/// resembling the bottom one.
private func horizontalSplit(_ top: CGRect, _ bottom: CGRect, ov: CGRect, grid: ColorGrid) -> CGFloat {
    let exclT = ov.minY - top.minY
    let exclB = bottom.maxY - ov.maxY
    let refT = exclT > 2 ? grid.mean(CGRect(x: ov.minX, y: top.minY, width: ov.width, height: exclT))
                         : grid.mean(CGRect(x: ov.minX, y: ov.minY, width: ov.width, height: ov.height * 0.2))
    let refB = exclB > 2 ? grid.mean(CGRect(x: ov.minX, y: ov.maxY, width: ov.width, height: exclB))
                         : grid.mean(CGRect(x: ov.minX, y: ov.maxY - ov.height * 0.2, width: ov.width, height: ov.height * 0.2))

    let step = max(1, ov.height / 48)
    var y = ov.minY
    while y < ov.maxY {
        let m = grid.mean(CGRect(x: ov.minX, y: y, width: ov.width, height: step))
        if colorDist(m, refB) < colorDist(m, refT) { return y }
        y += step
    }
    return ov.maxY
}
