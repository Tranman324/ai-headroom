import AppKit
import SwiftUI

enum UsagePopoverMetrics {
    static let contentWidth: CGFloat = 320
    static let contentHeight: CGFloat = 520
    static let cornerRadius: CGFloat = 13
    static let horizontalPadding: CGFloat = 14
    static let chartWidth: CGFloat = 292
    static let chartHeight: CGFloat = 80
    static let primaryRowHeight: CGFloat = 36
    static let modelRowHeight: CGFloat = 30
    static let primaryBarHeight: CGFloat = 5
    static let modelBarHeight: CGFloat = 3
}

enum UsagePalette {
    static let warmCharcoal = NSColor(hex: 0x262624)
    static let raisedSurface = NSColor(hex: 0x30302E)
    static let inset = NSColor(hex: 0x1F1E1D)
    static let border = NSColor(hex: 0x3E3E3A)
    static let primaryText = NSColor(hex: 0xECECEA)
    static let mutedText = NSColor(hex: 0x8A867F)
    static let claudeAccent = NSColor(hex: 0xD97757)
    static let codexAccent = NSColor(hex: 0x10A37F)
    static let warning = NSColor(hex: 0xE3B341)
    static let critical = NSColor(hex: 0xE5484D)
    static let allModels = NSColor(hex: 0xB4B0AA)
    static let sonnet = NSColor(hex: 0xC2A26B)
    static let haiku = NSColor(hex: 0x8FA0B8)
    static let statusWarning = adaptiveStatusColor(
        light: NSColor(hex: 0x855600),
        dark: NSColor(hex: 0xFFD25A)
    )
    /// A deeper red than `critical` so the capsule's white text meets 4.5:1 contrast.
    static let statusCriticalCapsule = NSColor(hex: 0xD1343A)

    private static func adaptiveStatusColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func accent(for provider: ProviderID) -> NSColor {
        switch provider {
        case .claude:
            return claudeAccent
        case .codex:
            return codexAccent
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex & 0xFF0000) >> 16) / 255
        let green = CGFloat((hex & 0x00FF00) >> 8) / 255
        let blue = CGFloat(hex & 0x0000FF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var swiftUIColor: Color {
        Color(nsColor: self)
    }

    var deviceRGBColor: NSColor {
        usingColorSpace(.deviceRGB) ?? self
    }
}
