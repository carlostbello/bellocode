import Foundation

/// A composer to put text into, bound when an action starts to the composer shown at that moment (AV10). Actions that
/// await something first (a Keychain read, a job log) insert through it afterwards: if the person switched threads
/// meanwhile, `insert` returns false and puts nothing anywhere, so GitLab content meant for one thread never lands in
/// another thread's draft.
@MainActor
public struct ComposerTarget {
    private let insertion: (String) -> Bool

    /// `insert` inserts and returns true, or returns false (inserting nothing) when its composer is no longer shown or
    /// is still loading its thread's draft.
    public init(insert: @escaping (String) -> Bool) {
        insertion = insert
    }

    /// Inserts `text` as one undoable edit; false when the composer this target was bound to is no longer shown.
    @discardableResult
    public func insert(_ text: String) -> Bool { insertion(text) }

    /// What to tell the person when `insert` returned false.
    public static let movedMessage = "The composer on screen changed, or was still loading its draft, before the text was ready, so nothing was added to any composer. Add it again from the thread you want."
}
