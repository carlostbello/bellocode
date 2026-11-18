import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Words for MR chips and rows (status is never colour only: a glyph and words every time).
public enum MergeRequestText {
    /// "!42 Open · ✓ Pipeline passed" (header chip). Draft MRs say "Draft".
    public static func chip(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" + (link.watching ? " · Watching" : "") }
        var parts = ["!\(link.ref.iid) \(snapshot.stateLabel)"]
        if snapshot.state == .opened {
            let pipeline = snapshot.pipelineSummary
            if pipeline != .none { parts.append("\(pipeline.glyph) \(pipeline.text)") }
        }
        return parts.joined(separator: " · ")
    }

    /// "!42 ✓" (sidebar: compact).
    public static func compact(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" }
        if snapshot.state.isTerminal { return "!\(link.ref.iid) \(snapshot.state.label)" }
        let pipeline = snapshot.pipelineSummary
        return "!\(link.ref.iid)" + (snapshot.draft ? " Draft" : "") + (pipeline == .none ? "" : " \(pipeline.glyph)")
    }

    public static func accessibility(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "Merge request \(link.ref.iid)" }
        return "Merge request \(link.ref.iid), \(snapshot.title), \(snapshot.stateLabel), \(snapshot.approvals.label), \(snapshot.pipelineSummary.text), "
            + snapshot.unresolvedText + (link.watching ? ", watching" : "") + (snapshot.truncationNote.map { ". \($0)" } ?? "")
    }

    /// "1/2 approvals", "Approved", "No approvals".
    public static func approvalCount(_ snapshot: MergeRequestSnapshot) -> String {
        let approvals = snapshot.approvals
        if approvals.required > 0 { return "\(approvals.required - approvals.left)/\(approvals.required) approvals" }
        if !approvals.approvedBy.isEmpty { return approvals.approvedBy.count == 1 ? "1 approval" : "\(approvals.approvedBy.count) approvals" }
        return "No approvals"
    }

    public static func source(_ source: MergeRequestLinkSource) -> String {
        switch source {
        case .agent: "linked by the agent"
        case .branch: "this thread's branch"
        case .output: "pushed from this thread"
        case .user: "linked by you"
        }
    }
}

