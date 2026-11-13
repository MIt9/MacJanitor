import Foundation

public struct ProcessListOptions {
    public enum Sort: String { case memory, cpu }
    public let sort: Sort
    public let limit: Int

    public init?(arguments: [String]) {
        var sort: Sort = .memory
        var limit = 10
        var seen = Set<String>()
        var i = 0
        while i < arguments.count {
            let key = arguments[i]
            guard !seen.contains(key), i + 1 < arguments.count else { return nil }
            seen.insert(key)
            switch key {
            case "--sort":
                guard let parsed = Sort(rawValue: arguments[i + 1]) else { return nil }
                sort = parsed
            case "--limit":
                guard let parsed = Int(arguments[i + 1]), (1...10000).contains(parsed) else { return nil }
                limit = parsed
            default: return nil
            }
            i += 2
        }
        self.sort = sort
        self.limit = limit
    }

    public func select(_ processes: [ProcessSample]) -> [ProcessSample] {
        let ordered = processes.sorted {
            switch sort {
            case .memory:
                if $0.memoryAvailable != $1.memoryAvailable { return $0.memoryAvailable }
                if $0.memory != $1.memory { return $0.memory > $1.memory }
            case .cpu:
                if $0.cpuAvailable != $1.cpuAvailable { return $0.cpuAvailable }
                if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            }
            return $0.id < $1.id
        }
        return Array(ordered.prefix(limit))
    }
}
