// Noodle - A macOS menu bar app for managing Node.js processes
// Copyright (c) 2024 Filip Olszak
// Licensed under the MIT License

import Cocoa
import SwiftUI

// MARK: - Models

/// Represents a Node.js process with its metadata
struct NodeProcess: Identifiable {
    let id: Int
    let pid: Int
    let name: String
    let project: String
    let projectPath: String
    let port: Int?
    let cpu: Double
    let memory: Double
    let command: String
    let startTime: Date?
    let isRunning: Bool
}

/// Persisted process info for restart capability
struct SavedProcess: Codable, Identifiable {
    var id: String { "\(projectPath):\(command)" }
    let projectPath: String
    let project: String
    let name: String
    let command: String
    var lastSeen: Date
}

// MARK: - Process Manager

/// Manages Node.js process discovery, monitoring, and control
final class ProcessManager: ObservableObject {
    @Published var processes: [NodeProcess] = []

    private var savedProcesses: [String: SavedProcess] = [:]
    private let savedProcessesKey = "savedProcesses"
    private let retentionDays = 7

    init() {
        loadSavedProcesses()
    }

    // MARK: - Persistence

    private func loadSavedProcesses() {
        if let data = UserDefaults.standard.data(forKey: savedProcessesKey),
           let decoded = try? JSONDecoder().decode([String: SavedProcess].self, from: data) {
            savedProcesses = decoded
        }
    }

    private func saveSavedProcesses() {
        if let encoded = try? JSONEncoder().encode(savedProcesses) {
            UserDefaults.standard.set(encoded, forKey: savedProcessesKey)
        }
    }

    // MARK: - Process Discovery

    func refresh() {
        let runningProcesses = discoverRunningProcesses()

        // Update saved processes with running ones
        for proc in runningProcesses {
            let key = "\(proc.projectPath):\(proc.command)"
            savedProcesses[key] = SavedProcess(
                projectPath: proc.projectPath,
                project: proc.project,
                name: proc.name,
                command: proc.command,
                lastSeen: Date()
            )
        }
        saveSavedProcesses()

        // Build combined list: running + recently stopped
        var combined: [NodeProcess] = runningProcesses
        let runningKeys = Set(runningProcesses.map { "\($0.projectPath):\($0.command)" })
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)

        for (key, saved) in savedProcesses {
            if !runningKeys.contains(key) && saved.lastSeen > cutoff {
                combined.append(NodeProcess(
                    id: key.hashValue,
                    pid: 0,
                    name: saved.name,
                    project: saved.project,
                    projectPath: saved.projectPath,
                    port: nil,
                    cpu: 0,
                    memory: 0,
                    command: saved.command,
                    startTime: nil,
                    isRunning: false
                ))
            }
        }

