import SwiftUI

enum AppTheme: String, CaseIterable, Hashable {
    case classic
    case phosphorTerminal

    var label: String {
        switch self {
        case .classic: return "經典 TUI"
        case .phosphorTerminal: return "Phosphor Terminal"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "跟隨深淺外觀的低彩度工作台"
        case .phosphorTerminal: return "黑底綠磷光、掃描線與 shell prompt"
        }
    }
}

// Theme token 全部由使用者選擇即時計算；TaskStore 的 @Published theme 會驅動畫面重繪。
enum Theme {
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "classic") ?? .classic
    }
    static var isTerminal: Bool { current == .phosphorTerminal }

    static var bg: Color     { token(classicDark: 0x15171e, classicLight: 0xfbfaf7, terminal: 0x07110b) }
    static var panel: Color  { token(classicDark: 0x1b1e27, classicLight: 0xefece6, terminal: 0x0b1a10) }
    static var fg: Color     { token(classicDark: 0xd7d9df, classicLight: 0x2a2d34, terminal: 0xb7f7c5) }
    static var dim: Color    { token(classicDark: 0x6b7280, classicLight: 0x9aa0aa, terminal: 0x568563) }
    static var border: Color { token(classicDark: 0x2b303b, classicLight: 0xddd8cf, terminal: 0x174626) }

    static var blue: Color   { token(classicDark: 0x7aa2f7, classicLight: 0x2f6bd6, terminal: 0x69f59a) }
    static var green: Color  { token(classicDark: 0x9ece6a, classicLight: 0x2e8b57, terminal: 0x45ff79) }
    static var red: Color    { token(classicDark: 0xf7768e, classicLight: 0xd43d30, terminal: 0xff6b6b) }
    static var yellow: Color { token(classicDark: 0xe0af68, classicLight: 0xb26a00, terminal: 0xe5f36b) }
    static var cyan: Color   { token(classicDark: 0x7dcfff, classicLight: 0x0e7490, terminal: 0x62e6d2) }
    static var mag: Color    { token(classicDark: 0xbb9af7, classicLight: 0x8250df, terminal: 0x9dbbff) }
    static var focus: Color  { token(classicDark: 0x4fd6c4, classicLight: 0x0d9488, terminal: 0x39ff88) }

    /// 可選強調色(設定頁):語意色(紅=逾期/teal=Focus/綠=完成)不列入,避免撞語意
    static var accentPalette: [(name: String, color: Color)] { [
        ("藍", blue), ("青", cyan), ("洋紅", mag), ("黃", yellow),
    ] }

    static var focusBg: Color { focus.opacity(0.15) }
    static var selBg: Color { blue.opacity(0.13) }
    /// 清單游標:中性灰 — 游標是位置指示,不承載語意色
    static var cursorBg: Color { dim.opacity(0.18) }

    static var mono: Font { appFont(size: 13.5) }
    static var monoSmall: Font { appFont(size: 11.5) }
    static var monoBig: Font { appFont(size: 22, weight: .bold) }

    /// 由設定選擇的全 app 字型。若指定字型不存在，SwiftUI 會自動回退系統字型。
    static func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let latin = LatinFontChoice(rawValue: UserDefaults.standard.string(forKey: "latinFontChoice")
                                    ?? UserDefaults.standard.string(forKey: "appFontChoice")
                                    ?? "systemMonospaced") ?? .systemMonospaced
        let chinese = ChineseFontChoice(rawValue: UserDefaults.standard.string(forKey: "chineseFontChoice") ?? "pingFangTC") ?? .pingFangTC
        let base = latin.fontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let chineseDescriptor = NSFontDescriptor(fontAttributes: [.family: chinese.fontName])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [chineseDescriptor]])
        let composed = NSFont(descriptor: descriptor, size: size) ?? base
        return Font(composed).weight(weight)
    }

    static func dyn(_ dark: UInt, _ light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    private static func token(classicDark: UInt, classicLight: UInt, terminal: UInt) -> Color {
        isTerminal ? Color(nsColor: NSColor(hex: terminal)) : dyn(classicDark, classicLight)
    }
}

/// CRT 掃描線只是一層很淡的材質，不攔截滑鼠，也不影響內容對比。
struct TerminalScanlines: View {
    var body: some View {
        if Theme.isTerminal {
            Canvas { context, size in
                var y: CGFloat = 1
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(.black.opacity(0.16)))
                    y += 4
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// due:YYYY-MM-DD → 相對標籤（研究：近期相對、遠期絕對;儲存仍 ISO）。
enum RelativeDate {
    static let cal = Calendar.current

    static func parse(_ ymd: String) -> Date? {
        let p = ymd.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return cal.date(from: DateComponents(year: y, month: m, day: d))
    }

    static func todayYMD(_ today: Date = Date()) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: today)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 回傳 (顯示文字, 是否逾期)。
    static func label(_ ymd: String, today: Date = Date()) -> (text: String, overdue: Bool)? {
        guard let d = parse(ymd) else { return nil }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case 0: return ("Today", false)
        case 1: return ("Tomorrow", false)
        case -1: return ("Yesterday", true)
        case ..<0: return ("\(-days)d ago", true)
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEE"; return (f.string(from: d), false)
        default:
            let f = DateFormatter(); f.dateFormat = "M/d"; return (f.string(from: d), false)
        }
    }
}
