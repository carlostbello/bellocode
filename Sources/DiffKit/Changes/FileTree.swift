import AppKit
import Foundation

/// A node of the changed-files tree: a folder (single-child folder chains are compacted: "Sources/Auth") or a file.
public final class FileTreeNode: NSObject, Sendable {
    public let name: String
    /// The folder path or the file's path.
    public let path: String
    public let file: ChangedFile?
    public let children: [FileTreeNode]

    init(name: String, path: String, file: ChangedFile?, children: [FileTreeNode]) {
        self.name = name
        self.path = path
        self.file = file
        self.children = children
    }

    public var isFolder: Bool { file == nil }
    /// Every file below (or this file).
    public var files: [ChangedFile] { file.map { [$0] } ?? children.flatMap(\.files) }
}

public enum FileTree {
    /// Builds a sorted tree (folders first, then files, by name) with compacted folder chains.
    public static func build(_ files: [ChangedFile]) -> [FileTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [ChangedFile] = []
        }
        let root = Folder()
        for file in files {
            var folder = root
            let components = file.path.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                if let existing = folder.folders[component] {
                    folder = existing
                } else {
                    let created = Folder()
                    folder.folders[component] = created
                    folder = created
                }
            }
            folder.files.append(file)
        }
        func nodes(_ folder: Folder, prefix: String) -> [FileTreeNode] {
            var result: [FileTreeNode] = []
            for name in folder.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var current = folder.folders[name]!
                var label = name
                var path = prefix.isEmpty ? name : prefix + "/" + name
                // Compact "a/b/c" while a folder holds exactly one folder and no files.
                while current.files.isEmpty, current.folders.count == 1, let (child, next) = current.folders.first {
                    label += "/" + child
                    path += "/" + child
                    current = next
                }
                result.append(FileTreeNode(name: label, path: path, file: nil, children: nodes(current, prefix: path)))
            }
            for file in folder.files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                result.append(FileTreeNode(name: (file.path as NSString).lastPathComponent, path: file.path, file: file, children: []))
            }
            return result
        }
        return nodes(root, prefix: "")
    }
}

/// Opens files in the user's editor: the default app for the file, or a chosen editor (VS Code, Cursor, Zed open at
/// the line through their URL schemes; others open the file).
@MainActor
public enum EditorLauncher {
    public struct Editor: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        /// URL scheme for "open at line" (`vscode://file/<path>:<line>`).
        public var scheme: String?
        public var bundleIdentifier: String?
    }

    public static let defaultEditorID = "default"
    static let known: [Editor] = [
        Editor(id: "vscode", name: "Visual Studio Code", scheme: "vscode", bundleIdentifier: "com.microsoft.VSCode"),
        Editor(id: "cursor", name: "Cursor", scheme: "cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        Editor(id: "zed", name: "Zed", scheme: "zed", bundleIdentifier: "dev.zed.Zed"),
        Editor(id: "xcode", name: "Xcode", scheme: nil, bundleIdentifier: "com.apple.dt.Xcode"),
        Editor(id: "sublime", name: "Sublime Text", scheme: nil, bundleIdentifier: "com.sublimetext.4"),
        Editor(id: "textedit", name: "TextEdit", scheme: nil, bundleIdentifier: "com.apple.TextEdit"),
    ]

    /// Editors installed on this Mac, the default app first.
    public static var available: [Editor] {
        [Editor(id: defaultEditorID, name: "Default App", scheme: nil, bundleIdentifier: nil)]
            + known.filter { $0.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil }
    }

    static let preferenceKey = "BelloCodePreferredEditor"

    /// The chosen editor (UserDefaults; "default" when unset).
    public static var preferredEditorID: String {
        get { UserDefaults.standard.string(forKey: preferenceKey) ?? defaultEditorID }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    public static func open(_ url: URL, line: Int? = nil, editorID: String? = nil) {
        let id = editorID ?? preferredEditorID
        guard let editor = known.first(where: { $0.id == id }) else {
            NSWorkspace.shared.open(url)
            return
        }
        if let scheme = editor.scheme, let target = URL(string: "\(scheme)://file\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)\(line.map { ":\($0)" } ?? "")") {
            NSWorkspace.shared.open(target)
            return
        }
        if let bundle = editor.bundleIdentifier, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
