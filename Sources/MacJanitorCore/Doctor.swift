import Foundation
import Darwin

public struct DoctorReport {
    public struct Tool {
        public let name: String
        public let path: String?
        public let status: String
    }
    public let volumePath: String
    public let availableBytes: UInt64?
    public let volumeError: String?
    public let macOSVersion: String
    public let developerDirectory: String?
    public let developerDirectoryStatus: String
    public let xcodeVersion: String?
    public let tools: [Tool]
}

public enum Doctor {
    /// Reads local metadata only; it never launches tools or runs installers.
    public static func inspect(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> DoctorReport {
        let fm = FileManager.default
        var filesystem = statfs()
        let diskOK = statfs(home.path, &filesystem) == 0
        let diskError = diskOK ? nil : String(cString: strerror(errno))
        let available = diskOK ? UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize) : nil

        let override = environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let selection = override ?? (try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
        let developerPath = selection.map { path -> String in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer").path : url.path
        }
        var isDirectory: ObjCBool = false
        let developerValid = developerPath.map { fm.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
        let developer = developerValid ? developerPath : nil
        let status = selection == nil ? "unknown" : (developerValid ? "available" : "unavailable")
        let xcodeBundle = developer.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() }
        let xcodeVersion = xcodeBundle.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

        let paths = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let tools = ["swift", "git", "xcodebuild", "clang"].map { name -> DoctorReport.Tool in
            let path = paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first { fm.isExecutableFile(atPath: $0) }
            let toolStatus: String
            if path == nil { toolStatus = "not_found" }
            else if path == "/usr/bin/\(name)" { toolStatus = "system_shim_unverified" }
            else { toolStatus = "executable_unverified" }
            return DoctorReport.Tool(name: name, path: path, status: toolStatus)
        }
        return DoctorReport(volumePath: home.path, availableBytes: available, volumeError: diskError,
                            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            developerDirectory: developer, developerDirectoryStatus: status,
                            xcodeVersion: xcodeVersion, tools: tools)
    }
}
