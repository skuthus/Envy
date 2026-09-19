import AppKit
import EnvyCore

/// Installs the Envy agent guide so an AI agent can work with the user's notes.
///
/// Two targets, from one command:
///  1. `AGENTS.md` at the vault root — the universal, tool-agnostic copy. It
///     lives with the notes, so any agent that operates on the vault finds it
///     (AGENTS.md-aware tools read it automatically; others see it on listing).
///     Envy hides this file from the notes list (NoteStore.agentGuideFileName).
///  2. `~/.claude/skills/envy-notes/SKILL.md` — a Claude Code skill, for
///     zero-config auto-surfacing there. A convenience, not the mechanism.
///
/// Envy is not sandboxed (Developer ID), so it writes both directly.
enum AgentSkillInstaller {
    static let claudeSkillDirName = "envy-notes"

    @MainActor
    static func installInteractively() {
        let fm = FileManager.default

        // 1. AGENTS.md in the vault — the part that makes it work for any agent.
        let vault = IndexPreference.load()
        let agentsURL = vault.appendingPathComponent(NoteStore.agentGuideFileName)
        do {
            try Data(AgentSkillContent.guideBody.utf8).write(to: agentsURL, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't write the agent guide"
            alert.informativeText = "Failed to write \(NoteStore.agentGuideFileName) to your vault (\(vault.path)):\n\n\(error.localizedDescription)"
            alert.runModal()
            return
        }

        // 2. Claude Code skill (best-effort — a failure here doesn't undo #1).
        var claudeNote = ""
        let claudeDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/\(claudeSkillDirName)", isDirectory: true)
        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try Data(AgentSkillContent.claudeSkill.utf8).write(to: claudeDir.appendingPathComponent("SKILL.md"), options: .atomic)
            claudeNote = "\n• Claude Code: ~/.claude/skills/\(claudeSkillDirName)/SKILL.md (auto-surfaces there)"
        } catch {
            claudeNote = "\n• (Couldn't also install the Claude Code skill: \(error.localizedDescription))"
        }

        let alert = NSAlert()
        alert.messageText = "Agent guide installed"
        alert.informativeText = """
        Any AI agent working with your notes will now find how-to guidance:

        • AGENTS.md in your vault (\(vault.lastPathComponent)) — read by any agent that works in the folder\(claudeNote)

        Point your agent at your notes and ask it to capture, find, or update — it follows Envy's conventions and finds the vault on its own.
        """
        alert.addButton(withTitle: "Reveal Guide in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([agentsURL])
        }
    }
}
