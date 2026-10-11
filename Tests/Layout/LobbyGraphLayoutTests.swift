import Foundation
import CoreGraphics

@main
struct LobbyGraphLayoutTests {
    static func main() {
        // Normal launch, extra banners, large window, and a compact canvas.
        let sizes = [CGSize(width: 811, height: 600),
                     CGSize(width: 811, height: 320),
                     CGSize(width: 1511, height: 900),
                     CGSize(width: 240, height: 180)]
        var checked = 0
        for size in sizes {
            for count in [1, 2, 12, 64] {
                for index in 0..<count {
                    let point = LobbyGraphLayout.position(index: index, count: count, size: size)
                    precondition(point.x >= LobbyGraphLayout.horizontalInset - 0.001)
                    precondition(point.x <= size.width - LobbyGraphLayout.horizontalInset + 0.001)
                    precondition(point.y >= LobbyGraphLayout.verticalInset - 0.001)
                    precondition(point.y <= size.height - LobbyGraphLayout.verticalInset + 0.001)
                    checked += 1
                }
            }
        }

        let large = LobbyGraphLayout.position(index: 0, count: 12, size: sizes[2])
        let small = LobbyGraphLayout.position(index: 0, count: 12, size: sizes[0])
        precondition(large.x > sizes[0].width, "Reproduce the stale-coordinate overflow")
        precondition(small.x < sizes[0].width - LobbyGraphLayout.horizontalInset)

        let collapsed = LobbyGraphLayout.position(index: 0, count: 0, size: .zero)
        precondition(collapsed == .zero, "Initial zero-sized proposals must remain finite")
        print("Lobby layout passed: \(checked) bounded node positions, resize, and zero-size proposal")
    }
}
