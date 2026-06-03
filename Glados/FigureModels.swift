import Foundation

struct FigurePanel {
    let figureNumber: Int
    let figureTitle: String
    let label: String           // "A", "B", … or "" for single-panel figures
    let legendText: String
    let textReferences: [String]
    let imageURL: URL?
}

struct PanelTimestamp {
    let panelIndex: Int
    let figureNumber: Int
    let panelLabel: String
    let startTime: TimeInterval
}

struct ProcessedFigures {
    let title: String
    let panels: [FigurePanel]
}