        // Sort: running first, then alphabetically by project
        processes = combined.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.project.lowercased() < $1.project.lowercased()
        }
    }

    private func discoverRunningProcesses() -> [NodeProcess] {
        var results: [NodeProcess] = []

        let output = shell("ps -eo pid,pcpu,pmem,etime,comm,command | awk '$5 == \"node\" || $5 == \"npm\" || $5 == \"npx\" {print}'")
        let ports = discoverListeningPorts()

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }

            let etime = String(parts[3])
            let comm = String(parts[4])
            let fullCommand = String(parts[5])

            // Skip self
            if fullCommand.contains("Noodle") { continue }

            let projectPath = getWorkingDirectory(pid: pid)
            let project = projectPath.components(separatedBy: "/").last ?? "unknown"

            results.append(NodeProcess(
                id: pid,
                pid: pid,
                name: extractScriptName(comm: comm, command: fullCommand),
                project: project,
                projectPath: projectPath,
                port: ports[pid],
                cpu: cpu,
                memory: mem,
                command: fullCommand,
                startTime: parseElapsedTime(etime),
                isRunning: true
            ))
        }

        return results
    }

    private func discoverListeningPorts() -> [Int: Int] {
        var ports: [Int: Int] = [:]
        let output = shell("lsof -i -P -n 2>/dev/null | grep LISTEN | grep node")

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int(parts[1]) else { continue }

            for part in parts {
                let s = String(part)
                if s.contains(":") && !s.contains("LISTEN"),
                   let colonIdx = s.lastIndex(of: ":") {
                    let portStr = String(s[s.index(after: colonIdx)...])
                    if let port = Int(portStr), port > 0 && port < 65536, ports[pid] == nil {
                        ports[pid] = port
                    }
                }
            }
        }

        return ports
    }

    private func getWorkingDirectory(pid: Int) -> String {
        let output = shell("lsof -p \(pid) 2>/dev/null | grep cwd | awk '{print $NF}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "/unknown" : output
    }

    private func parseElapsedTime(_ etime: String) -> Date? {
        var totalSeconds = 0
        var timePart = etime

        // Handle days (format: dd-hh:mm:ss)
        if let dashIdx = etime.firstIndex(of: "-") {
            if let days = Int(etime[..<dashIdx]) {
                totalSeconds += days * 86400
            }
            timePart = String(etime[etime.index(after: dashIdx)...])
        }

        let components = timePart.components(separatedBy: ":")
        switch components.count {
        case 3: // hh:mm:ss
            totalSeconds += (Int(components[0]) ?? 0) * 3600
            totalSeconds += (Int(components[1]) ?? 0) * 60
            totalSeconds += Int(components[2]) ?? 0
        case 2: // mm:ss
            totalSeconds += (Int(components[0]) ?? 0) * 60
            totalSeconds += Int(components[1]) ?? 0
        default:
            break
        }

        return Date().addingTimeInterval(-Double(totalSeconds))
    }

    private func extractScriptName(comm: String, command: String) -> String {
        let cmd = command.lowercased()

        // npm scripts
        if cmd.contains("npm run "),
           let range = command.range(of: #"npm run (\S+)"#, options: .regularExpression) {
            return String(command[range]).replacingOccurrences(of: "npm run ", with: "")
        }
        if cmd.contains("npm start") { return "start" }
        if cmd.contains("npm exec ") { return "exec" }

        // Common frameworks
        let frameworks: [(String, String)] = [
            ("next dev", "next dev"), ("next start", "next"),
            ("vite", "vite"), ("webpack", "webpack"),
            ("esbuild", "esbuild"), ("turbo", "turbo"),
            ("tsc", "tsc"), ("jest", "jest"), ("vitest", "vitest")
        ]
        for (pattern, name) in frameworks {
            if cmd.contains(pattern) { return name }
        }

        // Extract from node command
        if comm == "node" {
            if let range = command.range(of: #"([^\s/]+\.m?js)"#, options: .regularExpression) {
                return String(command[range])
            }
            if let range = command.range(of: #"/\.bin/([^\s]+)"#, options: .regularExpression) {
                return String(command[range]).replacingOccurrences(of: "/.bin/", with: "")
            }
        }

        return comm
    }

    // MARK: - Process Control

    func stop(_ process: NodeProcess) {
        guard process.isRunning else { return }
        kill(pid_t(process.pid), SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func forceKill(_ process: NodeProcess) {
        guard process.isRunning else { return }
        kill(pid_t(process.pid), SIGKILL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func stopAll() {
        for p in processes where p.isRunning {
            kill(pid_t(p.pid), SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refresh() }
    }

    func start(_ process: NodeProcess) {
        let cmd = inferStartCommand(from: process.command)
        let escaped = process.projectPath.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\" && \(cmd)"
            end tell
            """

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refresh() }
    }

    private func inferStartCommand(from fullCommand: String) -> String {
        let cmd = fullCommand.lowercased()

        // Direct npm commands
        if cmd.contains("npm run "),
           let range = fullCommand.range(of: #"npm run \S+"#, options: .regularExpression) {
            return String(fullCommand[range])
        }
        if cmd.contains("npm start") { return "npm start" }

        // Package managers
        if cmd.contains("yarn") { return "yarn start" }
        if cmd.contains("pnpm") { return "pnpm start" }

        // Framework detection -> npm run dev
        let devFrameworks = ["next dev", "vite", "webpack serve", "nuxt dev", "astro dev", "remix dev", "turbo"]
        for framework in devFrameworks {
            if cmd.contains(framework) { return "npm run dev" }
        }

        if cmd.contains("react-scripts start") { return "npm start" }
        if cmd.contains("vue-cli-service serve") { return "npm run serve" }

        return "npm start"
    }

    func forget(_ process: NodeProcess) {
        let key = "\(process.projectPath):\(process.command)"
        savedProcesses.removeValue(forKey: key)
        saveSavedProcesses()
        refresh()
    }

    // MARK: - Helpers

    private func shell(_ command: String) -> String {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - Formatters

func formatUptime(_ date: Date?) -> String {
    guard let date = date else { return "-" }
    let elapsed = Date().timeIntervalSince(date)

    switch elapsed {
    case ..<60:
        return "\(Int(elapsed))s"
    case ..<3600:
        return "\(Int(elapsed / 60))m"
    case ..<86400:
        return "\(Int(elapsed / 3600))h \(Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60))m"
    default:
        return "\(Int(elapsed / 86400))d \(Int((elapsed.truncatingRemainder(dividingBy: 86400)) / 3600))h"
    }
}

// MARK: - SwiftUI Components

struct MiniBar: View {
    let value: Double
    let maxValue: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * min(value / maxValue, 1.0)))
            }
        }
        .frame(width: 20, height: 6)
    }
}

struct EnergyBadge: View {
    let cpu: Double
    let memory: Double

    private var level: (label: String, icon: String, color: Color) {
        if cpu > 25 || memory > 12 {
            return ("High", "bolt.trianglebadge.exclamationmark", .orange)
        } else if cpu > 8 || memory > 5 {
            return ("Med", "bolt", .yellow)
        } else {
            return ("Low", "bolt.badge.checkmark", .green)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: level.icon)
                .font(.system(size: 9))
            Text(level.label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(level.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(level.color.opacity(0.15))
        .cornerRadius(4)
    }
}

struct ProcessRow: View {
    let process: NodeProcess
    let onStop: () -> Void
    let onKill: () -> Void
    let onStart: () -> Void
    let onForget: () -> Void
    let onCopyPid: () -> Void
    let onCopyCommand: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Project, Script, Actions
            HStack(alignment: .firstTextBaseline) {
                Text(process.project)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(process.isRunning ? .primary : .secondary)
                    .lineLimit(1)

                Text(process.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                if !process.isRunning {
                    Button(action: onStart) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Start")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    if process.isRunning {
                        Button(action: onStop) {
                            Label("Stop (SIGTERM)", systemImage: "stop.fill")
                        }
                        Button(action: onKill) {
                            Label("Force Kill (SIGKILL)", systemImage: "xmark.circle.fill")
                        }
                        Divider()
                        Button(action: onCopyPid) {
                            Label("Copy PID", systemImage: "doc.on.doc")
                        }
                    } else {
                        Button(action: onStart) {
                            Label("Start", systemImage: "play.fill")
                        }
                        Divider()
                        Button(action: onForget) {
                            Label("Remove from list", systemImage: "trash")
                        }
                    }
                    Button(action: onCopyCommand) {
                        Label("Copy Command", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundColor(isHovered ? .primary : .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // Row 2: Stats
            HStack(spacing: 10) {
                if process.isRunning {
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(formatUptime(process.startTime))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.secondary)

                    if let port = process.port {
                        HStack(spacing: 2) {
                            Image(systemName: "network")
                                .font(.system(size: 9))
                            Text(":\(port)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundColor(.blue)
                    }

                    Spacer()

                    HStack(spacing: 3) {
                        MiniBar(value: process.cpu, maxValue: 100, color: process.cpu > 30 ? .orange : .blue)
                        Text(String(format: "%.0f%%", process.cpu))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(process.cpu > 30 ? .orange : .secondary)
                    .frame(width: 45)

                    HStack(spacing: 3) {
                        MiniBar(value: process.memory, maxValue: 20, color: process.memory > 10 ? .orange : .purple)
                        Text(String(format: "%.0f%%", process.memory))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(process.memory > 10 ? .orange : .secondary)
                    .frame(width: 45)

                    EnergyBadge(cpu: process.cpu, memory: process.memory)
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 9))
                        Text("Stopped")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            isHovered
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3)
                : (process.isRunning ? Color.clear : Color(nsColor: .separatorColor).opacity(0.08))
        )
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }
}

struct ContentView: View {
    @ObservedObject var manager: ProcessManager
    let onQuit: () -> Void

    private var runningCount: Int {
        manager.processes.filter(\.isRunning).count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Noodle")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(runningCount) running")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if manager.processes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                    Text("No Node processes")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(manager.processes) { process in
                            ProcessRow(
                                process: process,
                                onStop: { manager.stop(process) },
                                onKill: { manager.forceKill(process) },
                                onStart: { manager.start(process) },
                                onForget: { manager.forget(process) },
                                onCopyPid: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(process.pid)", forType: .string)
                                },
                                onCopyCommand: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(process.command, forType: .string)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Footer
            HStack(spacing: 16) {
                Button(action: { manager.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")

                if runningCount > 0 {
                    Button(action: { manager.stopAll() }) {
                        Label("Stop All", systemImage: "stop.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let manager = ProcessManager()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()

        manager.refresh()
        updateStatusIcon()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.manager.refresh()
            self?.updateStatusIcon()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "n.circle.fill", accessibilityDescription: "Noodle")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func setupPanel() {
        let contentView = ContentView(manager: manager, onQuit: {
            NSApplication.shared.terminate(nil)
        })

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: contentView)
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let count = manager.processes.filter(\.isRunning).count
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            manager.refresh()
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)

        let x = screenRect.midX - panel.frame.width / 2
        let y = screenRect.minY - panel.frame.height - 5

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
