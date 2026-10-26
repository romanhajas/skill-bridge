// Updater.swift - keeps Skill Bridge up to date from its GitHub releases.
//
// Once a day, when the window opens, it asks GitHub for the latest release. A newer
// one is downloaded and checked: it must be signed by the same developer as this
// copy. It goes in when you quit, or straight away with Restart. With automatic
// installs off (Skill Bridge menu), the window offers the update instead.

import AppKit
import Security

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let latestAPI = URL(string: "https://api.github.com/repos/romanhajas/skill-bridge/releases/latest")!
    static let installKey = "installUpdates"
    private static let lastCheckKey = "lastUpdateCheck"

    struct Release { let version: String; let page: URL; let download: URL? }

    /// A newer version, once found.
    @Published private(set) var available: Release?
    /// Downloading and checking it.
    @Published private(set) var preparing = false
    /// The checked app, waiting next to this copy until you quit or restart.
    @Published private(set) var ready: URL?
    /// The answer to a check you asked for, shown as an alert.
    @Published var message: String?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// What this copy was signed to: its bundle ID and developer. An update must meet
    /// the same. Nil for a build signed ad hoc, which only links to new versions.
    nonisolated static let requirement: SecRequirement? = {
        var me: SecCode?, code: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              (text as String?)?.contains("anchor apple generic") == true else { return nil }
        return requirement
    }()

    /// Whether Skill Bridge can replace itself here: a signed copy, in a folder you can write to.
    var canInstall: Bool {
        Self.requirement != nil
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Date().timeIntervalSince1970 - last > 24 * 3600 { Task { await check(manual: false) } }
    }

    func check(manual: Bool) async {
        if let version = available?.version, ready != nil {
            if manual { message = "Skill Bridge \(version) is downloaded and goes in when you quit." }
            return
        }
        guard !preparing else { return }
        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = release["tag_name"] as? String else {
            if manual { message = "Couldn't reach GitHub to check for updates." }
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: current) else {
            // Up to date: look again in a day. A newer version is looked for at every
            // launch until it's in, in case you quit before it finished downloading.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            available = nil
            if manual { message = "Skill Bridge \(current) is the latest version." }
            return
        }
        let page = (release["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/romanhajas/skill-bridge/releases/latest")!
        let assets = release["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { $0["name"] as? String == "Skill-Bridge.zip" }?["browser_download_url"] as? String
        let found = Release(version: version, page: page, download: zip.flatMap(URL.init(string:)))
        available = found
        let automatic = UserDefaults.standard.object(forKey: Self.installKey) as? Bool ?? true
        if canInstall, found.download != nil, manual || automatic {
            await prepare(found, asked: manual)
        } else if manual {
            NSWorkspace.shared.open(page)
        }
    }

    /// Downloads and checks the update, leaving it ready to go in.
    func prepare(_ release: Release, asked: Bool) async {
        guard !preparing, ready == nil, let download = release.download, let requirement = Self.requirement else { return }
        preparing = true
        defer { preparing = false }
        do {
            let (zip, response) = try await URLSession.shared.download(from: download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download didn't arrive") }
            ready = try await Task.detached {
                try Self.unpack(zip, version: release.version, requirement: requirement)
            }.value
        } catch {
            // A daily check that fails stays quiet; the window links to the release instead.
            if asked {
                message = "Couldn't download Skill Bridge \(release.version): \((error as? Failure)?.reason ?? error.localizedDescription)."
            }
        }
    }

    /// Unzips the download next to this copy (same disk, so the swap is a rename) and
    /// makes sure it's Skill Bridge, intact, from the same developer, and the version expected.
    nonisolated private static func unpack(_ zip: URL, version: String, requirement: SecRequirement) throws -> URL {
        let files = FileManager.default
        defer { try? files.removeItem(at: zip) }
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: Bundle.main.bundleURL, create: true)
        let app = work.appendingPathComponent("Skill Bridge.app")
        do {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, work.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0, files.fileExists(atPath: app.path) else {
                throw Failure("the download wasn't a Skill Bridge app")
            }
            var code: SecStaticCode?
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
                throw Failure("the download isn't signed by Skill Bridge's developer")
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleShortVersionString"] as? String == version else {
                throw Failure("the download is a different version")
            }
            return app
        } catch {
            try? files.removeItem(at: work)
            throw error
        }
    }

    /// Puts the update in now and opens it.
    func restart() {
        if swapIn(reopen: true) { NSApp.terminate(nil) }
    }

    /// Puts the checked app where this one is. A small script, once this copy has
    /// quit, tells macOS about the new one, opens it if asked, and clears away the old.
    @discardableResult
    func swapIn(reopen: Bool) -> Bool {
        guard let app = ready else { return false }
        ready = nil
        let files = FileManager.default, target = Bundle.main.bundleURL
        let work = app.deletingLastPathComponent(), old = work.appendingPathComponent("Previous.app")
        do {
            try files.moveItem(at: target, to: old)
            do { try files.moveItem(at: app, to: target) } catch {
                try? files.moveItem(at: old, to: target)
                throw error
            }
        } catch {
            // Only once the old copy is back in place.
            if files.fileExists(atPath: target.path) { try? files.removeItem(at: work) }
            if reopen { message = "Couldn't install the update: \(error.localizedDescription)" }
            return false
        }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            /usr/bin/touch "$0"; \(lsregister) -f "$0"; [ "$2" = open ] && /usr/bin/open "$0"; /bin/rm -rf "$1"
            """
        let after = Process()
        after.executableURL = URL(fileURLWithPath: "/bin/sh")
        after.arguments = ["-c", script, target.path, work.path, reopen ? "open" : ""]
        try? after.run()
        return true
    }

    private struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// Compares "2.10" > "2.9" by number, part by part; missing parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
