import Foundation
import MacJanitorCore
import Darwin



func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
let jsonCount = args.filter { $0 == "--json" }.count
guard jsonCount <= 1 else { fail("Option --json may be specified only once.", code: 2) }
let json = jsonCount == 1
args.removeAll { $0 == "--json" }
func writeJSON(_ object: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch { fail("Could not encode JSON: \(error.localizedDescription)", code: 2) }
}
let usage = "Usage: macjanitor <port|processes|terminate|storage|cleanup|doctor|apps> [options]\nRun 'macjanitor --help' or 'macjanitor <command> --help' for details."
let commandHelp: [String: String] = [
    "port": """
    Usage: macjanitor port <1-65535> [--json]

    Find processes with a visible listening TCP port or UDP socket on the local port.
    Socket visibility depends on current permissions; no match does not prove the port is free.

    Examples:
      macjanitor port 3000
      macjanitor port 8080 --json

    Exit status: 0 = found, 1 = no visible match, 2 = invalid arguments or error.
    """,
    "processes": """
    Usage: macjanitor processes [--sort memory|cpu] [--limit N] [--json]

    List processes ordered by physical memory footprint or CPU usage.
      --sort memory|cpu  Sort by memory (default) or CPU.
      --limit N          Maximum number of rows, 1–10000 (default: 10).
    CPU sorting samples twice, one second apart; 100% is one CPU core. CPU is not
    measured for memory sorting. Inaccessible measurements are unknown (JSON null),
    and some processes may be omitted because of permissions or process exit.

    Examples:
      macjanitor processes --sort memory --limit 10
      macjanitor processes --sort cpu --limit 5 --json

    Exit status: 0 = report generated, 2 = invalid arguments or error.
    """,
    "storage": """
    Usage: macjanitor storage <directory> [--depth N] [--json]

    Scan a directory and list its largest directories by allocated bytes.
      --depth N  Output depth from the root, 0–100 (default: 1).
    The entire tree is scanned regardless of output depth. Symbolic links are not
    followed; hard-linked files are counted once. Inaccessible or vanished items
    make results incomplete; incomplete sizes are lower estimates, not free space.

    Examples:
      macjanitor storage ~/work --depth 2
      macjanitor storage ~/Downloads --depth 1 --json

    Exit status: 0 = report generated (including incomplete results), 2 = error.
    """,
    "terminate": """
    Usage: macjanitor terminate <PID> [--force] [--json]

    Send SIGTERM to a process owned by the current user. --force sends SIGKILL.
    PID must be greater than 1 and cannot be the CLI process. Owner and process
    identity are rechecked before signaling; a PID can still be reused in the
    small interval before the signal. Success means the signal was sent, not
    that the process has exited.

    Examples:
      macjanitor terminate 12345
      macjanitor terminate 12345 --force --json
    Exit status: 0 = signal sent, 2 = invalid arguments or error.
    """,
    "cleanup": """
    Usage: macjanitor cleanup --dry-run [--category ID ...] [--json]
           macjanitor cleanup --execute --category ID [--category ID ...] --yes [--permanent] [--json]

    Preview cleanup candidates and approximate allocated sizes; no files are removed.
      --dry-run       Perform a read-only preview.
      --execute       Apply the explicitly selected categories.
      --yes           Confirm execution; required with --execute.
      --permanent     Delete permanently instead of moving to Trash; irreversible.
      --category ID   Select a category; repeat to select several. Without this
                      option all categories are listed only for --dry-run.
    Category IDs: logs, caches, brew, derived, simcache, simunavail, npm, cargo, trash.
    Unavailable and protected items are marked. Simulator size cannot be estimated;
    hard links may make separate estimates overlap. The trash category requires
    --permanent for execution. Simulator cleanup is unsupported and skipped.

    Examples:
      macjanitor cleanup --dry-run
      macjanitor cleanup --dry-run --category caches --category brew --json
      macjanitor cleanup --execute --category caches --yes

    Exit status: 0 = report generated, 2 = invalid arguments, skipped entries or error.
    """,
    "doctor": """
    Usage: macjanitor doctor [--json]

    Report macOS version, free space on the home filesystem, selected Apple developer
    directory, Xcode version if available, and swift/git/xcodebuild/clang paths.
    Tool paths are not executed or validated; a system shim may require developer
    tools. Unknown values remain unknown. The report is local and read-only.

    Examples:
      macjanitor doctor
      macjanitor doctor --json

    Exit status: 0 = report generated even if some values are unknown, 2 = error.
    """,
    "apps": """
    Usage: macjanitor apps list [--json]

    List installed applications from /Applications and ~/Applications with name, bundle identifier, version, size and last launch date.

    Examples:
      macjanitor apps list
      macjanitor apps list --json

    Exit status: 0 = report generated, 2 = invalid arguments or error.
    """
]
let generalHelp = """
MacJanitor — inspect processes, ports and storage on macOS.

\(usage)

Commands:
  port       Find a process using a local port.
  processes  List processes by memory or CPU usage.
  terminate  Send a signal to a current-user process.
  storage    Report largest directories within a chosen path.
  cleanup    Preview or explicitly clean selected categories.
  doctor     Inspect the local development environment.
  apps       List installed applications.

Options:
  -h, --help  Show this help; use <command> --help for details.
  --json      Output a JSON object with schemaVersion 1; errors go to stderr.

Exit status: 0 = success; 1 = no visible port match; 2 = error or invalid arguments.
Results may be incomplete where macOS denies access.

Examples:
  macjanitor port 3000
  macjanitor storage ~/work --depth 2 --json
  macjanitor cleanup --help
"""
let helpText: String? = {
    if args == ["--help"] || args == ["-h"] { return generalHelp }
    if args.count == 2 && (args[1] == "--help" || args[1] == "-h") { return commandHelp[args[0]] }
    return nil
}()
if let helpText {
    if json { writeJSON(["schemaVersion": 1, "command": "help", "usage": helpText]); exit(0) }
    print(helpText)
    exit(0)
}
if args.first == "doctor" {
    guard args == ["doctor"] else { fail(usage, code: 2) }
    let report = Doctor.inspect(home: FileManager.default.homeDirectoryForCurrentUser)
    if json {
        let tools: [[String: Any]] = report.tools.map { ["name": $0.name, "path": $0.path as Any? ?? NSNull(), "status": $0.status] }
        writeJSON(["schemaVersion": 1, "command": "doctor", "macOSVersion": report.macOSVersion,
                   "volume": ["path": report.volumePath, "availableBytes": report.availableBytes as Any? ?? NSNull(), "error": report.volumeError as Any? ?? NSNull()],
                   "developerDirectory": ["path": report.developerDirectory as Any? ?? NSNull(), "status": report.developerDirectoryStatus],
                   "xcodeVersion": report.xcodeVersion as Any? ?? NSNull(), "tools": tools,
                   "limitations": ["Tool paths are not executed or validated; system shims may require developer tools.", "Available space is a point-in-time filesystem estimate."]])
    } else {
        print("macOS: \(report.macOSVersion)")
        print("Available space (\(report.volumePath)): \(report.availableBytes.map(String.init) ?? "unknown") bytes")
        if let error = report.volumeError { print("Volume error: \(error)") }
        print("Developer directory: \(report.developerDirectory ?? "unknown") (\(report.developerDirectoryStatus))")
        print("Xcode version: \(report.xcodeVersion ?? "unknown")")
        for tool in report.tools { print("\(tool.name): \(tool.path ?? "not found") (\(tool.status))") }
        print("Tool paths are not executed or validated; system shims may require developer tools.")
    }
    exit(0)
}
if args.first == "processes" {
    if args == ["processes", "--help"] { print(usage); exit(0) }
    guard let options = ProcessListOptions(arguments: Array(args.dropFirst())) else { fail(usage, code: 2) }
    let monitor = ProcessMonitor()
    if options.sort == .cpu {
        _ = monitor.sample()
        if monitor.enumerationFailed { fail("Could not enumerate processes.", code: 2) }
        try? await Task.sleep(for: .seconds(1))
    }
    let processes = options.select(monitor.sample())
    if monitor.enumerationFailed { fail("Could not enumerate processes.", code: 2) }
    if json {
        writeJSON(["schemaVersion": 1, "command": "processes", "sort": options.sort == .cpu ? "cpu" : "memory", "processes": processes.map { ["name": $0.name, "pid": $0.id, "user": $0.user, "cpuPercent": $0.cpuAvailable ? $0.cpu as Any : NSNull(), "memoryBytes": $0.memoryAvailable ? $0.memory as Any : NSNull()] as [String: Any] }, "limitations": ["Some processes may be omitted due to access restrictions or process exit.", "CPU is unavailable without two valid samples; resource values may be unavailable."]])
        exit(0)
    }
    print("PROCESS\tPID\tUSER\tCPU %\tMEMORY BYTES")
    for process in processes {
        let cpu = process.cpuAvailable ? String(format: "%.1f", process.cpu) : "unknown"
        let memory = process.memoryAvailable ? String(process.memory) : "unknown"
        print("\(process.name)\t\(process.id)\t\(process.user)\t\(cpu)\t\(memory)")
    }
    FileHandle.standardError.write(Data("Note: some processes may be omitted due to access restrictions or process exit; unknown values could not be measured. CPU requires two samples.\n".utf8))
    exit(0)
}
if args.first == "terminate" {
    let options = Array(args.dropFirst())
    guard (1...2).contains(options.count), let pid = pid_t(options[0]),
          options.count == 1 || options[1] == "--force" else { fail(usage, code: 2) }
    let force = options.count == 2
    do {
        try ProcessAction.send(pid: pid, force: force)
        if json { writeJSON(["schemaVersion": 1, "command": "terminate", "pid": pid, "signal": force ? "SIGKILL" : "SIGTERM", "sent": true]) }
        else { print("Sent \(force ? "SIGKILL" : "SIGTERM") to PID \(pid).") }
        exit(0)
    } catch { fail("Could not signal process: \(error.localizedDescription)", code: 2) }
}
if args.first == "storage" {
    if args == ["storage", "--help"] { print(usage); exit(0) }
    guard let options = StorageReportOptions(arguments: Array(args.dropFirst())) else { fail(usage, code: 2) }
    let root = URL(fileURLWithPath: NSString(string: options.path).expandingTildeInPath).standardizedFileURL
    var info = stat()
    guard lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
        fail("Storage path must be an existing directory (not a symbolic link).", code: 2)
    }
    do {
        let tree = try await StorageScanner().scan(root)
        guard !tree.inaccessible else { fail("Cannot read the selected directory.", code: 2) }
        let results = StorageReport.directories(tree, depth: options.depth)
        if json {
            writeJSON(["schemaVersion": 1, "command": "storage", "root": root.path, "depth": options.depth, "complete": !results.contains(where: \.incomplete), "directories": results.map { ["path": $0.node.url.path, "allocatedBytes": $0.node.inaccessible ? NSNull() : $0.node.size as Any, "complete": !$0.incomplete] as [String: Any] }])
            exit(0)
        }
        print("ALLOCATED BYTES\tSTATUS\tDIRECTORY")
        for result in results { print("\(result.node.inaccessible ? "unknown" : String(result.node.size))\t\(result.incomplete ? "incomplete" : "complete")\t\(result.node.url.path)") }
        if results.contains(where: \.incomplete) {
            FileHandle.standardError.write(Data("Warning: inaccessible or vanished items make some sizes incomplete.\n".utf8))
        }
        exit(0)
    } catch { fail("Could not scan directory: \(error.localizedDescription)", code: 2) }
}
if args.first == "cleanup" {
    if args == ["cleanup", "--help"] { print(usage); exit(0) }
    let options = Array(args.dropFirst())
    guard let mode = options.first, mode == "--dry-run" || mode == "--execute" else { fail(usage, code: 2) }
    let available = Set(CleanupCatalog.categories(home: FileManager.default.homeDirectoryForCurrentUser).map(\.id))
    var ids = Set<String>()
    var yes = false
    var permanent = false
    var index = 1
    while index < options.count {
        if mode == "--execute" && options[index] == "--yes" && !yes { yes = true; index += 1; continue }
        if mode == "--execute" && options[index] == "--permanent" && !permanent { permanent = true; index += 1; continue }
        guard options[index] == "--category", index + 1 < options.count, available.contains(options[index + 1]) else {
            fail("Invalid cleanup category or arguments. Available categories: \(available.sorted().joined(separator: ", "))", code: 2)
        }
        ids.insert(options[index + 1])
        index += 2
    }
    if mode == "--execute" {
        guard yes, !ids.isEmpty else { fail("Cleanup requires --yes and at least one explicit --category.", code: 2) }
        guard !ids.contains("trash") || permanent else { fail("Cleaning Trash requires --permanent; its contents cannot be moved to Trash.", code: 2) }
        guard !ids.contains("simunavail") else { fail("Simulator cleanup is unsupported by this command.", code: 2) }
        let rows = CleanupAction.execute(home: FileManager.default.homeDirectoryForCurrentUser, categoryIDs: ids, permanent: permanent)
        let failed = rows.contains { $0.status != "deleted" && $0.status != "trashed" }
        if json {
            writeJSON(["schemaVersion": 1, "command": "cleanup", "dryRun": false, "permanent": permanent, "entries": rows.map { ["category": $0.category, "path": $0.path.path, "status": $0.status] }])
        } else {
            print("CATEGORY\tSTATUS\tPATH")
            for row in rows { print("\(row.category)\t\(row.status)\t\(row.path.path)") }
        }
        exit(failed ? 2 : 0)
    }
    if ids.isEmpty { ids = available }
    do {
        let rows = try await CleanupPreview.scan(home: FileManager.default.homeDirectoryForCurrentUser, categoryIDs: ids)
        if json {
            let entries: [[String: Any]] = rows.map { row in
                ["category": row.category, "path": row.path.path, "allocatedBytes": row.size.map { $0 as Any } ?? NSNull(), "status": row.status]
            }
            writeJSON(["schemaVersion": 1, "command": "cleanup", "dryRun": true, "entries": entries, "limitations": ["Sizes are estimates and may overlap for hard links."]])
            exit(0)
        }
        print("CATEGORY\tALLOCATED BYTES\tSTATUS\tPATH")
        for row in rows { print("\(row.category)\t\(row.size.map(String.init) ?? "unknown")\t\(row.status)\t\(row.path.path)") }
        print("Dry run only; no files were removed. Sizes are estimates and may overlap for hard links.")
        exit(0)
    } catch { fail("Could not preview cleanup: \(error.localizedDescription)", code: 2) }
}
if args.first == "apps" {
    let rest = Array(args.dropFirst())
    if rest.first == "--help" || rest.first == "-h" { print(commandHelp["apps"] ?? usage); exit(0) }
    guard rest.first == "list" else { fail(usage, code: 2) }
    let options = Array(rest.dropFirst())
    if options == ["--help"] || options == ["-h"] { print(commandHelp["apps"] ?? usage); exit(0) }
    guard options.isEmpty || options == ["--json"] else { fail(usage, code: 2) }
    let installedApps = InstalledApps.applications(home: FileManager.default.homeDirectoryForCurrentUser)
    if json {
        let applications: [[String: Any]] = installedApps.map { app in
            ["name": app.name, "bundleId": app.bundleIdentifier ?? NSNull(), "version": app.version ?? NSNull(), "sizeBytes": app.sizeBytes ?? NSNull(), "lastLaunchDate": app.lastLaunchDate.map { (ISO8601DateFormatter()).string(from: $0) } ?? NSNull()] as [String: Any]
        }
        writeJSON(["schemaVersion": 1, "command": "apps", "applications": applications, "limitations": ["Application sizes are estimates from the bundle contents.", "Last launch dates are unknown for applications that are not running."]])
        exit(0)
    }
    print("NAME\tBUNDLE ID\tVERSION\tSIZE\tLAST LAUNCH")
    for app in installedApps {
        let lastLaunch = app.lastLaunchDate.map { (ISO8601DateFormatter()).string(from: $0) } ?? "unknown"
        print("\(app.name)\t\(app.bundleIdentifier ?? "unknown")\t\(app.version ?? "unknown")\t\(app.sizeBytes.map { String($0) } ?? "unknown")\t\(lastLaunch)")
    }
    exit(0)
}
guard args.count == 2, args[0] == "port", let port = Int(args[1]), (1...65535).contains(port) else {
    fail(usage, code: 2)
}
do {
    let matches = try PortScanner.scan(port: port).filter { $0.localPort == port }
    if json {
        writeJSON(["schemaVersion": 1, "command": "port", "port": port, "matches": matches.map { ["process": $0.process, "pid": Int($0.pid).map { $0 as Any } ?? NSNull(), "user": $0.user, "address": $0.address, "state": $0.state] as [String: Any] }, "limitations": ["Only sockets visible with current permissions are included; no match does not prove the port is free."]])
        exit(matches.isEmpty ? 1 : 0)
    }
    if matches.isEmpty {
        FileHandle.standardError.write(Data("Note: socket visibility is limited by current permissions; absence does not prove that the port is free.\n".utf8))
        print("No visible listening TCP or UDP socket found for port \(port).")
        exit(1)
    }
    print("PROCESS\tPID\tUSER\tADDRESS\tSTATE")
    for row in matches { print("\(row.process)\t\(row.pid)\t\(row.user)\t\(row.address)\t\(row.state)") }
    FileHandle.standardError.write(Data("Note: only sockets visible with current permissions are shown; other sockets may be omitted.\n".utf8))
} catch {
    fail("Could not inspect ports: \(error.localizedDescription)", code: 2)
}
