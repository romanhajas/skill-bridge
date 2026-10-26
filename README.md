<p align="center"><img src="docs/icon.png" width="128" alt="Skill Bridge icon"></p>

# Skill Bridge

A small Mac app that keeps the skills in your Claude app in step with the ones
you edit for Claude Code. (Formerly Package Skills; the old `package-skills`
command still works.)

![Skill Bridge window](docs/screenshot.png)

You write and test a skill in `~/.claude/skills`, where Claude Code picks up
every change. Getting that change into Claude chat (the desktop, web and mobile
apps) means zipping the skill and uploading it under **Settings → Capabilities →
Skills**. Skill Bridge tells you which skills actually need that, and builds
the ZIPs for you.

## What it does

- **Compares with your Claude account, not with its own history.** Claude Code
  keeps a copy of your Claude account's skills in `~/.claude/skills/synced/`.
  Skill Bridge compares each of your skills with that copy, by content, and
  builds a ZIP only when Claude has an older version. The Claude app rewrites a
  skill's frontmatter on upload, so the header is compared by meaning, not byte
  for byte.
- **One folder, exactly what to upload.** ZIPs land in
  `~/Desktop/claude-skills-upload`. A skill that is up to date has no ZIP there.
- **Sets up a new Mac from your Claude account.** Skills that are in your account
  but not on this Mac can be copied into `~/.claude/skills` with one click.
- **Sends new skills to Claude.** Skills on this Mac that aren't in your account
  yet are listed; **Add to Claude** builds their ZIP.
- **Shows what changed.** **Changes** lists every file that differs from the
  copy in your Claude account, with the changed lines, before you upload.
- **Drag and drop.** Drag a skill from the list straight into Claude's upload
  dialog; its ZIP comes along.
- **Catches what the uploader rejects.** Frontmatter keys the Claude app doesn't
  accept (for example `version:`) are moved under `metadata:`. It warns before
  you upload about a `name` that isn't lowercase letters, numbers and hyphens, is
  over 64 characters, contains "anthropic" or "claude", or doesn't match the
  folder; a missing description, one over 1024 characters, or one with `<` or
  `>`; files that `SKILL.md` refers to but the skill doesn't contain; and ZIPs
  over 20 MB.
- **Tells you about new versions.** Once a day it looks for a newer release on
  GitHub and shows a link in the window when there is one (**Skill Bridge →
  Check for Updates…** checks right away).

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask romanhajas/tap/skill-bridge
```

Or download `Skill Bridge.app` from the releases page, or build it:

```bash
git clone https://github.com/romanhajas/skill-bridge.git
cd skill-bridge
./build.sh            # builds and installs to ~/Desktop/Skill Bridge.app
```

Building needs Xcode or the Command Line Tools (`xcode-select --install`). The
built app needs nothing: it's a universal binary for Apple silicon and Intel and
runs on macOS 14 or later.

Downloads are signed and notarized by Apple, so they open normally. Builds you
make yourself are signed ad-hoc, which is fine on your own Mac; `./build.sh
--release` signs with your Developer ID and notarizes when `.signing.env` names
your certificate and notarytool profile (see the top of `build.sh`).

You need Claude Code installed and signed in. That is how your Claude account's
skills reach this Mac. It refreshes them every few minutes while it runs, so
right after an upload the app may still list the skill until Claude Code has
synced.

## Terminal

The app doubles as a command. When `~/.local/bin` exists, it keeps
`~/.local/bin/skill-bridge` pointing at itself:

```text
skill-bridge                  check all your skills, build what changed
skill-bridge NAME ...         also send these skills on this Mac to Claude
skill-bridge --setup NAME     copy a skill from your Claude account onto this Mac
skill-bridge --hide NAME      stop offering to set it up on this Mac (--unhide to undo)
skill-bridge --discard NAME   drop a waiting ZIP for a skill not in Claude yet
skill-bridge --changes NAME   show what differs from the copy in your Claude account
skill-bridge --no-open        don't open the folder in Finder
```

Without the link: `"/Applications/Skill Bridge.app/Contents/MacOS/SkillBridge" --cli`.

## Personal packaging rules

Some skills keep a file outside their folder, for example in a repository they
were cloned from. List those in `~/.config/skill-bridge/config.json` and they
are copied into the ZIP; `textFixes` then edits `SKILL.md` to match. See
[`config.example.json`](config.example.json):

```json
{
  "extraFiles": {
    "humanizer": { "scripts/copy_scan.py": "~/humanizer-stack/scripts/copy_scan.py" }
  },
  "textFixes": {
    "humanizer": [["# from the repo root", "# from the skill folder"]]
  }
}
```

Skills you hide are remembered in `~/.config/skill-bridge/hidden.json`.

## Good to know

- It reads `~/.claude/skills` and Claude Code's synced copy, and writes only to
  `~/Desktop/claude-skills-upload`, `~/.config/skill-bridge` and, when you
  ask it to set up a skill, `~/.claude/skills/<name>`. Its only network request
  is the daily update check against GitHub's public releases; it has no login of
  its own.
- The synced copy is how Claude Code stores your skills today; a future Claude
  Code update could change that.
- The icon is drawn by `tools/make-icon.swift`.

Not affiliated with Anthropic. Claude is a trademark of Anthropic.

## Releasing

Push a version tag and GitHub builds, signs, notarizes and publishes the app:

```bash
git tag v2.3 && git push origin v2.3
```

The workflow (`.github/workflows/release.yml`) needs six repository secrets: the
Developer ID certificate exported as a .p12 (`DEVELOPER_ID_P12`, base64-encoded,
and `DEVELOPER_ID_P12_PASSWORD`), `SIGN_IDENTITY`, and the notarization login
(`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, an app-specific password).

## Support

Skill Bridge is free. If it saves you some packing and uploading, you can
[sponsor me on GitHub](https://github.com/sponsors/romanhajas).

## License

MIT
