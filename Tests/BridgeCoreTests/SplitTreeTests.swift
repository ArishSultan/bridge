import CoreGraphics
import Foundation
import Testing
@testable import BridgeCore

struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// a | b, with b split into b / c.
    private func threePanes() -> SplitTree {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        return tree
    }

    @Test func splitPlacesNewPaneOnTheRequestedSide() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .left, newPane: b)
        #expect(tree.panes == [b, a])
        tree.split(a, direction: .down, newPane: c)
        #expect(tree.panes == [b, a, c])
    }

    @Test func framesDivideTheUnitSquare() {
        let frames = threePanes().frames()
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(frames[b] == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(frames[c] == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test func removeCollapsesIntoSibling() {
        var tree = threePanes()
        let removedB = tree.remove(b)
        #expect(removedB)
        #expect(tree.panes == [a, c])
        #expect(tree.frames()[c] == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let removedA = tree.remove(a)
        #expect(removedA)
        #expect(tree.root == .leaf(c))
        let removedLast = tree.remove(c)
        #expect(!removedLast)
        #expect(tree.panes == [c])
    }

    @Test func directionalNeighbors() {
        let tree = threePanes()
        #expect(tree.neighbor(of: a, .right) == b)
        #expect(tree.neighbor(of: c, .left) == a)
        #expect(tree.neighbor(of: b, .down) == c)
        #expect(tree.neighbor(of: c, .up) == b)
        #expect(tree.neighbor(of: a, .left) == nil)
        #expect(tree.neighbor(of: a, .up) == nil)
    }

    @Test func previousAndNextWrapAround() {
        let tree = threePanes()
        #expect(tree.neighbor(of: a, .next) == b)
        #expect(tree.neighbor(of: c, .next) == a)
        #expect(tree.neighbor(of: a, .previous) == c)
        #expect(SplitTree(pane: d).neighbor(of: d, .next) == nil)
    }

    @Test func resizeMovesNearestMatchingDivider() {
        var tree = threePanes()
        // Pane c is inside a vertical split inside a horizontal one; moving left moves the
        // horizontal divider by 100 of 1000 points.
        tree.resize(c, direction: .left, points: 100, in: CGSize(width: 1000, height: 800))
        #expect(abs(tree.frames()[a]!.width - 0.4) < 1e-9)
        // Moving down moves the b / c divider, which spans 800 points.
        tree.resize(b, direction: .down, points: 80, in: CGSize(width: 1000, height: 800))
        #expect(abs(tree.frames()[b]!.height - 0.6) < 1e-9)
    }

    @Test func ratiosAreClamped() {
        var tree = threePanes()
        tree.resize(a, direction: .right, points: 10_000, in: CGSize(width: 1000, height: 800))
        #expect(abs(tree.frames()[a]!.width - 0.9) < 1e-9)
    }

    @Test func equalizeSharesSpaceAlongEachAxis() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .right, newPane: c)
        tree.equalize()
        let frames = tree.frames()
        for pane in [a, b, c] {
            #expect(abs(frames[pane]!.width - 1.0 / 3) < 1e-9)
        }
    }
}
