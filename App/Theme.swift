import SwiftUI

// TUI 終端色票。每個顏色都是動態色：深色終端 / 淺色「紙終端」，隨系統或手動切換自動變。
enum Theme {
    // dyn(深, 淺)
    static let bg      = dyn(0x15171e, 0xfbfaf7)
    static let panel   = dyn(0x1b1e27, 0xefece6)
    static let fg      = dyn(0xd7d9df, 0x2a2d34)
    static let dim     = dyn(0x6b7280, 0x9aa0aa)
    static let border  = dyn(0x2b303b, 0xddd8cf)

    static let blue    = dyn(0x7aa2f7, 0x2f6bd6)   // 選取 / 一般強調
    static let green   = dyn(0x9ece6a, 0x2e8b57)   // 完成
    static let red     = dyn(0xf7768e, 0xd43d30)   // 逾期（唯一的紅）
    static let yellow  = dyn(0xe0af68, 0xb26a00)   // q2
    static let cyan    = dyn(0x7dcfff, 0x0e7490)   // q3 / @context
    static let mag     = dyn(0xbb9af7, 0x8250df)   // +project
    static let focus   = dyn(0x4fd6c4, 0x0d9488)   // Focus（teal，非紅）

    /// 可選強調色(設定頁):語意色(紅=逾期/teal=Focus/綠=完成)不列入,避免撞語意
    static let accentPalette: [(name: String, color: Color)] = [
        ("藍", blue), ("青", cyan), ("洋紅", mag), ("黃", yellow),
    ]

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
