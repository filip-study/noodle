# Noodle

A lightweight macOS menu bar app for monitoring and managing Node.js processes.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Monitor** all running Node.js, npm, and npx processes
- **View details** including project name, script, port, CPU, memory, and uptime
- **Energy indicator** showing Low/Med/High resource usage
- **Stop/Kill** processes with SIGTERM or SIGKILL
- **Remember** recently run processes and restart them with one click
- **Auto-refresh** every 5 seconds

## Screenshot

The app lives in your menu bar and shows the number of running Node processes. Click to open the panel:

```
┌─────────────────────────────────────────┐
│ Noodle                        2 running │
├─────────────────────────────────────────┤
│ my-project        next dev         ⋯   │
│ ⏱ 2h 15m  :3000    ▂ 2%  ▂ 1%  ⚡ Low  │
├─────────────────────────────────────────┤
│ api-server        start            ⋯   │
│ ⏱ 45m     :8080    ▂ 5%  ▂ 3%  ⚡ Low  │
├─────────────────────────────────────────┤
│ old-project       vite      [Start] ⋯  │
│ 🌙 Stopped                              │
└─────────────────────────────────────────┘
```

## Installation

### Download Release

1. Download the latest `Noodle-vX.X.X.zip` from [Releases](../../releases)
2. Unzip and move `Noodle.app` to your Applications folder
3. Open Terminal and run:
   ```bash
   xattr -cr /Applications/Noodle.app
   ```
4. Launch Noodle

> **Note:** The `xattr` command is needed because the app isn't signed with an Apple Developer certificate. macOS quarantines unsigned apps downloaded from the internet.

### Build from Source

Requires macOS 13+ and Xcode Command Line Tools.

```bash
git clone https://github.com/yourusername/noodle.git
cd noodle
./build.sh
```

Then move `Noodle.app` to your Applications folder.

## Usage

1. Launch Noodle - it will appear in your menu bar
2. Click the icon to see all running Node processes
3. Use the action menu (⋯) on each process to:
   - Stop (SIGTERM) or Force Kill (SIGKILL)
   - Copy PID or full command
4. Stopped processes are remembered for 7 days and can be restarted
5. Press ⌘R to refresh, ⌘Q to quit

## Permissions

On first run, macOS may ask for permissions:

- **Accessibility**: Not required
- **Automation (Terminal)**: Required only if you want to use the "Start" feature to restart stopped processes

## How It Works

Noodle uses system commands to discover Node processes:

- `ps` - List running processes with CPU/memory stats
- `lsof` - Find listening ports and working directories

No background daemons, no elevated privileges, no network access.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Issues and pull requests welcome!
