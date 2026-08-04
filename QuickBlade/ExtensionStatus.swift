import Foundation

/// Best-effort check of whether the Quick Look extension is registered and
/// enabled, via `pluginkit -m -i <bundle id>`. pluginkit prefixes its match
/// line with "+" (enabled), "-" (disabled), or other markers. Sandboxed apps
/// may not be able to spawn the tool or reach pkd at all — every failure path
/// returns nil, and the UI must show static instructions in that case, never
/// a guessed status.
enum ExtensionStatus {
    case enabled
    case disabled

    static func check() -> ExtensionStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", "com.quickblade.QuickBlade.BladeQuickLook"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let marker = output.trimmingCharacters(in: .whitespacesAndNewlines).first
        else { return nil }
        switch marker {
        case "+": return .enabled
        case "-": return .disabled
        default: return nil
        }
    }
}
