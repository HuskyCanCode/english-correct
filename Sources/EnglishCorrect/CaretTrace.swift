import Foundation

/// Opt-in, bounded local diagnostics. Records cursor metadata, never text or keys.
@MainActor
enum CaretTrace {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "caretDiagnosticsEnabled") }
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnglishCorrect/Diagnostics/caret.jsonl")
    }

    static func record(_ event: String, _ fields: [String: String] = [:]) {
        guard enabled else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            var values = fields
            values["event"] = event
            values["uptime"] = String(ProcessInfo.processInfo.systemUptime)
            var data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            data.append(0x0a)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size < 131_072 else { return }
            try handle.write(contentsOf: data)
        } catch { /* Diagnostics must never interrupt correction. */ }
    }
}
