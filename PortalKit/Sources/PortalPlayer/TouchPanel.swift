import Foundation

/// Where the numbers panel sits: with the on-screen controls shown it is at the top centre under the row of the three
/// centre controls (never over one, in either layout); without them, top left of the safe area, moved down under the gear where it would reach it (the gear is there with or without the
/// controls). The size is the panel's measured size -> .claude/client.md § input
public enum TouchPanel {
    static let margin = 8.0, gap = 4.0

    /// A model of the size, from the lines: the app places the panel by its MEASURED size (`PlayView` passes it; the first
    /// layout is hidden until it is known), so this is only the fallback for a caller with nothing drawn (11 pt monospaced: about 6.9 pt a character, 14.4 pt a line; 20 pt and 14 pt of padding; the full
    /// level is at least 336 pt wide).
    public static func estimatedSize(lines: [String], full: Bool) -> (width: Double, height: Double) {
        let chars = Double(lines.map(\.count).max() ?? 0)
        return (max(chars * 6.9 + 20, full ? 336 : 0), Double(lines.count) * 14.4 + 14)
    }

    public static func frame(width: Double, height: Double, geometry: TouchGeometry, controlsShown: Bool) -> TouchRect {
        let s = geometry.safe
        let pad = TouchPad(geometry: geometry, layout: .flat)
        guard controlsShown else {
            // Top left; the gear stays on screen without the controls, so a panel that would reach it moves down under it.
            let corner = TouchRect(x: s.minX + margin, y: s.minY + margin, width: width, height: height)
            let gear = pad.gearFrame
            let touches = corner.minX < gear.maxX && gear.minX < corner.maxX && corner.minY < gear.maxY && gear.minY < corner.maxY
            return touches ? TouchRect(x: corner.minX, y: gear.maxY + gap, width: width, height: height) : corner
        }
        return TouchRect(x: s.midX - width / 2, y: pad.menuRowBottom + gap, width: width, height: height)
    }
}
