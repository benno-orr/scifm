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
    /// Ordered timeline: leading text sections (Abstract, Introduction) modelled
    /// as panels with `figureNumber == 0` and no image, followed by figure panels.
    let panels: [FigurePanel]
}

extension FigurePanel {
    /// A non-figure section (Abstract / Introduction): narrated text, no image.
    var isTextSection: Bool { figureNumber == 0 }

    /// Identifies the section a panel belongs to, for the section indicator and
    /// section-level skipping. Text sections key on their title; figure panels on
    /// their figure number (so panels a, b, c… share one "Figure N" section).
    var sectionKey: String { isTextSection ? figureTitle : "fig\(figureNumber)" }

    /// Human-readable section name shown in the indicator.
    var sectionTitle: String { isTextSection ? figureTitle : "Figure \(figureNumber)" }
}
