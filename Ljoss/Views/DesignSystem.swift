import SwiftUI

/// Sizing constants.
///
/// The brief is that nothing may be too small to hit accurately with a
/// fingertip. Apple's floor is 44pt; every interactive element here is at or
/// above that, and the things you touch most during a drag are far larger.
enum Metrics {
    /// A node tile in the chain. Deliberately large: this is the primary drag handle.
    static let nodeWidth: CGFloat = 148
    static let nodeHeight: CGFloat = 104
    /// Input and output caps are a little narrower — they are never dragged.
    static let ioWidth: CGFloat = 108

    /// Horizontal gap between nodes, where the connector line shows through.
    static let nodeSpacing: CGFloat = 14
    /// Vertical gap between parallel lanes.
    static let laneSpacing: CGFloat = 12

    /// Stroke weight of the signal wire.
    static let wireThickness: CGFloat = 3
    /// Vertical gap between the rows of a wrapped chain. The return wire runs
    /// back across the middle of it, so it needs room either side.
    static let wrapRowSpacing: CGFloat = 32
    /// Inset of a chain's tiles from the edges of its row.
    static let canvasPadding: CGFloat = 16

    /// A palette tile in the tray.
    static let paletteItemWidth: CGFloat = 132
    static let paletteItemHeight: CGFloat = 86

    /// Every tappable control clears this.
    static let minTouchTarget: CGFloat = 48

    static let nodeCorner: CGFloat = 18

    /// Distance from a canvas edge that starts auto-scrolling during a drag.
    static let autoScrollZone: CGFloat = 78
    /// Peak auto-scroll speed, points per second.
    static let autoScrollMaxSpeed: CGFloat = 900

    /// How far a pointer must travel before a drag starts on macOS, where a
    /// drag is distinguished by movement rather than by a hold. Below this a
    /// press stays a click, so tap-to-select still works.
    static let pointerDragThreshold: CGFloat = 8
    /// Long-press duration that lifts a node out of the scrolling chain on iOS,
    /// where a finger pan is also how you scroll.
    static let liftDuration: Double = 0.18

    static let trayHeightCompact: CGFloat = 216
    static let trayHeightRegular: CGFloat = 232
}

enum Anim {
    /// Used for the gap opening and closing. Snappy enough to feel like the
    /// layout is tracking the finger, damped enough not to wobble.
    static let reflow: Animation = .snappy(duration: 0.24, extraBounce: 0.04)
    /// Settling a dropped node into its slot.
    static let settle: Animation = .spring(response: 0.32, dampingFraction: 0.78)
    /// Picking a node up / putting it down.
    static let lift: Animation = .spring(response: 0.26, dampingFraction: 0.7)
}

// MARK: - Category colour

extension ComponentCategory {
    /// A vivid accent that reads correctly on both light and dark backgrounds.
    ///
    /// Tiles use a low-opacity tint of this for their fill and the full-strength
    /// colour for icon and stroke, which keeps one value working in both
    /// appearances without a dynamic colour provider or an asset catalogue.
    var accent: Color {
        switch self {
        case .amp:        Color(red: 0.95, green: 0.52, blue: 0.15)
        case .cab:        Color(red: 0.76, green: 0.56, blue: 0.34)
        case .drive:      Color(red: 0.91, green: 0.30, blue: 0.27)
        case .dynamics:   Color(red: 0.18, green: 0.70, blue: 0.64)
        case .eq:         Color(red: 0.36, green: 0.45, blue: 0.90)
        case .modulation: Color(red: 0.63, green: 0.39, blue: 0.92)
        case .delay:      Color(red: 0.24, green: 0.60, blue: 0.94)
        case .reverb:     Color(red: 0.20, green: 0.74, blue: 0.86)
        case .pitch:      Color(red: 0.93, green: 0.40, blue: 0.66)
        case .filter:     Color(red: 0.36, green: 0.76, blue: 0.36)
        case .vocal:      Color(red: 0.96, green: 0.72, blue: 0.20)
        case .utility:    Color(red: 0.55, green: 0.58, blue: 0.64)
        }
    }

    var symbol: String {
        switch self {
        case .amp: "amplifier"
        case .cab: "hifispeaker.2"
        case .drive: "flame"
        case .dynamics: "waveform.path.ecg"
        case .eq: "slider.vertical.3"
        case .modulation: "water.waves"
        case .delay: "timer"
        case .reverb: "aqi.medium"
        case .pitch: "tuningfork"
        case .filter: "camera.filters"
        case .vocal: "music.mic"
        case .utility: "wrench.and.screwdriver"
        }
    }
}
