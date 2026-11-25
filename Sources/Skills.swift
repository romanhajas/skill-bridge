// Skills.swift - compare your skills with your Claude account and pack them for upload.
//
// Claude Code keeps a copy of the skills in your Claude account under
// ~/.claude/skills/synced/<id>/ (with a manifest.json). Every skill of yours that
// also lives in ~/.claude/skills/<name> is staged the way the Claude app expects
// it, compared with that copy, and packed as <name>.skill (a ZIP) into
// ~/Desktop/claude-skills-upload only when the two differ. So that folder always
// holds exactly what needs uploading.

import Foundation

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SkillRow: Identifiable, Sendable {
    enum State: Sendable {
        case upload(new: Bool)   // newer here than in Claude, or not in Claude yet
        case upToDate
        case onlyInClaude        // in your Claude account, not on this Mac
        case onlyOnMac           // on this Mac, not in your Claude account
        case hidden              // only in Claude, and you chose not to set it up here
        case failed(String)
    }
    let name: String
    let state: State
    var notes: [String] = []
    var id: String { name }
}

struct Report: Sendable {
    var rows: [SkillRow] = []
    var syncedAt: Date? = nil
    var noSync = false
}

/// One line of a compact diff: "-" for a line only in Claude's copy, "+" for one only here.
struct DiffLine: Hashable, Sendable {
    let sign: Character
    let text: String
}

/// How one file of a skill differs from the copy in the Claude account.
struct FileChange: Identifiable, Sendable {
    enum Kind: Sendable { case added, removed, modified }
    let path: String
    let kind: Kind
    var note: String? = nil
    var lines: [DiffLine] = []
    var id: String { path }
}

struct SkillChanges: Sendable {
    /// Not in the Claude account yet: every file is new.
    let isNew: Bool
    let files: [FileChange]
}

enum Skills {
    static let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    static let skillsDir = home.appendingPathComponent(".claude/skills")
    static let syncedRoot = skillsDir.appendingPathComponent("synced")
    static let outDir = home.appendingPathComponent("Desktop/claude-skills-upload")
    static let configDir: URL = {
        let dir = home.appendingPathComponent(".config/skill-bridge")
        // Settings from before the rename (Package Skills) move over once.
        let old = home.appendingPathComponent(".config/package-skills")
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        return dir
    }()
    static let configFile = configDir.appendingPathComponent("config.json")
    static let hiddenFile = configDir.appendingPathComponent("hidden.json")

    /// Frontmatter keys the Claude app's uploader accepts; anything else moves under metadata.
    static let allowedKeys: Set<String> = ["name", "description", "license", "allowed-tools", "metadata", "compatibility"]
    static let ignoredNames: Set<String> = [".DS_Store", "__pycache__", ".git"]
    static let blockScalars: Set<String> = ["|", ">", "|-", ">-", "|+", ">+"]
    /// Words a skill's name may not contain.
    static let reservedWords = ["anthropic", "claude"]
    static let maxUploadBytes = 20 * 1_048_576

    private static let fm = FileManager.default

    /// Claude's "Upload a new version" dialog takes only a .skill file (a ZIP by another name) or a SKILL.md.
    static func upload(for name: String) -> URL { outDir.appendingPathComponent("\(name).skill") }

    // MARK: - Check

    /// Compares every skill and repacks the uploads. `adding` are skills on this Mac to
    /// send to Claude for the first time; an upload already waiting for one counts too.
    static func check(adding: [String] = []) -> Report {
        guard let claude = claudeCopy() else { return Report(noSync: true) }
        let yours = Set(claude.yours)
        let local = localSkills()
        let hidden = loadHidden()
        let config = Config.load()
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: outDir.appendingPathComponent(".hashes.json"))  // left by version 1
        // Up to version 2.3 uploads were <name>.zip; carry them over so a waiting new skill still counts.
        for old in (try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "zip" {
            let new = upload(for: old.deletingPathExtension().lastPathComponent)
            if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: old) } else { try? fm.moveItem(at: old, to: new) }
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("skill-bridge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let pendingNew = local.filter { !yours.contains($0) && (adding.contains($0) || fm.fileExists(atPath: upload(for: $0).path)) }
        var rows: [SkillRow] = []
        for name in local.filter(yours.contains) + pendingNew {
            do {
                var (staged, notes) = try stage(name, in: tmp, config: config)
                let isYours = yours.contains(name)
                if isYours, try sameSkill(staged, claude.folder.appendingPathComponent(name)) {
                    try? fm.removeItem(at: upload(for: name))
                    rows.append(SkillRow(name: name, state: .upToDate, notes: notes))
                } else {
                    try writeZip(staged, to: upload(for: name))
                    let bytes = (try? fm.attributesOfItem(atPath: upload(for: name).path)[.size] as? NSNumber)?.intValue ?? 0
                    if bytes > maxUploadBytes {
                        notes.append("WARNING: the .skill file is \(bytes / 1_048_576) MB, which may be too big to upload (over 20 MB)")
                    }
                    rows.append(SkillRow(name: name, state: .upload(new: !isYours), notes: notes))
                }
            } catch {
                rows.append(SkillRow(name: name, state: .failed(error.localizedDescription)))
            }
        }
        for name in claude.yours.sorted() where !local.contains(name) {
            rows.append(SkillRow(name: name, state: hidden.contains(name) ? .hidden : .onlyInClaude))
        }
        for name in local where !yours.contains(name) && !pendingNew.contains(name) {
            rows.append(SkillRow(name: name, state: .onlyOnMac))
        }
        return Report(rows: rows, syncedAt: claude.syncedAt)
    }

