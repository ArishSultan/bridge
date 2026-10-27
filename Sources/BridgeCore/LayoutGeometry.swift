import CoreGraphics
import Foundation

/// Geometry of a layout in the unit square (origin top left): pane frames, moving focus between
/// panes, and resizing or evening out splits.
extension Layout {
    /// Each pane's frame in the unit square.
    public func frames() -> [ID: CGRect] {
        geometry().panes
    }

    private func geometry() -> (panes: [ID: CGRect], splits: [ID: CGRect]) {
        var panes: [ID: CGRect] = [:]
        var splits: [ID: CGRect] = [:]
        layout(in: CGRect(x: 0, y: 0, width: 1, height: 1), panes: &panes, splits: &splits)
        return (panes, splits)
    }

    private func layout(in rect: CGRect, panes: inout [ID: CGRect], splits: inout [ID: CGRect]) {
        switch self {
        case .pane(let id, _):
            panes[id] = rect
        case .split(let id, let axis, let ratio, let first, let second):
            splits[id] = rect
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
            first.layout(in: a, panes: &panes, splits: &splits)
            second.layout(in: b, panes: &panes, splits: &splits)
        }
    }

    public static func divide(_ rect: CGRect, axis: SplitAxis, ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let width = rect.width * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .vertical:
            let height = rect.height * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
    }

    /// The splits from the root down to `pane`, as (id, axis, ratio).
    private func path(to pane: ID) -> [(id: ID, axis: SplitAxis, ratio: Double)]? {
        switch self {
        case .pane(let id, _):
            return id == pane ? [] : nil
        case .split(let id, let axis, let ratio, let first, let second):
            guard let rest = first.path(to: pane) ?? second.path(to: pane) else { return nil }
            return [(id, axis, ratio)] + rest
        }
    }

    /// Move the divider nearest to `pane` that runs across `direction` by `points`, in a layout
    /// drawn at `size`.
    public mutating func resize(_ pane: ID, toward direction: Side, points: Double, in size: CGSize) {
        guard let path = path(to: pane) else { return }
        let splits = geometry().splits
        for split in path.reversed() where split.axis == direction.axis {
            guard let frame = splits[split.id] else { return }
            let extent = split.axis == .horizontal ? frame.width * size.width : frame.height * size.height
            guard extent > 0 else { return }
            let sign: Double = direction == .right || direction == .bottom ? 1 : -1
            setRatio(split.ratio + sign * points / extent, of: split.id)
            return
        }
    }

    /// How many panes sit side by side along `axis` (1 for anything split the other way).
    private func count(along axis: SplitAxis) -> Int {
        guard case .split(_, let splitAxis, _, let first, let second) = self, splitAxis == axis else { return 1 }
        return first.count(along: axis) + second.count(along: axis)
    }

    /// Give every pane along each axis the same share of the space.
    public func equalized() -> Layout {
        guard case .split(let id, let axis, _, let first, let second) = self else { return self }
        let a = Double(first.count(along: axis))
        let b = Double(second.count(along: axis))
        return .split(id: id, axis: axis, ratio: a / (a + b), first: first.equalized(), second: second.equalized())
    }

    public enum Focus: Sendable {
        case previous, next, up, down, left, right
    }

    /// The pane to move focus to from `pane`, or nil if there is none that way.
    public func neighbor(of pane: ID, _ direction: Focus) -> ID? {
        let order = panes
        guard let index = order.firstIndex(of: pane) else { return nil }
        switch direction {
        case .previous:
            return order.count > 1 ? order[(index - 1 + order.count) % order.count] : nil
        case .next:
            return order.count > 1 ? order[(index + 1) % order.count] : nil
        case .up, .down, .left, .right:
            let frames = frames()
            guard let from = frames[pane] else { return nil }
            let epsilon = 1e-9
            // Panes entirely on that side that overlap on the other axis: the closest wins, then
            // the one overlapping most, then the first in reading order.
            let candidates = frames.compactMap { id, frame -> (ID, Double, Double)? in
                guard id != pane else { return nil }
                let distance: Double
                let overlap: Double
                switch direction {
                case .left:
                    guard frame.maxX <= from.minX + epsilon else { return nil }
                    distance = from.minX - frame.maxX
                    overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
                case .right:
                    guard frame.minX >= from.maxX - epsilon else { return nil }
                    distance = frame.minX - from.maxX
                    overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
                case .up:
                    guard frame.maxY <= from.minY + epsilon else { return nil }
                    distance = from.minY - frame.maxY
                    overlap = min(frame.maxX, from.maxX) - max(frame.minX, from.minX)
                default:
                    guard frame.minY >= from.maxY - epsilon else { return nil }
                    distance = frame.minY - from.maxY
                    overlap = min(frame.maxX, from.maxX) - max(frame.minX, from.minX)
                }
                return overlap > epsilon ? (id, distance, overlap) : nil
            }
            return candidates.min { a, b in
                if abs(a.1 - b.1) > epsilon { return a.1 < b.1 }
                if abs(a.2 - b.2) > epsilon { return a.2 > b.2 }
                return order.firstIndex(of: a.0)! < order.firstIndex(of: b.0)!
            }?.0
        }
    }
}
