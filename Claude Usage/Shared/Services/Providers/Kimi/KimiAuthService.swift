import Foundation

enum KimiAuthService {
    /// OpenCode v2 exports records; v1 stores a dictionary of provider keys.
    /// Only the explicitly selected Kimi region may supply a credential.
    static func parse(_ data: Data, region: KimiRegion) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data)
        if let rows = json as? [[String: Any]] {
            let matches = rows.filter { $0["integrationID"] as? String == region.integrationID }
            let active = matches.filter { $0["active"] as? Bool == true }
            guard active.count == 1 else {
                if active.count > 1 { throw KimiError.ambiguousAccounts }
                throw KimiError.importFailed
            }
            if let value = active[0]["value"] as? [String: Any],
               ["key", "api"].contains(value["type"] as? String ?? ""),
               let key = (value["key"] as? String)?.nilIfBlank { return key }
        } else if let root = json as? [String: Any] {
            // The legacy kimi-for-coding endpoint was api.kimi.com.
            let ids = region == .china ? [region.integrationID, "kimi-for-coding"] : [region.integrationID]
            for id in ids {
                if let value = root[id] as? [String: Any],
                   ["key", "api"].contains(value["type"] as? String ?? ""),
                   let key = (value["key"] as? String)?.nilIfBlank { return key }
            }
        }
        throw KimiError.importFailed
    }

    static func importFromOpenCode(region: KimiRegion, executablePath: String? = nil,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> String {
        let candidates = executablePath?.nilIfBlank.map { [($0 as NSString).expandingTildeInPath] } ?? [
            home.appendingPathComponent(".opencode/bin/opencode").path,
            "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"
        ]
        if let path = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) {
            let data = try await export(executable: URL(fileURLWithPath: path), region: region, home: home)
            // A successful but empty/ambiguous export must never fall back to a stale v1 login.
            return try parse(data, region: region)
        }
        if executablePath?.nilIfBlank != nil { throw KimiError.importFailed }
        let data = try Data(contentsOf: home.appendingPathComponent(".local/share/opencode/auth.json"))
        return try parse(data, region: region)
    }

    static func export(executable: URL, region: KimiRegion, home: URL,
                       timeout: TimeInterval = 15) async throws -> Data {
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["auth", "export", region.integrationID]
            process.currentDirectoryURL = home
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { throw KimiError.importFailed }
            let stop = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
            defer { stop.cancel(); try? pipe.fileHandleForReading.close() }
            var result = Data()
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                guard result.count + chunk.count <= 1_048_576 else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw KimiError.importFailed
                }
                result.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw KimiError.importFailed }
            return result
        }.value
        try Task.checkCancellation()
        return result
    }
}
