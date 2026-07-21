import SwiftUI
import TasksTxtCore

// MARK: - ⌘4 統計 Dashboard
// 設計:描述性 TUI 圖表(Taskwarrior / todo.txt-graph 路線)+ GitHub 熱力圖。唯讀、一鍵進出。
// tui-design 準則:單一語意色(綠=完成)、標籤帶身分色、長條用字元(█░)、砍裝飾性描邊與逐柱標數。
// 刻意不做:Karma 計分、等級、排名、逾期懲罰、歸零 streak(市場反模式)。

struct DashboardView: View {
    @EnvironmentObject var store: TaskStore
    @State private var doneByDay: [String: Int] = [:]      // done:YMD → 完成數
    @State private var doneProjects: [(String, Int)] = []  // 近 30 天 +project → 完成數
    @State private var createdThisWeek = 0                 // created: ≥ 本週一(僅捕捉過的任務有此欄,少算屬事實)

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    private func ymd(_ d: Date) -> String { Self.fmt.string(from: d) }
    private func day(_ offset: Int, from base: Date = Date()) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base))!
    }
    private var startOfWeek: Date {
        let today = cal.startOfDay(for: Date())
        let wd = (cal.component(.weekday, from: today) + 5) % 7   // 週一=0
        return day(-wd, from: today)
    }
    private func count(_ d: Date) -> Int { doneByDay[ymd(d)] ?? 0 }
    private func sum(from: Date, days: Int) -> Int {
        (0..<days).reduce(0) { $0 + count(day($1, from: from)) }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                greetingHeader
                summaryRow
                section("完成趨勢")
                heatmap.padding(.horizontal, 16)
                sparkline.padding(.horizontal, 16).padding(.top, 10)
                if !doneProjects.isEmpty {
                    section("List · 近 30 天完成")
                    projectBars.padding(.horizontal, 16)
                }
                section("象限 · 未完成")
                quadrantBars.padding(.horizontal, 16)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    // MARK: 時段問候(早晨/中午/下午/晚上 各配線條圖案)

    private var greetingHeader: some View {
        let (_, text, color) = greetingParts
        return VStack(spacing: 32) {   // 明確保留至少一個完整文字行高的空白
            dashboardIcon(color: color)
            Text(text).font(Theme.mono).foregroundColor(Theme.fg)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 44)
    }

    @ViewBuilder private func dashboardIcon(color: Color) -> some View {
        switch store.dashboardIconStyle {
        case .chronoOrb: chronoOrb(color)
        case .terminalPulse: terminalPulse(color)
        case .completionCompass: completionCompass
        case .quietHorizon: quietHorizon(color)
        }
    }

    private func chronoOrb(_ color: Color) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.32), lineWidth: 1).frame(width: 126, height: 126)
            Circle().stroke(color.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: 98, height: 98)
            Circle().stroke(color.opacity(0.18), lineWidth: 1).frame(width: 64, height: 64)
            ForEach(0..<8, id: \.self) { i in
                Rectangle().fill(color.opacity(0.8)).frame(width: 1, height: 9)
                    .offset(y: -68).rotationEffect(.degrees(Double(i) * 45))
            }
            Circle().fill(color).frame(width: 42, height: 42)
                .shadow(color: color.opacity(0.55), radius: 15)
            Text("\(String(format: "%02d", cal.component(.hour, from: Date()))):\(String(format: "%02d", cal.component(.minute, from: Date())))")
                .font(.system(size: 8, design: .monospaced)).foregroundColor(Theme.bg)
        }
        .frame(height: 145)
        .overlay(alignment: .bottom) {
            Text("CHRONO · TODAY").font(.system(size: 8, design: .monospaced))
                .tracking(2).foregroundColor(color.opacity(0.8))
        }
    }

    private func terminalPulse(_ color: Color) -> some View {
        VStack(spacing: 5) {
            Text("╭──────────────╮").foregroundColor(color.opacity(0.65))
            Text("────┤  ● \(String(format: "%02d:%02d", cal.component(.hour, from: Date()), cal.component(.minute, from: Date())))  ├────")
                .foregroundColor(Theme.focus)
            Text("╰──────┬───────╯").foregroundColor(color.opacity(0.65))
            Text("▁▂▃▅▇███▇▅▃▂▁").foregroundColor(color)
            Text("READY / FOCUS").font(.system(size: 9, design: .monospaced))
                .tracking(2).foregroundColor(Theme.focus)
        }
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .frame(height: 145)
    }

    private var completionCompass: some View {
        ZStack {
            VStack(spacing: 4) {
                HStack(spacing: 4) { compassCell("Q1", Theme.red); compassCell("Q2", Theme.yellow) }
                HStack(spacing: 4) { compassCell("Q3", Theme.cyan); compassCell("Q4", Theme.dim) }
            }
            .rotationEffect(.degrees(45))
            Rectangle().fill(Theme.panel).frame(width: 48, height: 48)
                .overlay(Rectangle().stroke(Theme.mag))
                .overlay(Text("✓").font(.system(size: 24, weight: .bold, design: .monospaced)).foregroundColor(Theme.green))
            Text("\(sum(from: startOfWeek, days: 7)) DONE · \(store.lines.filter { !$0.isDone }.count) OPEN")
                .font(.system(size: 8, design: .monospaced)).tracking(1.4).foregroundColor(Theme.mag)
                .offset(y: 70)
        }
        .frame(height: 145)
    }

    private func compassCell(_ label: String, _ color: Color) -> some View {
        Rectangle().fill(color.opacity(0.10)).frame(width: 56, height: 56)
            .overlay(Rectangle().stroke(color.opacity(0.45)))
            .overlay(Text(label).font(.system(size: 8, design: .monospaced)).foregroundColor(color).rotationEffect(.degrees(-45)))
    }

    private func quietHorizon(_ color: Color) -> some View {
        Canvas { context, size in
            let horizon = size.height * 0.72
            var line = Path(); line.move(to: CGPoint(x: 10, y: horizon)); line.addLine(to: CGPoint(x: size.width - 10, y: horizon))
            context.stroke(line, with: .linearGradient(Gradient(colors: [.clear, color, .clear]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 1)
            var mountains = Path(); mountains.move(to: CGPoint(x: 28, y: horizon)); mountains.addLine(to: CGPoint(x: 90, y: 48)); mountains.addLine(to: CGPoint(x: 132, y: horizon)); mountains.addLine(to: CGPoint(x: 188, y: 62)); mountains.addLine(to: CGPoint(x: 250, y: horizon))
            context.stroke(mountains, with: .color(color.opacity(0.55)), lineWidth: 1)
            let moon = CGRect(x: size.width / 2 - 25, y: 18, width: 50, height: 50)
            context.stroke(Path(ellipseIn: moon), with: .color(color.opacity(0.9)), lineWidth: 1)
        }
        .frame(width: 280, height: 125)
        .overlay(alignment: .bottom) {
            Text("QUIET PROGRESS").font(.system(size: 8, design: .monospaced))
                .tracking(2.4).foregroundColor(color.opacity(0.8))
        }
        .frame(height: 145)
    }
    private var greetingParts: ([String], String, Color) {
        let who = store.userName.trimmingCharacters(in: .whitespaces)
        let name = who.isEmpty ? "" : " " + who      // 設定頁未填名字就用通用問候
        let english = store.appLanguage == .english
        switch cal.component(.hour, from: Date()) {
        case 5..<11:   // 早晨:朝陽從地平線升起,放射光芒
            return (["      \\   |   /",
                     "   ‘ .  _◜◝_  . ’",
                     "  ──  (  ☀  )  ──",
                     "   . ’  ‾◟◞‾  ‘ .",
                     "  ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁"],
                    english ? "Good morning\(name) — Start the day with one clear task." : "早安\(name) — 新的一天，從第一件事開始。", Theme.yellow)
        case 11..<14:  // 中午:烈日當空,全向放射
            return (["    \\    |    /",
                     "   ‘‘  .───.  ’’",
                     "  ──  ║ ☀ ║  ──",
                     "   ,,  ‘───’  ,,",
                     "    /    |    \\"],
                    english ? "Good afternoon\(name) — Take a breath, then begin the next half." : "午安\(name) — 記得休息，下半場再來。", Theme.yellow)
        case 14..<18:  // 下午:斜陽西沉,長影拉地平
            return (["         \\  |  /",
                     "      ‘ .  ___  . ’",
                     "     ──   ( ◗ )   ──",
                     "  ~~~~~~~~‾‾‾‾‾~~~~~~~~",
                     "   ▂▃▄▅▆▇███▇▆▅▄▃▂"],
                    english ? "Good afternoon\(name) — Keep your rhythm; the finish is in sight." : "下午好\(name) — 保持節奏，收尾在望。", Theme.yellow)
        default:       // 晚上:弦月與星辰
            return (["    ✦        .      ˚",
                     "        .    ⋆   ___",
                     "   ˚    ✦       (   ◗",
                     "      ⋆    .     ‾‾‾",
                     "   .      ✦   ˚      ⋆"],
                    english ? "Good evening\(name) — Take a moment to review what you finished today." : "晚安\(name) — 回顧一下今天完成的事。", Theme.cyan)
        }
    }

    /// 統計查詢由 Core module 建立；View 只負責呈現。
    private func reload() {
        let cutoff = ymd(day(-29))
        let report = ActivityReporting.build(lines: store.lines, archiveLines: store.archiveLines, sinceYMD: cutoff)
        doneByDay = report.doneByDay
        doneProjects = report.doneProjects.prefix(6).map { ($0.name, $0.count) }
        createdThisWeek = ActivityReporting.build(lines: store.lines, archiveLines: store.archiveLines,
                                                  sinceYMD: ymd(startOfWeek)).createdSince
    }

    // MARK: 摘要(事實陳述,不打分;僅「本週」帶語意綠)

    private var summaryRow: some View {
        let pending = store.lines.filter { !$0.isDone }.count
        let thisWeek = sum(from: startOfWeek, days: 7)
        let lastWeek = sum(from: day(-7, from: startOfWeek), days: 7)
        let d30 = sum(from: day(-29), days: 30)
        return HStack(spacing: 10) {
            statCard("待辦", "\(pending)", Theme.fg)
            statCard("本週完成", "\(thisWeek)", Theme.green)
            statCard("上週", "\(lastWeek)", Theme.fg)
            statCard("近30天", "\(d30)", Theme.fg)
            statCard("本週流量", "+\(createdThisWeek) −\(thisWeek)", Theme.fg)   // 淨流量:待辦收斂或膨脹
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    /// TUI 卡片:方角、細框、數字為主 — 等寬並排填滿一列
    private func statCard(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundColor(color)
            Text(LocalizedStringKey(label)).font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.panel)                           // 同分頁列底色
        .overlay(Rectangle().stroke(Theme.border))
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .font(Theme.monoSmall).tracking(1)
        .padding(.horizontal, 16).padding(.top, store.density.sectionTop).padding(.bottom, 8)
    }

    // MARK: 熱力圖(GitHub 式,12 週 × 7 天;無描邊,濃淡即資訊)

    private var heatmap: some View {
        // 以「日曆年」為單位呈現:每年一張 1/1→12/31 的完整格圖,新年份在上
        let years: [Int] = {
            var ys = Set(doneByDay.keys.compactMap { Int($0.prefix(4)) })
            ys.insert(cal.component(.year, from: Date()))
            return ys.sorted(by: >)
        }()
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(years, id: \.self) { yearGrid($0) }
        }
        .frame(maxWidth: .infinity)
    }
    private func yearGrid(_ year: Int) -> some View {
        let today = cal.startOfDay(for: Date())
        let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let offset = (cal.component(.weekday, from: jan1) + 5) % 7        // 週一=0
        let gridStart = cal.date(byAdding: .day, value: -offset, to: jan1)!
        let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31))!
        let weeks = (cal.dateComponents([.day], from: gridStart, to: dec31).day! / 7) + 1
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(year)).font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1)
                .frame(maxWidth: .infinity)   // 年度數字置中
            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(["一", "", "三", "", "五", "", "日"], id: \.self) { w in
                        Text(w).font(Theme.monoSmall).foregroundColor(Theme.dim).frame(height: 13)
                    }
                }.padding(.trailing, 3)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(0..<weeks, id: \.self) { w in
                                VStack(spacing: 3) {
                                    ForEach(0..<7, id: \.self) { r in
                                        let d = cal.date(byAdding: .day, value: w * 7 + r, to: gridStart)!
                                        let inYear = cal.component(.year, from: d) == year
                                        Rectangle()
                                            .fill(!inYear ? Color.clear
                                                  : d > today ? Theme.dim.opacity(0.1)     // 年內未到的天:透明灰
                                                  : heatColor(count(d)))
                                            .frame(width: 13, height: 13)
                                            .help(inYear ? (store.appLanguage == .english ? "\(ymd(d)) · \(count(d)) completed" : "\(ymd(d)) · 完成 \(count(d))") : "")
                                    }
                                }.id(w)
                            }
                        }
                    }
                    .onAppear {   // 當年卷動到本週置中,歷史年停在年初
                        if year == cal.component(.year, from: today) {
                            let cw = (cal.dateComponents([.day], from: gridStart, to: today).day ?? 0) / 7
                            proxy.scrollTo(cw, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func heatColor(_ n: Int) -> Color {
        switch n {
        case 0: return Theme.panel
        case 1: return Theme.green.opacity(0.3)
        case 2...3: return Theme.green.opacity(0.6)
        default: return Theme.green.opacity(0.95)
        }
    }

    // MARK: 近 14 天 sparkline(單行字元,取代長條圖)

    private var sparkline: some View {
        let days = (0..<14).map { day($0 - 13) }
        let maxN = max(days.map(count).max() ?? 1, 1)
        let levels = Array("▁▂▃▄▅▆▇█")
        let spark = days.reduce(Text("")) { acc, d in
            let n = count(d)
            let ch = n == 0 ? "▁" : String(levels[min(7, Int(Double(n) / Double(maxN) * 7 + 0.5))])
            return acc + Text(ch).foregroundColor(n > 0 ? Theme.green : Theme.border)
        }
        let weeklyAvg = Int((Double(sum(from: day(-83), days: 84)) / 12).rounded())   // 12 週窗的每週均量
        return HStack(spacing: 10) {
            Text("近 14 天").foregroundColor(Theme.dim)
            spark.font(.system(size: 17, design: .monospaced))
            Spacer()   // 數字靠右,整行撐滿
            Text("今天 \(count(days[13]))").foregroundColor(Theme.fg)
            Text("週均 \(weeklyAvg)").foregroundColor(Theme.dim)
        }
        .font(Theme.monoSmall)
    }

    // MARK: 字元長條(█░;標籤帶身分色,長條一律中性)

    private var projectBars: some View {
        let maxN = doneProjects.first?.1 ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(doneProjects, id: \.0) { name, n in
                // drill-down(Asana 慣例):點列 → 清單視圖 + 套該專案篩選
                tbar("+\(name)", n, maxN, Theme.mag)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.tagFilter = "+" + name
                        store.view = .list
                        store.ensureCursor()
                    }
            }
        }
    }
    private var quadrantBars: some View {
        let b = store.board()
        let rows: [(String, Int, Color)] = [
            ("q1 Do", b.q1.count, Theme.red), ("q2 Schedule", b.q2.count, Theme.yellow),
            ("q3 Delegate", b.q3.count, Theme.cyan), ("q4 Delete", b.q4.count, Theme.dim),
            (store.appLanguage == .english ? "Unassigned" : "未歸位", b.unplaced.count, Theme.dim),
        ]
        let maxN = max(rows.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { label, n, color in tbar(label, n, maxN, color) }
        }
    }
    private func tbar(_ label: String, _ n: Int, _ maxN: Int, _ labelColor: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundColor(labelColor).frame(width: 120, alignment: .trailing).lineLimit(1)
            // 軌道撐滿剩餘寬度,填充比例由 GeometryReader 計算(字元條無法填滿彈性寬,改回幾何條)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.panel)
                GeometryReader { geo in
                    Rectangle().fill(Theme.dim.opacity(0.75))
                        .frame(width: n > 0 ? max(geo.size.width * CGFloat(n) / CGFloat(maxN), 4) : 0)
                }
            }
            .frame(height: 11)
            Text("\(n)").foregroundColor(Theme.fg).frame(width: 32, alignment: .trailing)
        }
        .font(Theme.monoSmall)
    }
}
