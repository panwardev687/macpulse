# MacPulse

**A native macOS system utility suite - monitor, clean, and tune your Mac from one app.**

MacPulse combines a real-time system monitor, a safe storage cleaner, a duplicate
finder, an app uninstaller, a startup auditor, and a screenshot organizer into a
single native app with a live menu bar widget. Built entirely in Swift, no
dependencies, compiles with a shell script.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

| Pane | What it does |
|---|---|
| **Dashboard** | CPU / battery / SSD temperature (real sensors, no sudo), thermal pressure, memory + swap, disk free, top memory apps with Quit buttons. Refreshes every 5 s. |
| **Clean Storage** | Reclaims "System Data" bloat: app caches, logs, developer caches (Xcode DerivedData, npm), Trash, iOS backups, Time Machine local snapshots. **Whitelist-only** - it never touches paths it doesn't recognize. |
| **Duplicates & Large Files** | Top-100 largest files with last-opened dates; duplicate detection via size + SHA-256. Finder-style Quick Look: click a file, press Space, arrow through results. |
| **Uninstall Apps** | Drop an app in - finds every leftover by bundle ID (Application Support, Caches, Preferences, Containers, LaunchAgents…). Conservative matching, everything goes to the Trash. |
| **Startup Items** | Audits LaunchAgents/Daemons and login items. Flags **orphans** left by deleted apps. Disabling is reversible - plists move to a `LaunchAgents (Disabled)` folder. |
| **Screenshots** | Auto-files new screenshots/recordings into `~/Pictures/Screenshots/YYYY-MM/`. Waits until captures finish writing; never overwrites. |
| **Menu bar widget** | CPU temperature + memory usage beside the clock, tinted by heat / memory pressure. Customizable: content, color mode (status / custom / monochrome), refresh rate, °C/°F. |

MacPulse stays in the menu bar when you close the window. Deletion flows are
deliberately safety-first: confirmation dialogs everywhere, Trash instead of
hard-delete wherever recoverable, files in use are skipped, never forced.

## Install

**Build from source** (needs Xcode Command Line Tools: `xcode-select --install`):

```sh
git clone https://github.com/panwardev687/macpulse.git
cd macpulse
./build_app.sh
open MacPulse.app
```

The build takes a few seconds - it's one `swiftc` invocation, no Xcode project,
no package manager.

To start MacPulse at login, flip the toggle in **Settings → General** inside the app.

## Permissions

macOS will prompt for these on first use - each is optional and only gates its
own feature:

- **Desktop/Documents/Downloads folder access** - file scanning and screenshot organizing.
- **Automation → System Events** - listing/removing login items in the Startup pane.
- **Full Disk Access** (System Settings → Privacy & Security) - only needed for
  Trash size reporting and iOS backup cleanup in the Clean pane.

MacPulse makes **zero network connections**. No analytics, no telemetry, no
update phone-home. The only outbound links are the buttons in Settings that
open GitHub in your browser.

## How the temperature reading works

Apple Silicon exposes temperature sensors through the IOKit HID event system.
MacPulse reads them directly (`Sensors.swift`) - the same mechanism used by
tools like Stats - which is why it needs no helper daemon and no sudo. This is
a private API: fine for a notarized direct-download app, not eligible for the
Mac App Store.

## Repository layout

```
MacPulseApp/          ← the unified app (start here)
  Main.swift            app shell + sidebar navigation
  StatusBar.swift       menu bar widget + app delegate
  DashboardView.swift   live system overview
  CleanView.swift       storage cleaner
  FilesView.swift       duplicates & large files + Quick Look
  UninstallView.swift   app uninstaller
  StartupView.swift     launch agent auditor
  ShotsView.swift       screenshot organizer engine + settings
  Settings.swift        preferences, launch-at-login, support links
  Sensors.swift         IOKit temperature reading
  MemoryStats.swift     memory pressure / per-app usage
  Shared.swift          common helpers
build_app.sh          ← builds MacPulse.app
scripts/make_icon.swift  regenerates the app icon programmatically
```

The repo also contains the original standalone single-purpose apps
(`TempWidget.swift`, `CleanApp.swift`, `StartupApp.swift`, `UninstallApp.swift`,
`FilesApp.swift`, `ShotsApp.swift`, `MemoryWidget.swift` with matching
`build_*.sh` scripts) and a Python CLI (`macpulse.py`) with SQLite history and a
browser dashboard. The unified app supersedes them, but they're kept as
minimal, readable examples - each is a complete app in one file.

### Python CLI (optional extra)

```sh
./macpulse                   # snapshot: temps, CPU, memory, battery → SQLite
./macpulse watch -i 30       # continuous sampling
./macpulse stats --hours 24  # min/avg/max + hottest moment
./macpulse dashboard         # live charts at http://127.0.0.1:8321
./macpulse why               # "why is my Mac hot?" - heat attribution
```

## Is it safe to clean caches?

Caches, logs, and snapshots are *regenerable by design* - an app that finds its
cache missing rebuilds it. The real performance benefit is keeping 10-15% of
your disk free; macOS slows down measurably when nearly full. Items that are
**not** regenerable (Trash, iOS backups) are labeled `PERMANENT` in the UI,
unchecked by default, and double-confirmed.

## Contributing

Issues and PRs welcome. The codebase is intentionally simple: one view file per
pane, models are plain `ObservableObject`s, helpers live in `Shared.swift`.
Build with `./build_app.sh`, no other tooling required.

## Support

If MacPulse keeps your Mac cool, fast, and tidy, consider
[sponsoring development](https://github.com/sponsors/panwardev687) ♥

## License

[MIT](LICENSE)
