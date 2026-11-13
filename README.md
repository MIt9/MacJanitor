<div align="center">

**English** · [Українська](README.uk.md)

<img src="docs/icon.png" alt="MacJanitor" width="96" height="96">

# MacJanitor

**Processes, ports, disk space and apps on macOS in one window, plus explanations from a local AI.**

macOS 26+ · Swift 6 · SwiftUI · CLI `macjanitor`

</div>

---

## Features

| Tab | What it does |
| --- | --- |
| **Processes** | Apps and background processes with CPU, memory, PID and owner. Graceful or forced termination of the current user's processes. |
| **Ports** | Listening TCP ports and UDP sockets with process, PID and address. Search, refresh, terminate the process. |
| **Storage** | Scan the home folder or a chosen folder: tree view or the 100 largest files. Reveal in Finder, move to Trash (also during a scan), safe cleanup of caches and logs, copy or move to Google Drive. |
| **Apps** | Apps from `/Applications` and `~/Applications`: bundle id, version, real size, last launch. Removal that respects uninstallers and running processes, plus search for leftovers and orphaned data. |

The **Processes**, **Ports** and **Storage** tabs have an **Ask AI** button (and a context menu item). The AI explains what a process, port or folder is, who creates it, and whether it is safe to terminate or delete.

The UI is available in English and Ukrainian (**Language / Мова** menu).

## Quick start

```bash
./bundle.sh
open build/MacJanitor.app
```

`bundle.sh` builds a release version and signs `build/MacJanitor.app`. A stable signature and bundle id keep macOS permissions (notably Full Disk Access) between builds.

### Code signing

There are no prebuilt binaries in this repository: build the app yourself. You need your own code-signing certificate, for example a free `Apple Development` one (Xcode → Settings → Accounts → Manage Certificates). List yours:

```bash
security find-identity -v -p codesigning
```

Pass the certificate name or SHA-1:

```bash
MACJANITOR_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./bundle.sh
```

The script has the author's certificate as its default, which does not exist on your Mac, so always set the variable. Ad hoc signing (`-`) is not supported: without a stable signature macOS resets permissions after every build.

The app is **not notarized** and not signed with a `Developer ID`, so Gatekeeper blocks a `.app` downloaded from the internet. A build signed with your own certificate on your own Mac runs without warnings.

> [!TIP]
> For a full scan, add `MacJanitor.app` under **System Settings → Privacy & Security → Full Disk Access**. Without it some folders are inaccessible and sizes are incomplete. The Storage tab has buttons to open the settings and re-check.

### Requirements

- macOS 26 or newer, Swift 6 and Apple developer tools.
- For Google Drive: Google Drive for desktop with a signed-in account.
- For Ask AI: an installed and signed-in `claude` (Claude Code) or `codex` (Codex CLI).

## Ask AI

MacJanitor uses an AI CLI already installed on this Mac, with its own login. The app stores no keys.

