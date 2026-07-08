import SwiftUI
import AppKit
import ServiceManagement
import VelocityCore

struct GeneralSettingsView: View {
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showDateModified") private var showDateModified = false
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("showEditorTitleHeader") private var showEditorTitleHeader = true
    @AppStorage(NotesDirectoryPreference.storageKey) private var notesDirectoryPathsRaw = ""
    @State private var showingMarkupHelp = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var dateDisplayStyle: Binding<DateDisplayStyle> {
        Binding(
            get: { DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart },
            set: { dateDisplayStyleRaw = $0.rawValue }
        )
    }

    private var directories: [URL] {
        let decoded = NotesDirectoryPreference.decode(notesDirectoryPathsRaw)
        return decoded.isEmpty ? NotesDirectoryPreference.load() : decoded
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Envy at Login", isOn: Binding(
                    get: { openAtLogin },
                    set: { setOpenAtLogin($0) }
                ))
            }

            Section("Storage") {
                ForEach(Array(directories.enumerated()), id: \.element) { index, directory in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(directory.lastPathComponent)
                            Text(directory.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if index == 0 {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            moveDirectory(at: index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)

                        Button {
                            moveDirectory(at: index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == directories.count - 1)

                        Button(role: .destructive) {
                            removeDirectory(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(directories.count <= 1)
                    }
                }

                HStack {
                    Button("Add Folder…") {
                        addFolder()
                    }
                    Button("Reveal Default in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([directories[0]])
                    }
                }
            }

            Section("List") {
                Toggle("Show content preview under title", isOn: $showNotePreview)
                Toggle("Show date modified", isOn: $showDateModified)
                Picker("Date Format", selection: dateDisplayStyle) {
                    ForEach(DateDisplayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .disabled(!showDateModified)
            }

            Section("Editor") {
                Toggle("Show title bar above note", isOn: $showEditorTitleHeader)
            }

            Section("Links") {
                Toggle("Require ⌘-click to open note links", isOn: $requireModifierForLinkClick)
            }

            Section("Help") {
                Button("View Markup Commands…") {
                    showingMarkupHelp = true
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(isPresented: $showingMarkupHelp) {
            MarkupHelpView()
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLogin = enabled
        } catch {
            // Reflect whatever actually took effect rather than trusting the
            // requested value if registration failed.
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Notes Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = directories
        guard !updated.contains(url) else { return }
        updated.append(url)
        notesDirectoryPathsRaw = NotesDirectoryPreference.encode(updated)
    }

    private func removeDirectory(at index: Int) {
        var updated = directories
        guard updated.count > 1, updated.indices.contains(index) else { return }
        updated.remove(at: index)
        notesDirectoryPathsRaw = NotesDirectoryPreference.encode(updated)
    }

    private func moveDirectory(at index: Int, by offset: Int) {
        var updated = directories
        let target = index + offset
        guard updated.indices.contains(index), updated.indices.contains(target) else { return }
        updated.swapAt(index, target)
        notesDirectoryPathsRaw = NotesDirectoryPreference.encode(updated)
    }
}
