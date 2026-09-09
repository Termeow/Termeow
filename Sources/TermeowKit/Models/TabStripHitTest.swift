import Foundation
import CoreGraphics

public enum TabStripHitTest {
    public static func tab(at point: CGPoint, order: [UUID], frames: [UUID: CGRect]) -> UUID? {
        order.first { frames[$0]?.contains(point) == true }
    }

    /// Use the half of the target under the pointer, excluding the source from insertion order.
    public static func insertion(at x: CGFloat, order: [UUID], frames: [UUID: CGRect], excluding source: UUID) -> (before: UUID?, markerX: CGFloat) {
        let candidates = order.filter { $0 != source }
        for id in candidates {
            if let rect = frames[id], x < rect.midX { return (id, rect.minX - 2) }
        }
        return (nil, candidates.last.flatMap { frames[$0]?.maxX }.map { $0 + 2 } ?? 4)
    }
}
