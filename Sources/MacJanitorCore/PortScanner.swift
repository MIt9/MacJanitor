import Foundation

public struct PortRow: Identifiable, Sendable {
    public let id: String
    public let process: String
    public let pid: String
    public let user: String
    public let address: String
    public let state: String

    public var localPort: Int? {
        let local = address.components(separatedBy: "->").first ?? ""
        guard let port = local.split(separator: ":").last else { return nil }
        return Int(port)
    }
}

public enum PortScanner {
    public static func parse(_ output: String) -> [PortRow] {
        var process = "", pid = "", user = "", address = "", proto = "", state = ""
        var rows: [PortRow] = []
        func appendRow() {
            guard !address.isEmpty else { return }
            let id = "\(pid)|\(proto)|\(address)|\(state)"
            rows.append(PortRow(id: id, process: process, pid: pid, user: user, address: "\(proto) \(address)", state: state))
        }
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": appendRow(); address = ""; proto = ""; state = ""; pid = value
            case "c": process = value
            case "L": user = value
            case "f": appendRow(); address = ""; proto = ""; state = ""
            case "P": proto = value
            case "n": address = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        appendRow()
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
    }

    public static func scan(port: Int? = nil) throws -> [PortRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        let suffix = port.map { ":\($0)" } ?? ""
        process.arguments = ["-nP", "-iTCP\(suffix)", "-sTCP:LISTEN", "-iUDP\(suffix)", "-FpcLfPnT"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw CocoaError(.fileReadUnknown)
        }
        return parse(String(decoding: data, as: UTF8.self))
    }
}