    // MARK: - Actions

    /// Copies a skill from your Claude account's copy into ~/.claude/skills.
    static func setUp(_ name: String) throws {
        guard let claude = claudeCopy() else { throw Problem("Can't find your Claude account's skills on this Mac.") }
        let src = claude.folder.appendingPathComponent(name), dst = skillsDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.appendingPathComponent("SKILL.md").path) else { throw Problem("\(name) is not in your Claude account.") }
        guard !fm.fileExists(atPath: dst.path) else { throw Problem("\(name) is already on this Mac at \(dst.path).") }
        try copyTree(src, to: dst)
    }

    /// Stops (or resumes) offering to set up a Claude-only skill on this Mac.
    static func setHidden(_ name: String, _ hide: Bool) throws {
        var hidden = loadHidden()
        if hide { hidden.insert(name) } else { hidden.remove(name) }
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: hidden.sorted(), options: [.prettyPrinted]).write(to: hiddenFile)
    }

    /// Drops a waiting upload for a skill you no longer want to send to Claude.
    static func discard(_ name: String) { try? fm.removeItem(at: upload(for: name)) }

    // MARK: - Claude's copy and this Mac's skills

    struct ClaudeCopy { let folder: URL; let yours: [String]; let syncedAt: Date }

    /// The newest synced copy of the Claude account's skills. Anthropic's own
    /// skills are left out; the rest are the ones you uploaded.
    static func claudeCopy() -> ClaudeCopy? {
        let dirs = (try? fm.contentsOfDirectory(at: syncedRoot, includingPropertiesForKeys: nil)) ?? []
        var best: (manifest: [String: Any], path: URL)?
        for dir in dirs {
            let path = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: path),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if best == nil || lastUpdated(manifest) > lastUpdated(best!.manifest) { best = (manifest, path) }
        }
        guard let best else { return nil }
        let (manifest, path) = best
        let skills = manifest["skills"] as? [[String: Any]] ?? []
        let yours = skills.filter { !(($0["source"] as? String) ?? "").hasPrefix("anthropic") }.compactMap { $0["name"] as? String }
        let modified = (try? fm.attributesOfItem(atPath: path.path)[.modificationDate] as? Date) ?? .distantPast
        let syncedAt = max(Date(timeIntervalSince1970: lastUpdated(manifest) / 1000), modified)
        return ClaudeCopy(folder: path.deletingLastPathComponent(), yours: yours, syncedAt: syncedAt)
    }

    private static func lastUpdated(_ manifest: [String: Any]) -> Double { (manifest["lastUpdated"] as? NSNumber)?.doubleValue ?? 0 }

    /// Changes whenever Claude Code finishes a sync round (about every 10 minutes while it runs).
    static func claudeCopyStamp() -> Date? {
        let dirs = (try? fm.contentsOfDirectory(at: syncedRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.flatMap { [$0.appendingPathComponent("manifest.json"), $0.appendingPathComponent(".last-complete-round")] }
            .compactMap { try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .max()
    }

    /// True when Claude Code is set not to download the account's skills
    /// (`"syncClaudeAiSkills": false` in ~/.claude/settings.json).
    static var syncTurnedOff: Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (settings["syncClaudeAiSkills"] as? Bool) == false
    }

    /// What to do when there is no synced copy to compare with.
    static var noSyncAdvice: String {
        syncTurnedOff
            ? "Claude Code is set not to download them: remove \"syncClaudeAiSkills\": false from ~/.claude/settings.json, then start Claude Code."
            : "Open Claude Code once and sign in with your Claude account. It downloads your skills."
    }

    static func localSkills() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: skillsDir.path)) ?? []
        return names.filter { $0 != "synced" && !$0.hasPrefix(".")
            && fm.fileExists(atPath: skillsDir.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }.sorted()
    }

    static func loadHidden() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenFile), let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return Set(names)
    }

    // MARK: - Staging

    /// Personal packaging rules, from ~/.config/skill-bridge/config.json.
    struct Config {
        /// skill -> (path inside the skill -> file elsewhere on disk to ship there)
        var extraFiles: [String: [String: String]] = [:]
        /// skill -> [[find, replace]] applied to SKILL.md after extraFiles are copied in
        var textFixes: [String: [[String]]] = [:]

        static func load() -> Config {
            guard let data = try? Data(contentsOf: configFile),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Config() }
            return Config(extraFiles: o["extraFiles"] as? [String: [String: String]] ?? [:],
                          textFixes: o["textFixes"] as? [String: [[String]]] ?? [:])
        }
    }

    /// Copies a skill into `tmp` the way the Claude app wants it: extra files in,
    /// text fixes applied, unknown frontmatter keys moved under metadata.
    static func stage(_ name: String, in tmp: URL, config: Config) throws -> (URL, [String]) {
        let src = skillsDir.appendingPathComponent(name).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: src.appendingPathComponent("SKILL.md").path) else { throw Problem("no SKILL.md in \(src.path)") }
        let dst = tmp.appendingPathComponent(name)
        try copyTree(src, to: dst)
        for (rel, extra) in config.extraFiles[name] ?? [:] {
            let from = URL(fileURLWithPath: extra.hasPrefix("~/") ? home.path + extra.dropFirst() : extra)
            guard fm.fileExists(atPath: from.path) else { continue }  // e.g. a Mac set up from the Claude copy, which has it already
            let to = dst.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }

        let skillMD = dst.appendingPathComponent("SKILL.md")
        var text = try String(contentsOf: skillMD, encoding: .utf8)
        for fix in config.textFixes[name] ?? [] where fix.count == 2 {
            text = text.replacingOccurrences(of: fix[0], with: fix[1])
        }
        let (fixed, moved) = try fixFrontmatter(text)
        try fixed.write(to: skillMD, atomically: true, encoding: .utf8)

        var notes = moved.isEmpty ? [] : ["moved \(moved.joined(separator: ", ")) under metadata"]
        let (lines, body) = try splitFrontmatter(fixed)
        let declared = field(lines, "name")
        if declared != name { notes.append("WARNING: frontmatter name is \(declared.map { "'\($0)'" } ?? "missing"), folder is '\(name)'") }
        if let declared {
            if declared.count > 64 { notes.append("WARNING: name is \(declared.count) chars (limit 64)") }
            if declared.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                notes.append("WARNING: name may only use lowercase letters, numbers and single hyphens, none at the start or end")
            }
            for word in reservedWords where declared.lowercased().contains(word) {
                notes.append("WARNING: name contains the reserved word '\(word)'")
            }
        }
        let desc = field(lines, "description") ?? ""
        if desc.isEmpty { notes.append("WARNING: no description") }
        else if desc.count > 1024 { notes.append("WARNING: description is \(desc.count) chars (limit 1024)") }
        if desc.contains("<") || desc.contains(">") { notes.append("WARNING: description contains < or >, read as XML tags") }
        if let compat = field(lines, "compatibility"), compat.count > 500 {
            notes.append("WARNING: compatibility is \(compat.count) chars (limit 500)")
        }
        for ref in references(in: body, skill: dst) where !fm.fileExists(atPath: dst.appendingPathComponent(ref).path) {
            notes.append("WARNING: SKILL.md refers to \(ref), which isn't in the skill")
        }
        return (dst, notes)
    }

    /// Relative files SKILL.md points at: markdown links, and backticked paths whose
    /// first folder exists in the skill (so `src/app.ts` in an example isn't counted).
    static func references(in body: String, skill: URL) -> [String] {
        var found: [String] = []
        func matches(_ pattern: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(body.startIndex..., in: body)
            return re.matches(in: body, range: range).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
        }
        for link in matches(#"\[[^\]]*\]\(([^)\s]+)\)"#) {
            var path = link.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, !path.contains(":"), !path.hasPrefix("/"), !path.hasPrefix("~") else { continue }
            found.append(path.removingPercentEncoding ?? path)
        }
        for code in matches(#"`([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]+)`"#) {
            let path = code.hasPrefix("./") ? String(code.dropFirst(2)) : code
            var isDir: ObjCBool = false
            let first = path.components(separatedBy: "/")[0]
            if fm.fileExists(atPath: skill.appendingPathComponent(first).path, isDirectory: &isDir), isDir.boolValue {
                found.append(path)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func writeZip(_ src: URL, to zipURL: URL) throws {
        let work = fm.temporaryDirectory.appendingPathComponent("skill-bridge-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let built = work.appendingPathComponent(zipURL.lastPathComponent)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qrX", built.path, src.lastPathComponent]
        zip.currentDirectoryURL = src.deletingLastPathComponent()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw Problem("zip failed for \(src.lastPathComponent)") }
        try? fm.removeItem(at: zipURL)
        try fm.moveItem(at: built, to: zipURL)
    }

    /// Copies a folder, skipping .DS_Store, .git, __pycache__ and *.pyc, and
    /// following symlinks so the copy holds real files.
    static func copyTree(_ src: URL, to dst: URL) throws {
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let walk = fm.enumerator(atPath: src.path) else { throw Problem("can't read \(src.path)") }
        while let rel = walk.nextObject() as? String {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.contains(where: ignoredNames.contains) || rel.hasSuffix(".pyc") {
                walk.skipDescendants()
                continue
            }
            let from = src.appendingPathComponent(rel), to = dst.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDir)
            if isDir.boolValue {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } else {
                try Data(contentsOf: from).write(to: to)
            }
        }
    }

    // MARK: - Comparing with the Claude copy

    /// True when the staged build says the same as the copy in the Claude account.
    /// SKILL.md is compared by meaning, since the Claude app rewrites its frontmatter.
    static func sameSkill(_ staged: URL, _ remote: URL) throws -> Bool {
        let a = files(staged), b = files(remote)
        guard Set(a) == Set(b) else { return false }
        for rel in a {
            let x = staged.appendingPathComponent(rel), y = remote.appendingPathComponent(rel)
            if rel == "SKILL.md" {
                let fa = try splitFrontmatter(String(contentsOf: x, encoding: .utf8))
                let fb = try splitFrontmatter(String(contentsOf: y, encoding: .utf8))
                if frontmatterMeaning(fa.lines) != frontmatterMeaning(fb.lines) || trimmed(fa.body) != trimmed(fb.body) { return false }
            } else if try Data(contentsOf: x) != Data(contentsOf: y) {
                return false
            }
        }
        return true
    }

    /// What would change in the Claude account if this skill were uploaded now: each
    /// added, removed or modified file, compared the same way as sameSkill.
    static func changes(for name: String) throws -> SkillChanges {
        let tmp = fm.temporaryDirectory.appendingPathComponent("skill-bridge-changes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let (staged, _) = try stage(name, in: tmp, config: Config.load())
        guard let claude = claudeCopy(), claude.yours.contains(name),
              fm.fileExists(atPath: claude.folder.appendingPathComponent(name).path) else {
            return SkillChanges(isNew: true, files: files(staged).sorted().map { FileChange(path: $0, kind: .added) })
        }
        let remote = claude.folder.appendingPathComponent(name)
        let here = Set(files(staged)), there = Set(files(remote))
        var out: [FileChange] = []
        for rel in here.union(there).sorted() {
            guard there.contains(rel) else { out.append(FileChange(path: rel, kind: .added)); continue }
            guard here.contains(rel) else { out.append(FileChange(path: rel, kind: .removed)); continue }
            let mine = try Data(contentsOf: staged.appendingPathComponent(rel))
            let theirs = try Data(contentsOf: remote.appendingPathComponent(rel))
            if rel == "SKILL.md" {
                let a = try splitFrontmatter(String(decoding: mine, as: UTF8.self))
                let b = try splitFrontmatter(String(decoding: theirs, as: UTF8.self))
                let ma = frontmatterMeaning(a.lines), mb = frontmatterMeaning(b.lines)
                let keys = Set(ma.keys).union(mb.keys).filter { ma[$0] != mb[$0] }.sorted()
                let bodyChanged = trimmed(a.body) != trimmed(b.body)
                guard !keys.isEmpty || bodyChanged else { continue }
                var change = FileChange(path: rel, kind: .modified)
                if !keys.isEmpty { change.note = "Frontmatter changed: \(keys.joined(separator: ", "))" }
                if bodyChanged { change.lines = diff(old: trimmed(b.body), new: trimmed(a.body)) }
                out.append(change)
            } else if mine != theirs {
                var change = FileChange(path: rel, kind: .modified)
                if let new = String(data: mine, encoding: .utf8), let old = String(data: theirs, encoding: .utf8) {
                    change.lines = diff(old: old, new: new)
                } else {
                    change.note = "Binary file changed"
                }
                out.append(change)
            }
        }
        return SkillChanges(isNew: false, files: out)
    }

    /// The lines only in `old` ("-") and only in `new` ("+"), in file order, capped.
    static func diff(old: String, new: String, limit: Int = 200) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var lines: [(offset: Int, order: Int, line: DiffLine)] = []
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, element, _): lines.append((offset, 0, DiffLine(sign: "-", text: element)))
            case let .insert(offset, element, _): lines.append((offset, 1, DiffLine(sign: "+", text: element)))
            }
        }
        let sorted = lines.sorted { ($0.offset, $0.order) < ($1.offset, $1.order) }.map(\.line)
        guard sorted.count > limit else { return sorted }
        return Array(sorted.prefix(limit)) + [DiffLine(sign: "…", text: "\(sorted.count - limit) more changed lines")]
    }

    static func files(_ root: URL) -> [String] {
        var out: [String] = []
        guard let walk = fm.enumerator(atPath: root.path) else { return out }
        while let rel = walk.nextObject() as? String {
            if rel.split(separator: "/").contains(where: { ignoredNames.contains(String($0)) }) || rel.hasSuffix(".pyc") { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Frontmatter

    static func splitFrontmatter(_ text: String) throws -> (lines: [String], body: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard t.hasPrefix("---\n"),
              let end = t.range(of: "\n---\n", range: t.index(t.startIndex, offsetBy: 3)..<t.endIndex) else {
            throw Problem("SKILL.md has no --- frontmatter block")
        }
        let start = t.index(t.startIndex, offsetBy: 4)
        let header = start <= end.lowerBound ? String(t[start..<end.lowerBound]) : ""
        return (header.components(separatedBy: "\n"), String(t[end.upperBound...]))
    }

    /// `key:` at the start of a line, as YAML writes a mapping key.
    static func leadingKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return String(key)
    }

    /// Frontmatter lines grouped into top-level entries.
    static func entries(_ lines: [String]) -> [(key: String, block: [String])] {
        var out: [(key: String, block: [String])] = []
        for line in lines {
            if let first = line.first, !first.isWhitespace, let key = leadingKey(line) {
                out.append((key, [line]))
            } else if !out.isEmpty {
                out[out.count - 1].block.append(line)
            }
        }
        return out
    }

    static func fixFrontmatter(_ text: String) throws -> (String, [String]) {
        let (lines, body) = try splitFrontmatter(text)
        var kept: [(key: String, block: [String])] = [], moved: [(key: String, block: [String])] = []
        for entry in entries(lines) {
            if allowedKeys.contains(entry.key) { kept.append(entry) } else { moved.append(entry) }
        }
        if !moved.isEmpty {
            let indented = moved.flatMap(\.block).map { trimmed($0).isEmpty ? $0 : "  " + $0 }
            if let i = kept.firstIndex(where: { $0.key == "metadata" }) { kept[i].block += indented }
            else { kept.append(("metadata", ["metadata:"] + indented)) }
        }
        return ("---\n\(kept.flatMap(\.block).joined(separator: "\n"))\n---\n\(body)", moved.map(\.key))
    }

    private static func firstValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Value of a top-level field, block scalars flattened.
    static func field(_ lines: [String], _ name: String) -> String? {
        guard let block = entries(lines).first(where: { $0.key == name })?.block else { return nil }
        let first = firstValue(block[0])
        if blockScalars.contains(first) {
            return block.dropFirst().map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// Strips YAML quotes from a scalar, keeping a leading "- " or "key: ".
    static func unquote(_ part: String) -> String {
        var prefix = "", rest = Substring(part)
        if rest.hasPrefix("- ") {
            prefix = "- "; rest = rest.dropFirst(2)
        } else if let key = leadingKey(part) {
            prefix = key + ":"; rest = rest.dropFirst(key.count + 1)
            if rest.hasPrefix(" ") { prefix += " "; rest = rest.dropFirst() }
        }
        var v = rest.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.first == "\"", v.last == "\"" {
            if let data = v.data(using: .utf8), let s = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String {
                v = s
            } else {
                v = String(v.dropFirst().dropLast())
            }
        } else if v.count >= 2, v.first == "'", v.last == "'" {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return prefix + v
    }

    /// Each top-level key with its value reduced to plain words, so the same
    /// frontmatter written in a different YAML style compares equal.
    static func frontmatterMeaning(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, block) in entries(lines) {
            let first = firstValue(block[0])
            let rest = block.dropFirst().map(trimmed).filter { !$0.isEmpty }
            let parts = blockScalars.contains(first) ? rest : (first.isEmpty ? [] : [first]) + rest
            out[key] = parts.map(unquote).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return out
    }
}
