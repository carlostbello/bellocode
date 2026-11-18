import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Words for MR chips and rows (status is never colour only: a glyph and words every time).
public enum MergeRequestText {
    /// "!42 Draft · ✕ Pipeline failed · 1/2 approvals" (header chip). Status is a glyph and words, never colour only.
    public static func chip(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" + (link.watching ? " · Babysitting" : "") }
        var parts = ["!\(link.ref.iid) \(snapshot.stateLabel)"]
        if snapshot.state == .opened {
            let pipeline = snapshot.pipelineSummary
            if pipeline != .none { parts.append("\(pipeline.glyph) \(pipeline.text)") }
            if snapshot.approvals.required > 0 || !snapshot.approvals.approvedBy.isEmpty { parts.append(approvalCount(snapshot)) }
        }
        return parts.joined(separator: " · ")
    }

    /// "!42 Draft ✕ 1/2" (sidebar: compact; the pipeline glyph, the approval count, Draft as a word).
    public static func compact(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" }
        if snapshot.state.isTerminal { return "!\(link.ref.iid) \(snapshot.state.label)" }
        let pipeline = snapshot.pipelineSummary
        var text = "!\(link.ref.iid)" + (snapshot.draft ? " Draft" : "") + (pipeline == .none ? "" : " \(pipeline.glyph)")
        if snapshot.approvals.required > 0 { text += " \(snapshot.approvals.required - snapshot.approvals.left)/\(snapshot.approvals.required)" } else if !snapshot.approvals.approvedBy.isEmpty {
            text += " ✓\(snapshot.approvals.approvedBy.count)"
        }
        return text
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

