# Development

← back to the [README](README.md)

This page is for people who want to build Focus Tracker from source, read how
it works, or contribute. If you only want to use the app, the README is all you
need.

## Build from source

Requirements: macOS 14 or later and Xcode with Swift 6 (verified with
Xcode 27.1; no older minimum has been tested).

```sh
brew install xcodegen
xcodegen generate
open FocusTracker.xcodeproj      # build and run from Xcode
```

From the command line:

```sh
xcodebuild -project FocusTracker.xcodeproj -scheme FocusTracker \
  -destination 'platform=macOS' build

xcodebuild -project FocusTracker.xcodeproj -scheme FocusTracker \
  -destination 'platform=macOS' test
```

- The Xcode project is generated from `project.yml`, so it is not committed
  (`.gitignore` lists `*.xcodeproj/`). Re-run `xcodegen generate` after adding
  or removing a source file.
- Ad-hoc code signing is intentional (`CODE_SIGN_IDENTITY: "-"`): you do not
  need an Apple Developer account or a team to build and run it. Please do not
  add a team.
- The test run launches the app and touches its saved settings (the
  `com.chauanhcong.FocusTracker` defaults domain), so quit Focus Tracker first.
- Run one `xcodebuild` at a time: concurrent runs race on the shared
  DerivedData folder.

## Architecture

Focus Tracker is a native SwiftUI app (macOS 14+, Swift 6). The task list and
the session history live in plain files in a folder the user picks (the
"vault"); there is no database and no server.

```
project.yml                  XcodeGen spec: the FocusTracker app target
                             (product name "Focus Tracker", module
                             FocusTracker), the FocusTrackerTests target,
                             macOS 14, Swift 6, MARKETING_VERSION
Sources/FocusTracker/
  FocusTrackerApp.swift      app entry point
  Info.plist, Assets.xcassets  bundle metadata and the app icon
  App/                       app model and settings, vault validation and
                             naming, window-presentation and expiry-alarm
                             controllers, AeroSpaceFloating.swift
  Domain/                    focus-session and break engines, the active-
                             session snapshot (persistence and recovery),
                             status transitions
  Models/                    task, subtask, category, project, session and
                             break logs
  Vault/                     vault store, front-matter and daily-log codecs,
                             atomic file writer, Inbox import, task ordering
  Views/                     SwiftUI views for tasks, sessions and breaks,
                             plus DesignTokens.swift
Packages/SyncCore/           local SwiftPM package for optional git sync
                             (Foundation only, testable without AppKit)
Tests/FocusTrackerTests/     XCTest suites
fixtures/                    fictional vaults the tests use
scripts/generate-icon.swift  regenerates the app icon
```

- **Dependencies.** [Yams](https://github.com/jpsim/Yams) (YAML front matter,
  via Swift Package Manager) and the local `SyncCore` package. Please do not add
  new dependencies without discussion first.
- **SyncCore** holds `GitRunner`, `SyncCoordinator`, `SyncPlan`, `SyncHealth`
  and `SyncCycleError`. Its tests are the `SyncCoreTests` target, which the same
  `FocusTracker` scheme runs.
- **Tests** copy the fixtures into a temporary folder and never modify the
  files in `fixtures/`. `fixtures/sample-vault` is the reference for the file
  format described below.
- **Results are typed.** The code prefers explicit, typed, comparable failure
  values over silent no-ops, and tests assert the exact case.

## The vault format

Everything is ordinary Markdown with YAML front matter. The app reads and writes
exactly two folders in the vault, `Tasks/` and `Logs/` (and removes `Inbox/`
drafts it has imported). It never touches anything else in the vault.

- **Tasks.** `Tasks/<title>.md`, one file per top-level task. Subtasks live
  inside the parent's file, nested to any depth.
  - The file name is the title: case and spaces are kept; `/`, `:` and control
    characters become `-`; trailing dots and spaces are trimmed; a name already
    taken gets `-2`, `-3` and so on. Editing a title does **not** rename the
    file.
  - Front-matter keys: `id`, `title`, `status`, `categories`, `project`,
    `priority`, `effort`, `deadline` (`YYYY-MM-DD`), `notes`, `order` and
    `subtasks`. The Markdown body below the front matter is preserved
    byte-for-byte.
  - Tasks without an `order` sort last, by file name.
- **Logs.** `Logs/YYYY-MM-DD.md` is named for the local calendar day on which a
  session or break ended, and holds `sessions:` and `breaks:`. The invariant for
  a session is `ended_at − started_at == focused + paused`, at minute
  granularity.
- **Inbox.** Any `Inbox/*.md` draft becomes a task: the title is the first `# `
  heading, or the file name without `.md`; the category is **Inbox**; the status
  is **To Do**; the draft's text (after the title heading, if there is one) is
  kept as the Markdown body of the task file, below the front matter, and
  `notes` stays empty; the draft is removed after the import. A draft that is
  not UTF-8 text or is larger than 1 MiB stays where it is and is counted as a
  problem. Drafts are imported at launch and by
  **Import Inbox Drafts (N)** in the Vault menu.
- **Identity.** Every task and subtask has a UUID `id`; references are by id,
  never by title.
- **Writes are atomic.** Each file is written to a temporary file in the same
  directory and then renamed over the target, so a crash never leaves a
  half-written file.
- **No file watcher.** The vault is read at launch, on a vault switch, after a
  sync fast-forward and after an Inbox import. A task that changed on disk
  after it was loaded is refused on save rather than overwritten.
