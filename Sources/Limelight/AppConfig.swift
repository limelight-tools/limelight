import Foundation
import AppKit

struct AppConfig {
    let blurAlpha: CGFloat
    let dimAlpha: CGFloat

    private static let blurKey = "blurAlpha"
    private static let dimKey = "dimAlpha"
    private static let hotkeyEnabledKey = "hotkeyEnabled"

    static let `default` = AppConfig(blurAlpha: 0.85, dimAlpha: 0.20)

    /// Loads from: UserDefaults (persisted slider values) -> CLI overrides.
    static func fromCommandLine() -> AppConfig {
        let defaults = UserDefaults.standard
        var blurAlpha = defaults.object(forKey: blurKey) != nil
            ? CGFloat(defaults.double(forKey: blurKey))
            : Self.default.blurAlpha
        var dimAlpha = defaults.object(forKey: dimKey) != nil
            ? CGFloat(defaults.double(forKey: dimKey))
            : Self.default.dimAlpha

        var i = 1
        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            switch arg {
            case "--blur-alpha":
                if i + 1 < CommandLine.arguments.count,
                   let value = Double(CommandLine.arguments[i + 1]) {
                    blurAlpha = CGFloat(max(0.0, min(1.0, value)))
                    i += 1
                }
            case "--dim-alpha":
                if i + 1 < CommandLine.arguments.count,
                   let value = Double(CommandLine.arguments[i + 1]) {
                    dimAlpha = CGFloat(max(0.0, min(1.0, value)))
                    i += 1
                }
            case "--help", "-h":
                printHelpAndExit()
            default:
                break
            }
            i += 1
        }

        return AppConfig(blurAlpha: blurAlpha, dimAlpha: dimAlpha)
    }

    static func saveToDefaults(blurAlpha: CGFloat, dimAlpha: CGFloat) {
        let defaults = UserDefaults.standard
        defaults.set(Double(blurAlpha), forKey: blurKey)
        defaults.set(Double(dimAlpha), forKey: dimKey)
    }

    static var isHotkeyEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: hotkeyEnabledKey) == nil
                ? true
                : defaults.bool(forKey: hotkeyEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hotkeyEnabledKey)
        }
    }

    private static func printHelpAndExit() -> Never {
        print(
            """
            Limelight options:
              --blur-alpha <0...1>   Blur layer alpha (default: 0.9)
              --dim-alpha <0...1>    Dim layer alpha (default: 0.3)
              -h, --help             Show this help
            """
        )
        exit(0)
    }
}
