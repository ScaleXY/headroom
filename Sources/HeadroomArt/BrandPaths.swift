import CoreGraphics
import Foundation

/// The real Claude and OpenAI marks, read from `assets/brand/*.svg` (copied into the app's and
/// the widget extension's Resources by `make app`). 24×24 viewBox.
public enum BrandPaths {
    nonisolated(unsafe) private static var cache: [String: CGPath] = [:]
    private static let lock = NSLock()

    /// `claude` or `openai`; an empty path when the file can't be found.
    public static func path(named name: String) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let p = cache[name] { return p }
        let p = loadPathData(name).map(SVGPath.parse) ?? CGMutablePath()
        cache[name] = p
        return p
    }

    private static func loadPathData(_ name: String) -> String? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "brand") { candidates.append(u) }
        // Development runs (`swift run`): read straight from the repository.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("assets/brand/\(name).svg"))
        for url in candidates {
            guard let svg = try? String(contentsOf: url, encoding: .utf8),
                  let r = svg.range(of: #"\sd="([^"]+)""#, options: .regularExpression) else { continue }
            let attr = svg[r]
            return String(attr.dropFirst(4).dropLast())
        }
        return nil
    }
}
