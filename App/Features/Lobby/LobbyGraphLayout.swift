import Foundation

enum LobbyGraphLayout {
    // Leave room for the 100-point labels, node halos, and hover scale.
    static let horizontalInset: CGFloat = 72
    static let verticalInset: CGFloat = 60

    static func position(index: Int, count: Int, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(0, min(min(size.width, size.height) * 0.34,
                                size.width / 2 - horizontalInset,
                                size.height / 2 - verticalInset))
        let angle = Double(index) / Double(max(1, count)) * 2 * .pi
        return CGPoint(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius)
    }
}