- **Not in the vault:** the in-progress session snapshot
  (`~/Library/Application Support/FocusTracker/active-session.json`) and the
  app's settings.

## Focus sessions, recovery and breaks

The focus-session and break engines are state machines driven by an injectable
tick scheduler, so tests step time deterministically instead of waiting. While
a session runs, a snapshot of it is written about once a second and on quit.
After a crash, recovery re-anchors the elapsed time so the time the app was
closed is not counted, and the user chooses to resume or discard. Breaks are
not persisted: a break interrupted by a quit is lost.

## Sync internals

Optional git sync is implemented by `SyncCore` plus the app's coordinator.

- It is **off by default**; with it off the app never launches `git`.
- Optional GitHub backup needs Apple's free Command Line Tools (or Xcode);
  tasks and timers work without them. The app never installs tools.
- `GitToolResolver` uses filesystem checks only: nonblank `DEVELOPER_DIR`, then
  the selected developer symlink, otherwise CLT then default Xcode. Explicit
  selection fails closed. Every static check and invocation resolves afresh to
  a canonical regular executable, never Apple's `/usr/bin/git` shim. Custom
  absolute binaries are validated too; aliases to the shim cannot bypass this.
  The real executable inherits the user's normal environment: no tokens, no
  `gh`, no stored credentials. License/auth/hook errors remain operation errors.
- Settings keys: `vaultSyncEnabled` and `vaultSyncRemote`. There is no default
  remote. When the other backup requirements are met, with an empty link the
  sync is "unavailable" ("Sync unavailable — no
  sync remote is configured.") and no git command runs.
- The link may be `https://github.com/<owner>/<repo>` or
  `git@github.com:<owner>/<repo>.git`; it is always normalised to the SSH form
  before it is stored. A cycle sets or replaces the vault's `origin` with it.
- A cycle runs: `git fetch`; decide from HEAD versus the remote branch (strictly
  behind → `merge --ff-only`; divergence → stop and report, never an automatic
  merge or force); `git add` of `Tasks` and `Logs` only; `git commit` ("FocusTracker
  vault sync") only if something is staged; `git push`.
- A push cycle starts about a minute after a vault write (debounced) and on
  quit. A pull-only cycle (fast-forward only) runs at launch, before an Inbox
  import, and every 15 minutes while sync is on.
- Only one cycle runs at a time; failures never interrupt the user, they show as
  a status line in the Sync Vault sheet.

## AeroSpace

An optional integration for the [AeroSpace](https://github.com/nikitabobko/AeroSpace)
tiling window manager. When the compact (mini) timer window opens, the app
floats it through the `aerospace` command-line tool, and re-tiles it when the
full window comes back:

- `aerospace list-windows --all --format '%{window-id} %{app-bundle-id}'` finds
  the app's own window;
- `aerospace layout --window-id <id> floating` and `... tiling` switch it.

The binary is looked up at `/opt/homebrew/bin/aerospace`, then on `PATH`. If it
is absent, or a call fails or times out, the integration quietly does nothing.
It never edits `~/.aerospace.toml`, and the window transition never waits on
aerospace. See `Sources/FocusTracker/App/AeroSpaceFloating.swift`.

## Verifying a download

Each release provides byte-identical `FocusTracker-v<version>.dmg` and stable
`FocusTracker.dmg` downloads. Each has its own `.sha256` sidecar (format
`<hash>  <its-own-filename>`). In the download directory, verify either pair:

```sh
shasum -a 256 -c FocusTracker.dmg.sha256
shasum -a 256 -c FocusTracker-v<version>.dmg.sha256
```

The output must match the checksum in the release notes and in the `.sha256`
file.

## Releases

A release is the app built universal (arm64 and x86_64), signed ad hoc (there
is no Apple Developer certificate and it is not notarized), and packaged with
`hdiutil` as a compressed disk image with an Applications shortcut. A SHA-256
file is published beside each name of the identical disk image.

- The version is `MARKETING_VERSION` in `project.yml`, the single source of
  truth.
- The app icon is generated by `scripts/generate-icon.swift`.
- Because the app is not notarized, first-launch approval (possibly again after
  updates) is needed; see
  "Download and first launch" in the [README](README.md).

### Advanced: trusted-download troubleshooting

Only for a download whose source you trust, after trying the README's normal
approval steps. This command bypasses quarantine for this app; it is not the
default install method and does not disable Gatekeeper globally. Do not use it
to bypass damaged-app or malware warnings: stop instead.

```sh
xattr -dr com.apple.quarantine "/Applications/Focus Tracker.app"
```

Warning labels vary by OS/language; managed Macs may need an administrator.
See [Apple's guidance](https://support.apple.com/en-us/102445) and the
[version-specific approval steps](README.md#download-and-first-launch).
macOS 14/15 GUI approval and a clean tools-free Mac remain unverified; native
launch evidence on a developer Mac does not prove those flows.

## Contributing

Issues and pull requests are welcome.

- Run the full test command above before opening a pull request, with Focus
  Tracker quit.
- Do not commit the generated `.xcodeproj`; edit `project.yml` and run
  `xcodegen generate`.
- Swift 6 and macOS 14 are the minimums.
- No new dependencies without discussion.
- The app reads and writes only `Tasks/` and `Logs/` in a vault. Please keep it
  that way.
- Tests use temporary copies of the fixtures, never the files in `fixtures/`.
- Prefer explicit, typed results over silent no-ops.
- The license is MIT; see [LICENSE](LICENSE).
