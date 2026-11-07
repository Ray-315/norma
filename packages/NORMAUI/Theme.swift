import SwiftUI
import Observation
public enum ThemeMode: String, CaseIterable, Codable, Sendable { case system, light, dark }
@MainActor @Observable public final class ThemeManager {
    public var mode: ThemeMode { didSet { defaults.set(mode.rawValue, forKey: "appearance.mode") } }
    public var accentHex: String { didSet { defaults.set(accentHex, forKey: "appearance.accent") } }
    public var customHex: String { didSet { defaults.set(customHex, forKey: "appearance.custom") } }
    private let defaults: UserDefaults
    public static let accents = ["947AF5", "4F8EF7", "2CB8B5", "36AC79", "EA965A", "E56B79"]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ThemeMode(rawValue: defaults.string(forKey: "appearance.mode") ?? "") ?? .system
        accentHex = defaults.string(forKey: "appearance.accent") ?? "947AF5"
        customHex = defaults.string(forKey: "appearance.custom") ?? "947AF5"
    }
    public var preferredScheme: ColorScheme? { mode == .system ? nil : mode == .dark ? .dark : .light }
    public var accent: Color { Color(hex: accentHex) }
    public func toggle(resolved: ColorScheme) { mode = resolved == .dark ? .light : .dark }
    public static func validHex(_ value: String) -> Bool {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return hex.count == 6 && hex.allSatisfy { $0.isHexDigit }
    }
    public func saveCustom(_ value: String) -> Bool {
        guard Self.validHex(value) else { return false }
        customHex = value.replacingOccurrences(of: "#", with: "").uppercased(); accentHex = customHex; return true
    }
    public func reset() { mode = .system; accentHex = "947AF5"; customHex = "947AF5" }
}
public extension Color {
    init(hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x947AF5
        self.init(.sRGB, red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
struct ThemeTokens {
    let dark: Bool
    var canvas: Color { Color(hex: dark ? "13161C" : "F5F6FA") }
    var sidebar: Color { Color(hex: dark ? "111318" : "EAEFF5") }
    var surface: Color { Color(hex: dark ? "181C23" : "FFFFFF") }
    var secondary: Color { Color(hex: dark ? "1D2129" : "F9FAFD") }
    var border: Color { Color(hex: dark ? "2E333D" : "D6DCE6") }
    var primary: Color { Color(hex: dark ? "E8EDF5" : "1E2533") }
    var muted: Color { Color(hex: dark ? "8C96A8" : "667084") }
}
struct Panel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String; @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        let tokens = ThemeTokens(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tokens.border))
    }
}
struct StatusBadge: View {
    let text: String; var status: String = "unknown"
    var color: Color {
        switch status { case "pass", "succeeded", "fullGood": Color(hex: "36AC79")
        case "fail", "failed", "bad": Color(hex: "E56B79")
        case "running", "queued": Color(hex: "4F8EF7")
        default: Color(hex: "EA965A") }
    }
    var body: some View { Text(DisplayText.value(text)).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.12), in: Capsule()) }
}
