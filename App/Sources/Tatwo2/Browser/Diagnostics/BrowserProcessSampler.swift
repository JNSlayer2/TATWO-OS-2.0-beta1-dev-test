import Foundation
import Darwin

enum BrowserHelperRole: String, Sendable {
    case renderer, gpu, network, utility, other

    static func classify(arguments: [String]) -> Self {
        func value(_ key: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument.hasPrefix(key + "=") { return String(argument.dropFirst(key.count + 1)).lowercased() }
                if argument == key, index + 1 < arguments.count { return arguments[index + 1].lowercased() }
            }
            return nil
        }
        switch value("--type") {
        case "renderer": return .renderer
        case "gpu-process": return .gpu
        case "utility":
            return value("--utility-sub-type")?.contains("networkservice") == true ? .network : .utility
        default: return .other
        }
    }
}

struct BrowserProcessSample: Identifiable, Sendable {
    let pid: pid_t
    let role: String
    /// Physical footprint, as requested by D-B6; nil is unreadable/exited, never a fake zero.
    let footprintBytes: UInt64?
    let isHelper: Bool
    var residentBytes: UInt64? = nil
    var id: pid_t { pid }
    var megabytes: Double? { footprintBytes.map { Double($0) / 1_048_576 } }
}

enum BrowserProcessSampler {
    /// Bounded descendant traversal, scoped to this App's helper bundle tree.
    /// Arguments are used transiently to classify a role and are never retained.
    static func sample(rootPID: pid_t = getpid(), helperRoot: String?) -> [BrowserProcessSample] {
        var result = [row(pid: rootPID, role: "main", isHelper: false)]
        guard let helperRoot else { return result }
        let canonicalRoot = URL(fileURLWithPath: helperRoot).resolvingSymlinksInPath().path
        var pending = [rootPID]
        var visited: Set<pid_t> = [rootPID]
        while !pending.isEmpty, visited.count < 4096 {
            let parent = pending.removeLast()
            var children = [pid_t](repeating: 0, count: 4096)
            // libproc's convenience wrapper returns a PID count, NOT byte count.
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            for pid in children.prefix(Int(count)) where pid > 0 {
                guard visited.insert(pid).inserted else { continue }
                pending.append(pid)
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
                guard length > 0 else { continue }
                let executable = String(cString: path)
                guard executable.hasPrefix(canonicalRoot + "/"),
                      executable.contains(" Helper"), executable.contains(".app/Contents/MacOS/") else { continue }
                result.append(row(pid: pid, role: BrowserHelperRole.classify(arguments: arguments(pid: pid)).rawValue,
                                  isHelper: true))
            }
        }
        return result.sorted { $0.isHelper == $1.isHelper ? $0.pid < $1.pid : !$0.isHelper }
    }

    private static func row(pid: pid_t, role: String, isHelper: Bool) -> BrowserProcessSample {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return BrowserProcessSample(pid: pid, role: role,
                                    footprintBytes: status == 0 ? usage.ri_phys_footprint : nil, isHelper: isHelper,
                                    residentBytes: status == 0 ? usage.ri_resident_size : nil)
    }

    private static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 16384 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        // Skip executable path and padding; consume argc entries, never the environment.
        while cursor < size && data[cursor] != 0 { cursor += 1 }
        while cursor < size && data[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard cursor < size else { break }
            let start = cursor
            while cursor < size && data[cursor] != 0 { cursor += 1 }
            result.append(String(decoding: data[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return result
    }
}
