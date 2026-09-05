# AGENTS.md

Guide for the Termeow repository. Chat with the maintainer may be Chinese. Everything that lands in this repo or on GitHub must be English, including comments.

Product / app / repo: **Termeow**. Site: https://termeow.cn. GitHub: https://github.com/Termeow/Termeow. Bundle ID: `cn.termeow.Termeow`.

## Language

English only on GitHub and in committed files:

- Code comments
- README, docs, this file
- Commit messages, PR titles and bodies, issues, discussions
- GitHub Release titles and notes, repository About / `--description`, tag annotations (`-m`)
- CI workflow `name:` values
- In-repo UI copy, localization strings, `CFBundleDisplayName`

Do not commit Chinese text.

Also English by convention: Conventional Commit type prefixes, identifiers, type names, file and directory names, branch names (`feat/ssh-password`), tag names (`v0.1.0`), workflow file names and job ids.

## Product

- Open `Termeow.xcodeproj`, scheme **Termeow**. macOS 15+, Xcode 16+.
- `App/` is the app. `Sources/TermeowKit` is the shared library. `Tests/` covers the library.
- Bump `CFBundleShortVersionString` (and the matching Info.plist version fields) on release.
- Do not commit Keychain data, private keys, or signing certificates.

Workflow (branches, PRs, releases, hotfixes) follows the workspace `AGENTS.md` next to this clone. Commits and PR text stay English.