- **Settings (⌘,)**: choose Claude Code or Codex, the CLI path (auto-detected in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`) and the model. The Claude default is `haiku`.
- The CLI runs with no tools, no MCP and no user settings, in an empty temporary folder. The answer is in the app's language.
- Closing the answer window cancels the request; the limit is 120 s.

> [!NOTE]
> The AI receives only the name, path (home folder replaced with `~`), size and similar metadata. File contents are never sent.

## App removal and leftovers

1. **Check.** If the app is running, the tool offers to quit it; removal is impossible while it runs.
2. **Own uninstaller.** If `Uninstall *.app`, `Remove *.app` or `*Uninstaller.app` sits next to it, you are offered to run it first.
3. **Confirmation** with a list of paths and the total size. Symlinks and aliases are removed as links; the target `.app` they point to is shown on a separate row.
4. **Leftovers** open automatically: a search in `~/Library` (Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, Logs, HTTPStorages, WebKit, LaunchAgents) and system `/Library` by bundle id, name and developer. Each item shows its reason and confidence.

> [!IMPORTANT]
> - System apps, Apple apps and SIP-protected apps are never removed.
> - Only exact bundle id matches are preselected. Shared developer folders where other apps remain, and orphaned data, get a warning and are not preselected.
> - Loaded LaunchAgents are unloaded before removal.
> - System `/Library` items need administrator rights: the app shows them but does not delete them. Remove them manually.

By default everything is moved to Trash. Permanent deletion is a separate option with an extra confirmation.

## Reading sizes

- The figure is the approximate **allocated** space of the chosen folder, not used or free disk space.
- Files and folders under 1 MB are not listed separately but are counted in the parent folder's size.
- Symbolic links are not followed; hard links are counted once.
- "Inaccessible" items have an unknown size and are not added to the total.
- System data, disk snapshots and purgeable space can explain differences from macOS figures.

The scan result is saved in `~/Library/Caches/MacJanitor/storage-scan-v2.plist` and shown with its date on the next launch. A cancelled scan does not replace the saved result.

> [!WARNING]
> Permanent deletion cannot be undone. Cleanup deletes Trash contents permanently. With Google Drive in Mirror mode, moving a file may not free space.

## Command line

After `./bundle.sh` the CLI is available as `.build/release/macjanitor`.

| Command | Purpose |
| --- | --- |
| `port 3000` | Process holding a local port |
| `processes --sort memory --limit 10` | Top processes by memory or CPU |
| `terminate <pid> [--force]` | SIGTERM or SIGKILL a current-user process |
| `storage ~/work --depth 2` | Largest directories |
| `cleanup --dry-run` | Preview cleanup candidates |
| `cleanup --execute --category caches --yes [--permanent]` | Clean selected categories |
| `doctor` | Development environment diagnostics |
| `apps list --sort size` | Installed apps |
| `apps remove <bundle-id\|path> (--yes \| --dry-run) [--permanent]` | Remove an app |
| `apps leftovers <bundle-id\|name>` · `--orphans` | App leftovers or orphaned data |
| `apps leftovers <...> --remove <path…> --yes` | Remove selected leftovers |

Every command has `--help` with examples, limits and exit codes. All commands support `--json`.

**Exit codes:** `0` success, `2` error, refusal or bad arguments; for `port`, `1` means no matches. Incomplete results are not an error by themselves.

**CLI safety:**
- `cleanup` requires `--execute`, an explicit `--category` and `--yes`; `trash` only with `--permanent`; simulators are not cleaned via CLI.
- `apps remove` refuses instead of quitting a running app; it rejects protected apps and anything outside `/Applications` and `~/Applications`.
- `apps leftovers --remove` deletes only paths from a freshly computed list for the same app or `--orphans`; if any path is missing from it, nothing is deleted.
- `terminate` checks the PID and owner right before the signal; success means the signal was sent.

<details>
<summary>JSON fields (schemaVersion 1)</summary>

Standard output is one JSON object with `schemaVersion: 1` and `command`. Errors go to stderr. Unknown values are `null`.

- `port`: `port`, `matches` (`process`, `pid`, `user`, `address`, `state`), `limitations`.
- `processes`: `sort`, `processes` (`name`, `pid`, `user`, `cpuPercent`, `memoryBytes`), `limitations`.
- `storage`: `root`, `depth`, `complete`, `directories` (`path`, `allocatedBytes`, `complete`). `complete: false` means incomplete data; the size is then a lower bound.
- `cleanup`: `dryRun`, `entries` (`category`, `path`, `allocatedBytes`, `status`), `limitations`.
- `doctor`: `macOSVersion`, `volume` (`path`, `availableBytes`, `error`), `developerDirectory` (`path`, `status`), `xcodeVersion`, `tools` (`name`, `path`, `status`), `limitations`.
- `apps list`: `sort`, `applications` (`name`, `bundleId`, `version`, `path`, `sizeBytes`, `lastLaunchDate`, `protected`), `limitations`.
- `apps remove`: `action`, `application`, `dryRun`, `permanent`, `entries` (`path`, `role`, `allocatedBytes`, `status`), `totalBytes`, `runningPids`, `uninstallers`, `limitations`.
- `apps leftovers`: `action`, `query`, `orphans`, `leftovers` (`path`, `allocatedBytes`, `reason`, `confidence`, `preselected`, `sharedWith`, `needsAdmin`, `launchTarget`, `loaded`), `limitations`.

`cleanup` categories: `logs`, `caches`, `brew`, `derived`, `simcache`, `simunavail`, `npm`, `cargo`, `trash`.

</details>

## Development

```bash
swift build
swift test
```

| Target | Contents |
| --- | --- |
| `MacJanitorCore` | Shared logic: processes, ports, scanner, cleanup, apps, leftovers, AI backends |
| `MacJanitor` | SwiftUI app |
| `MacJanitorCLI` | `macjanitor` CLI |
| `MacJanitorTests` | Tests (Swift Testing) on temporary folders, no changes to the real `/Applications` or `~/Library` |
