import Foundation

/// File writes for setup: through symlinks (dotfile managers link `settings.json` and
/// `CLAUDE.md`), atomically, keeping permissions, with an optional backup beside the real file.
enum SetupFiles {
    /// Where a write to `url` really lands: symlinks followed (up to 16), relative links resolved
    /// against the link's folder. A dangling link resolves to its target, which is then created.
    static func target(_ url: URL) -> URL {
        var cur = url.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<16 {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: cur.path) else { return cur }
            cur = (dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : cur.deletingLastPathComponent().appendingPathComponent(dest)).standardizedFileURL
        }
        return cur
    }

    /// Backup first (as `<name>.headroom-backup` beside the real file), then a temporary file
    /// renamed over the real file. Returns the backup's URL when one was written.
    @discardableResult
    static func write(_ data: Data, to url: URL, backup: Data? = nil) throws -> URL? {
        let fm = FileManager.default
        let real = target(url)
        let dir = real.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let mode = (try? fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int) ?? 0o644
        var backupURL: URL?
        if let backup {
            let b = dir.appendingPathComponent(real.lastPathComponent + ".headroom-backup")
            try backup.write(to: b, options: .atomic)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: b.path)
            backupURL = b
        }
        let tmp = dir.appendingPathComponent(".\(real.lastPathComponent).headroom-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        guard rename(tmp.path, real.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return backupURL
    }

    /// `~/x` and `$HOME/x` against `userHome`; anything else as given.
    static func expand(_ path: String, userHome: URL) -> URL {
        if path == "~" || path == "$HOME" { return userHome }
        if path.hasPrefix("~/") { return userHome.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("$HOME/") { return userHome.appendingPathComponent(String(path.dropFirst(6))) }
        return URL(fileURLWithPath: path, relativeTo: userHome).standardizedFileURL
    }
}

/// When a Headroom hook last ran, per harness: `<store>/tasks/hook-heartbeat.json`,
/// `{"claude-code": "2026-11-13T10:00:00.000Z", …}`. Proof the hooks fire.
enum HookHeartbeat {
    static func url(store: URL) -> URL { TaskJournal.directory(home: store).appendingPathComponent("hook-heartbeat.json") }

    static func read(store: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url(store: store)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Date] = [:]
        for (k, v) in obj {
            if let s = v as? String, let d = ISO8601DateFormatter.headroomEventDate(s) { out[k] = d }
        }
        return out
    }

    /// Skips the write when the last beat is under 5 seconds old: hooks fire in bursts.
    static func record(_ harness: AgentHarness, at: Date, store: URL) {
        var beats = read(store: store)
        if let last = beats[harness.rawValue], abs(at.timeIntervalSince(last)) < 5 { return }
        beats[harness.rawValue] = at
        let obj = beats.mapValues { ISO8601DateFormatter.headroomEventString($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let dir = TaskJournal.directory(home: store)
        try? TaskJournal.makeDirectory(dir)
        let tmp = dir.appendingPathComponent(".hook-heartbeat-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url(store: store).path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }
}
