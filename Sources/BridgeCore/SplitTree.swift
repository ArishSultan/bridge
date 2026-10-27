import CoreGraphics
import Foundation

public typealias PaneID = UUID

/// The layout of a tab: a binary tree whose leaves are terminal panes and whose inner nodes split
/// their area in two, side by side or stacked.
public struct SplitTree: Equatable, Sendable {
    public private(set) var root: SplitNode

    public init(pane: PaneID) {
        root = .leaf(pane)
    }

    public init(root: SplitNode) {
        self.root = root
    }

    /// Every pane, left to right and top to bottom.
    public var panes: [PaneID] { root.panes }

    public func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }

    /// Split `pane` in two, putting `newPane` on the given side of it.
    public mutating func split(_ pane: PaneID, direction: SplitDirection, newPane: PaneID) {
        root = root.replacing(pane) {
            let new = SplitNode.leaf(newPane)
            let old = SplitNode.leaf(pane)
            let after = direction == .right || direction == .down
            return .split(Split(
                axis: direction.axis,
                ratio: 0.5,
                first: after ? old : new,
                second: after ? new : old))
        }
    }

    /// Remove `pane`; its sibling takes the space. Returns false when it was the last pane, which
    /// leaves the tree unchanged (the tab closes instead).
    @discardableResult
    public mutating func remove(_ pane: PaneID) -> Bool {
        guard let newRoot = root.removing(pane) else { return false }
        root = newRoot
        return true
    }

    /// Set the divider position of the split with this id, as a fraction of its size.
    public mutating func setRatio(_ ratio: Double, of splitID: UUID) {
        root = root.mapSplits { split in
            guard split.id == splitID else { return split }
            var split = split
            split.ratio = ratio.clamped(0.1, 0.9)
            return split
        }
    }

    /// Move the divider nearest to `pane` that runs across `direction` by `points`, in a tree
    /// laid out in `size`.
    public mutating func resize(_ pane: PaneID, direction: SplitDirection, points: Double, in size: CGSize) {
        guard let path = root.path(to: pane) else { return }
        let frames = splitFrames()
        // The nearest ancestor that splits along the direction's axis.
        for split in path.reversed() where split.axis == direction.axis {
            guard let frame = frames[split.id] else { return }
            let extent = split.axis == .horizontal ? frame.width * size.width : frame.height * size.height
            guard extent > 0 else { return }
            let delta = points / extent * (direction == .right || direction == .down ? 1 : -1)
            setRatio(split.ratio + delta, of: split.id)
            return
        }
    }

    /// Give every pane along each axis the same share of the space.
    public mutating func equalize() {
        root = root.equalized()
    }

    /// Each pane's frame in the unit square, origin top left.
    public func frames() -> [PaneID: CGRect] {
        layout().panes
    }

    func splitFrames() -> [UUID: CGRect] {
        layout().splits
    }

    private func layout() -> (panes: [PaneID: CGRect], splits: [UUID: CGRect]) {
        var panes: [PaneID: CGRect] = [:]
        var splits: [UUID: CGRect] = [:]
        root.layout(in: CGRect(x: 0, y: 0, width: 1, height: 1), panes: &panes, splits: &splits)
        return (panes, splits)
    }

    /// The pane to move focus to from `pane`, or nil if there is none that way.
    public func neighbor(of pane: PaneID, _ direction: FocusDirection) -> PaneID? {
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

            // Panes that lie entirely on that side and overlap on the other axis; the closest
            // wins, then the one that overlaps most.
            let candidates = frames.compactMap { id, frame -> (PaneID, Double, Double)? in
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
            // Remaining ties go to the pane that comes first (top, then left).
            return candidates.min { a, b in
                if abs(a.1 - b.1) > epsilon { return a.1 < b.1 }
                if abs(a.2 - b.2) > epsilon { return a.2 > b.2 }
                return order.firstIndex(of: a.0)! < order.firstIndex(of: b.0)!
            }?.0
        }
    }
}

public indirect enum SplitNode: Equatable, Sendable {
    case leaf(PaneID)
    case split(Split)

    var panes: [PaneID] {
        switch self {
        case .leaf(let id): [id]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    func replacing(_ pane: PaneID, with make: () -> SplitNode) -> SplitNode {
        switch self {
        case .leaf(let id):
            return id == pane ? make() : self
        case .split(var split):
            split.first = split.first.replacing(pane, with: make)
            split.second = split.second.replacing(pane, with: make)
            return .split(split)
        }
    }

    /// The tree without `pane`, or nil if nothing would be left.
    func removing(_ pane: PaneID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == pane ? nil : self
        case .split(var split):
            guard let first = split.first.removing(pane) else { return split.second }
            guard let second = split.second.removing(pane) else { return split.first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    func mapSplits(_ transform: (Split) -> Split) -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var split):
            split.first = split.first.mapSplits(transform)
            split.second = split.second.mapSplits(transform)
            return .split(transform(split))
        }
    }

    /// The splits from the root down to `pane`.
    func path(to pane: PaneID) -> [Split]? {
        switch self {
        case .leaf(let id):
            return id == pane ? [] : nil
        case .split(let split):
            if let rest = split.first.path(to: pane) ?? split.second.path(to: pane) {
                return [split] + rest
            }
            return nil
        }
    }

    /// How many panes sit side by side along `axis` (1 for anything split the other way).
    func count(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            guard split.axis == axis else { return 1 }
            return split.first.count(along: axis) + split.second.count(along: axis)
        }
    }

    func equalized() -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var split):
            split.first = split.first.equalized()
            split.second = split.second.equalized()
            let first = Double(split.first.count(along: split.axis))
            let second = Double(split.second.count(along: split.axis))
            split.ratio = first / (first + second)
            return .split(split)
        }
    }

    /// Record the frame of every pane and split when this node fills `rect`.
    func layout(in rect: CGRect, panes: inout [PaneID: CGRect], splits: inout [UUID: CGRect]) {
        switch self {
        case .leaf(let id):
            panes[id] = rect
        case .split(let split):
            splits[split.id] = rect
            let (first, second) = split.divide(rect)
            split.first.layout(in: first, panes: &panes, splits: &splits)
            split.second.layout(in: second, panes: &panes, splits: &splits)
        }
    }
}

public struct Split: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var axis: SplitAxis
    /// The first child's share of the space, 0.1 to 0.9.
    public var ratio: Double
    public var first: SplitNode
    public var second: SplitNode

    public init(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }

    func divide(_ rect: CGRect) -> (CGRect, CGRect) {
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
}

/// `horizontal` puts the children side by side, `vertical` stacks them.
public enum SplitAxis: Sendable {
    case horizontal, vertical
}

public enum SplitDirection: Sendable {
    case right, down, left, up

    var axis: SplitAxis {
        self == .left || self == .right ? .horizontal : .vertical
    }
}

public enum FocusDirection: Sendable {
    case previous, next, up, down, left, right
}
