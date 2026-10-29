import Security

/// What the app and its fan helper (a root LaunchDaemon) agree on.
///
/// Messages are XPC dictionaries with an `op`:
///   `curve` + `min`, `max` (°C, doubles), `sensor` (a FanSensor; default if missing or unknown)
///                                          take the fans and follow this curve
///   `release`                              give the fans back to macOS
/// Each gets a reply; an `error` string in it means it didn't take.
/// The helper gives the fans back on its own as soon as the app's connection goes away.
public enum FanHelper {
    public static let label = "com.scalexy.headroom.fan"
    public static let machService = label
    public static let plistName = "\(label).plist"
    /// The code signing identifiers each side checks the other for, along with the team.
    public static let helperIdentifier = label
    public static let appIdentifier = "com.scalexy.headroom"

    public static func requirement(identifier: String, team: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team that signed this process (nil when unsigned or ad hoc). The app and helper must share it.
    public static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
