import CoreGraphics
import Testing
@testable import QuotaMonitor

@Suite("Codex header accessibility traversal")
struct CodexSidebarHeaderReaderTests {
    private let host = CGRect(x: 100, y: 100, width: 1200, height: 800)

    private func tree(depth: Int = 1) -> HeaderTree {
        let tree = HeaderTree(host: host)
        var parent = 1
        for id in 2..<(depth + 2) {
            tree.nodes[parent]?.children = [id]
            tree.nodes[id] = .init(frame: host)
            parent = id
        }
        tree.nodes[parent]?.children = [1000, 1001]
        tree.nodes[1000] = .init(role: "AXPopUpButton",
            frame: CGRect(x: 168, y: 146, width: 76, height: 28),
            labels: ["Switch mode, current mode: Codex"])
        tree.nodes[1001] = .init(role: "AXButton",
            frame: CGRect(x: 506, y: 146, width: 28, height: 28), labels: ["Search"])
        return tree
    }

    @Test("A cold Chromium tree is activated by reading the application role")
    func coldApplication() {
        let tree = tree()
        tree.cold = true
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree.access)
        #expect(result.anchor == .init(leadingInset: 152, trailingXInset: 398, centerYInset: 60))
        #expect(tree.applicationRoleRead)
    }

    @Test("A header beyond fourteen wrapper levels is still discovered")
    func deeplyNestedHeader() {
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree(depth: 24).access)
        #expect(result.anchor != nil)
    }

    @Test("Off-header content neither exhausts traversal nor has its text read")
    func ignoresConversationContent() {
        let tree = tree()
        let content = CGRect(x: 100, y: 400, width: 1100, height: 400)
        tree.nodes[1]?.children.insert(2000, at: 0)
        tree.nodes[2000] = .init(frame: content, children: Array(2001...2800))
        for id in 2001...2800 {
            tree.nodes[id] = .init(role: "AXStaticText", frame: content, labels: ["private fixture text"])
        }
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree.access)
        #expect(result.anchor != nil)
        #expect(tree.descriptorReads.allSatisfy { $0 < 2000 })
        #expect(result.visitedCount < 12)
    }

    @Test("Denied access is reported without querying another application")
    func permissionDenied() {
        let tree = tree()
        var access = tree.access
        access.isTrusted = false
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: access)
        #expect(result.failure == .permissionRequired)
        #expect(!tree.applicationRoleRead)
        #expect(tree.descriptorReads.isEmpty)
    }

    @Test("A cyclic tree is finite and a missing header is distinguishable")
    func cycle() {
        let tree = tree()
        tree.nodes[2]?.children = [1]
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree.access)
        #expect(result.failure == .treeUnavailable)
        #expect(result.visitedCount == 2)
    }

    @Test("Cancelled discovery does not read the target")
    func cancelled() {
        let tree = tree()
        var access = tree.access
        access.isCancelled = { true }
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: access)
        #expect(result.failure == .cancelled)
        #expect(!tree.applicationRoleRead)
    }

    @Test("Unknown or empty wrapper bounds do not hide their header children", arguments: [nil, CGRect.zero])
    func unboundedWrapper(frame: CGRect?) {
        let tree = tree()
        tree.nodes[2]?.frame = frame
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree.access)
        #expect(result.anchor != nil)
    }

    @Test("Elements with equal hashes remain distinct")
    func hashCollisions() {
        let original = tree().access
        let access = CodexSidebarHeaderAccess<CollidingElement>(isTrusted: true,
            role: { original.role($0.id) }, frame: { original.frame($0.id) },
            windows: { original.windows($0.id).map(CollidingElement.init) },
            children: { original.children($0.id).map(CollidingElement.init) },
            descriptors: { original.descriptors($0.id) })
        #expect(CodexSidebarHeaderReader.read(application: .init(id: 0),
            windowFrame: host, access: access).anchor != nil)
    }

    @Test("Traversal limits reject partial measurements", arguments: ["nodes", "depth", "time"])
    func boundedDiscovery(limit: String) {
        let tree = tree()
        var access = tree.access
        if limit == "nodes" {
            tree.nodes[2]?.children += Array(2000...2700)
            for id in 2000...2700 { tree.nodes[id] = .init(frame: host) }
        } else if limit == "depth" {
            tree.nodes[2]?.children.append(2000)
            for id in 2000...2060 { tree.nodes[id] = .init(frame: host, children: [id + 1]) }
        } else {
            var clockReads = 0
            access.uptime = {
                clockReads += 1
                return clockReads <= 4 ? 0 : 1
            }
        }
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: access)
        #expect(result.failure == .traversalLimit)
        #expect(result.anchor == nil)
        #expect(result.visitedCount <= CodexSidebarHeaderReader.maximumVisitedElements)
    }

    @Test("A recognized header with too little room is distinct from unreadable controls")
    func insufficientSpace() {
        let tree = tree()
        tree.nodes[1001]?.frame = CGRect(x: 264, y: 146, width: 28, height: 28)
        let result = CodexSidebarHeaderReader.read(application: 0, windowFrame: host, access: tree.access)
        #expect(result.anchor == nil)
        #expect(result.failure == .insufficientSpace)
        #expect(result.unavailableStatus == .headerSpaceUnavailable)
    }

    @Test("Failure hints distinguish permission, unreadable controls, and an unrecognized header")
    func failureHints() {
        #expect(CodexSidebarHeaderReadResult(failure: .permissionRequired).unavailableStatus == .accessibilityPermissionRequired)
        for failure: CodexSidebarHeaderReadFailure in [.windowUnavailable, .treeUnavailable, .traversalLimit, .cancelled] {
            #expect(CodexSidebarHeaderReadResult(failure: failure).unavailableStatus == .waitingForInterface)
        }
        #expect(CodexSidebarHeaderReadResult(failure: .headerNotFound).unavailableStatus == .waitingForHeader)
    }
}

private struct CollidingElement: Hashable {
    var id: Int
    func hash(into hasher: inout Hasher) { hasher.combine(0) }
}

private final class HeaderTree {
    struct Node {
        var role = "AXGroup"
        var frame: CGRect?
        var labels: [String] = []
        var children: [Int] = []
    }
    var nodes: [Int: Node]
    var cold = false
    var applicationRoleRead = false
    var descriptorReads: [Int] = []

    init(host: CGRect) { nodes = [1: .init(role: "AXWindow", frame: host)] }

    var access: CodexSidebarHeaderAccess<Int> {
        .init(isTrusted: true, role: { id in
            if id == 0 { self.applicationRoleRead = true; return "AXApplication" }
            return self.nodes[id]?.role
        }, frame: { self.nodes[$0]?.frame }, windows: { _ in
            self.cold && !self.applicationRoleRead ? [] : [1]
        }, children: { self.nodes[$0]?.children ?? [] }, descriptors: { id in
            self.descriptorReads.append(id)
            return self.nodes[id]?.labels ?? []
        })
    }
}
