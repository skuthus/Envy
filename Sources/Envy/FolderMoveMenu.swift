import SwiftUI
import AppKit
import EnvyCore

/// One node of the folder hierarchy the "Move to" menus render as nested
/// submenus. Built from the flat `subfolderCache` (full relative paths like
/// "projects/work"); each node carries its own full `path` (for the move and
/// for color/swatch lookup) and its `name` (the leaf, shown in the menu).
struct FolderNode: Identifiable {
    let path: String
    let name: String
    var children: [FolderNode] = []
    var id: String { path }

    /// Builds the forest from a sorted list of full relative paths. Intermediate
    /// folders are created on demand, so a deep path whose parent isn't itself
    /// listed still nests correctly.
    static func build(from paths: [String]) -> [FolderNode] {
        var roots: [FolderNode] = []
        for path in paths {
            insert(components: path.split(separator: "/").map(String.init), prefix: "", into: &roots)
        }
        return roots
    }

    private static func insert(components: [String], prefix: String, into nodes: inout [FolderNode]) {
        guard let first = components.first else { return }
        let currentPath = prefix.isEmpty ? first : prefix + "/" + first
        let rest = Array(components.dropFirst())
        if let idx = nodes.firstIndex(where: { $0.name == first }) {
            insert(components: rest, prefix: currentPath, into: &nodes[idx].children)
        } else {
            var node = FolderNode(path: currentPath, name: first)
            insert(components: rest, prefix: currentPath, into: &node.children)
            nodes.append(node)
        }
    }
}

/// A folder as a submenu in the "Move to" tree: move the note(s) straight into
/// this folder, start a new subfolder under it, and — recursively — the same
/// for each child folder. Self-referential in `body`, which is how the whole
/// hierarchy renders however deep it goes.
struct FolderMoveMenu: View {
    let node: FolderNode
    /// The note's current folder, so "Move Here" is disabled for the folder it
    /// already sits in. nil in the bulk menu (a mixed selection has no single
    /// current folder, and moving to where it already is is a harmless no-op).
    let currentPath: String?
    /// Label for the direct-move item — "Move Here" for one note, "Move N Notes
    /// Here" for a selection.
    let moveLabel: String
    let onMove: (String) -> Void
    let onNewSubfolder: (String) -> Void
    let swatch: (String) -> NSImage?

    var body: some View {
        Menu {
            // Child folders first so drilling deeper is the top of the menu;
            // this folder's own actions sit below a divider.
            if !node.children.isEmpty {
                ForEach(node.children) { child in
                    FolderMoveMenu(
                        node: child,
                        currentPath: currentPath,
                        moveLabel: moveLabel,
                        onMove: onMove,
                        onNewSubfolder: onNewSubfolder,
                        swatch: swatch
                    )
                }
                Divider()
            }
            Button(moveLabel) { onMove(node.path) }
                .disabled(currentPath == node.path)
            Button("New Subfolder…") { onNewSubfolder(node.path) }
        } label: {
            if let img = swatch(node.path) {
                Label { Text(node.name) } icon: { Image(nsImage: img) }
            } else {
                Label(node.name, systemImage: "folder")
            }
        }
    }
}
