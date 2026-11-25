// CLI.swift - the same checks from Terminal. The app's binary runs this when it is
// started as `skill-bridge` (a symlink the app keeps in ~/.local/bin) or with --cli.

import AppKit

enum CLI {
    static let usage = """
    Package your skills as .skill files for upload to the Claude app.

    Compares each of your skills on this Mac with the copy your Claude account has
    (Claude Code keeps it in ~/.claude/skills/synced) and packs a .skill file only
    for the skills that differ. Upload those in the Claude app: Settings -> Plugins -> Skills.

    Usage:
      skill-bridge                  check all your skills, build what changed
      skill-bridge NAME ...         also send these skills on this Mac to Claude
      skill-bridge --setup NAME     copy a skill from your Claude account onto this Mac
      skill-bridge --hide NAME      stop offering to set it up on this Mac (--unhide to undo)
      skill-bridge --discard NAME   drop a waiting .skill file for a skill not in Claude yet
      skill-bridge --changes NAME   show what differs from the copy in your Claude account
      skill-bridge --no-open        don't open the folder in Finder

    Personal packaging rules: ~/.config/skill-bridge/config.json (see README).
    """

    static func run(_ args: [String]) -> Int32 {
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let names = args.filter { !$0.hasPrefix("-") }
        let known: Set<String> = ["--no-open", "--setup", "--hide", "--unhide", "--discard", "--changes", "-h", "--help"]
        if !flags.subtracting(known).isEmpty {
            print("unknown option: \(flags.subtracting(known).sorted().joined(separator: " "))\n\n\(usage)")
            return 2
        }
        if flags.contains("-h") || flags.contains("--help") { print(usage); return 0 }

        do {
            if flags.contains("--setup") {
                for name in names { try Skills.setUp(name); print("  set up     \(name) in \(Skills.skillsDir.appendingPathComponent(name).path)") }
                return 0
            }
            if flags.contains("--hide") || flags.contains("--unhide") {
                for name in names { try Skills.setHidden(name, flags.contains("--hide")) }
                return 0
            }
            if flags.contains("--discard") {
                names.forEach(Skills.discard)
                return 0
            }
            if flags.contains("--changes") {
                for name in names { printChanges(name, try Skills.changes(for: name)) }
                return 0
            }
        } catch {
            print("  FAILED     \(error.localizedDescription)")
            return 1
        }

        let unknown = names.filter { !Skills.localSkills().contains($0) }
        if !unknown.isEmpty { print("not in ~/.claude/skills: \(unknown.joined(separator: ", "))"); return 1 }

        let report = Skills.check(adding: names)
        if report.noSync {
            print("Can't find your Claude account's skills on this Mac (~/.claude/skills/synced).\n\(Skills.noSyncAdvice) Then try again.")
            return 2
        }

        var uploads = 0, failed = false
        var onlyInClaude: [String] = [], onlyOnMac: [String] = []
        for row in report.rows {
            let status: String
            switch row.state {
            case .upload(let new): status = new ? "UPLOAD new " : "UPLOAD     "; uploads += 1
            case .upToDate: status = "in sync    "
            case .failed(let why): status = "FAILED     "; failed = true; print("  \(status)\(row.name): \(why)"); continue
            case .onlyInClaude: onlyInClaude.append(row.name); continue
            case .onlyOnMac: onlyOnMac.append(row.name); continue
            case .hidden: continue
            }
            print("  \(status)\(row.name)" + row.notes.map { "\n               \($0)" }.joined())
        }

        let checked = report.syncedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "unknown"
        print("\nCompared with your Claude account as of \(checked).")
        if !onlyInClaude.isEmpty { print("In Claude but not on this Mac: \(onlyInClaude.joined(separator: ", "))  (--setup NAME)") }
        if !onlyOnMac.isEmpty { print("On this Mac but not in Claude: \(onlyOnMac.joined(separator: ", "))  (skill-bridge NAME to add)") }
        print()
        if uploads > 0 {
            print("Upload \(uploads) .skill file(s) from \(Skills.outDir.path)")
            print("  Claude app -> Settings -> Plugins -> Skills (replace the old version)")
            print("  Uploaded already? Claude Code syncs about every 10 minutes while it runs; check again after that.")
            if !flags.contains("--no-open") { NSWorkspace.shared.open(Skills.outDir) }
        } else {
            print("Everything matches your Claude account. No upload needed.")
        }
        return failed ? 1 : 0
    }

    static func printChanges(_ name: String, _ changes: SkillChanges) {
        if changes.isNew {
            print("\(name): new skill, \(changes.files.count) files")
            changes.files.forEach { print("  + \($0.path)") }
            return
        }
        guard !changes.files.isEmpty else { print("\(name): same as in your Claude account"); return }
        print("\(name): \(changes.files.count) file(s) differ from your Claude account")
        for file in changes.files {
            let kind = switch file.kind { case .added: "added"; case .removed: "removed"; case .modified: "modified" }
            print("\n  \(file.path) (\(kind))")
            if let note = file.note { print("    \(note)") }
            file.lines.forEach { print("    \($0.sign) \($0.text)") }
        }
    }
}
