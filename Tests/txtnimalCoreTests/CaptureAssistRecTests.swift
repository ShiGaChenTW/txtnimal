import XCTest
@testable import txtnimalCore

/// `rec:` 露出到 UI 所依賴的純函式:人話標籤、候選清單、補全路徑。
/// 另含 due/project/context 的回歸斷言 — 新增 `.rec` 不得改動既有補全行為。
final class CaptureAssistRecTests: XCTestCase {
    // 與 LogicTests 相同的固定日曆 + 日期,結果不受 runner 時區影響。
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private lazy var today: Date = cal.date(from: DateComponents(year: 2026, month: 7, day: 9))!

    // MARK: - 標籤與 parse 嚴格對齊

    /// spec「標籤函式對齊 parse」:當且僅當 parse 非 nil,標籤非 nil。
    /// 這是驗收條件本身,所以用同一份語料同時餵兩個函式逐一比對,不各寫各的期望值。
    func testRecurrenceLabelIsNonNilExactlyWhenRuleParses() {
        let corpus = [
            // 預期有效
            "1d", "1w", "1m", "1y", "2d", "3w", "5y", "10d", "01w", "999m",
            "+1d", "+1w", "+1m", "+1y", "+2w", "+12m",
            // 預期無效
            "", "+", "0d", "+0w", "d", "w", "1", "+1", "3x", "1dd", "1 d", "1D", "1W",
            "-1d", "1.5w", "w1", "++1d", "1d ", " 1d", "rec:1w", "1週", "1d1w",
        ]

        for token in corpus {
            let parsed = RecurrenceRule.parse(token)
            let label = CaptureAssist.recurrenceLabel(for: token)
            XCTAssertEqual(
                label != nil, parsed != nil,
                "標籤與 parse 不同調:token=\(token.debugDescription) label=\(String(describing: label)) parsed=\(String(describing: parsed))"
            )
        }
    }

    /// 語料本身要真的兩邊都有,否則上面的 biconditional 可能是空轉。
    func testRecurrenceLabelCorpusCoversBothOutcomes() {
        XCTAssertNotNil(CaptureAssist.recurrenceLabel(for: "1w"))
        XCTAssertNil(CaptureAssist.recurrenceLabel(for: "3x"))
    }

    /// 措辭是 UI 契約,逐字釘住。
    func testRecurrenceLabelWording() {
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "1d"), "每天")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "1w"), "每週")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "1m"), "每月")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "1y"), "每年")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "2d"), "每 2 天")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "3w"), "每 3 週")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "2m"), "每 2 月")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "5y"), "每 5 年")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "+1m"), "每月(固定)")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "+2w"), "每 2 週(固定)")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "+1y"), "每年(固定)")
    }

    /// 前導零由 parse 決定數值,標籤跟著數值走而不是跟著字面走。
    func testRecurrenceLabelFollowsParsedCountNotLiteralDigits() {
        XCTAssertEqual(RecurrenceRule.parse("01w")?.count, 1)
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "01w"), "每週")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(for: "002d"), "每 2 天")
    }

    // MARK: - 候選清單

    func testRecurrenceCandidatesAreValidAndOrdered() {
        XCTAssertEqual(
            CaptureAssist.recurrenceCandidates,
            ["1d", "1w", "2w", "1m", "1y", "+1d", "+1w", "+2w", "+1m", "+1y"]
        )
        // spec 要求至少涵蓋 1d/1w/2w/1m/1y 與其 + strict 版本。
        for required in ["1d", "1w", "2w", "1m", "1y", "+1d", "+1w", "+2w", "+1m", "+1y"] {
            XCTAssertTrue(CaptureAssist.recurrenceCandidates.contains(required), "缺候選 \(required)")
        }
        for candidate in CaptureAssist.recurrenceCandidates {
            XCTAssertNotNil(RecurrenceRule.parse(candidate), "候選 \(candidate) 無法被 parse")
            XCTAssertNotNil(CaptureAssist.recurrenceLabel(for: candidate), "候選 \(candidate) 無標籤")
        }
        XCTAssertEqual(
            Set(CaptureAssist.recurrenceCandidates).count,
            CaptureAssist.recurrenceCandidates.count,
            "候選清單有重複"
        )
    }

    // MARK: - rec 補全查詢與套用

    func testCompletionQueryRecognizesRecPrefix() {
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "倒垃圾 rec:", cursorUTF16Offset: 8),
            CaptureAssist.CompletionQuery(kind: .rec, fragment: "", tokenRange: NSRange(location: 4, length: 4))
        )
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "倒垃圾 rec:1", cursorUTF16Offset: 9),
            CaptureAssist.CompletionQuery(kind: .rec, fragment: "1", tokenRange: NSRange(location: 4, length: 5))
        )
        // 游標在 token 中間:只看游標前那一段,與 due: 同規則。
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "倒垃圾 rec:1w 之後", cursorUTF16Offset: 9),
            CaptureAssist.CompletionQuery(kind: .rec, fragment: "1", tokenRange: NSRange(location: 4, length: 5))
        )
        // 不是行首的 rec: 不觸發(與 "email+a" 同理)。
        XCTAssertNil(CaptureAssist.completionQuery(from: "prec:1w", cursorUTF16Offset: 7))
    }

    func testApplyingRecCompletionEmitsPrefixAndTrailingSpace() {
        guard let query = CaptureAssist.completionQuery(from: "倒垃圾 rec:", cursorUTF16Offset: 8) else {
            return XCTFail("rec: 應產生 completion query")
        }

        // spec:套用後為 `倒垃圾 rec:<候選>` 並在尾端補一個空格。
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("1w", query: query, to: "倒垃圾 rec:"),
            CaptureAssist.CompletionResult(text: "倒垃圾 rec:1w ", cursorUTF16Offset: 11)
        )
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("+1m", query: query, to: "倒垃圾 rec:"),
            CaptureAssist.CompletionResult(text: "倒垃圾 rec:+1m ", cursorUTF16Offset: 12)
        )
    }

    /// token 不在行尾時不補空格 — 與既有 `@`/`due:` 的尾隨空格規則一致。
    func testApplyingRecCompletionMidLineDoesNotAppendSpace() {
        guard let query = CaptureAssist.completionQuery(from: "倒垃圾 rec:1 之後", cursorUTF16Offset: 9) else {
            return XCTFail("rec: 應產生 completion query")
        }
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("1w", query: query, to: "倒垃圾 rec:1 之後"),
            CaptureAssist.CompletionResult(text: "倒垃圾 rec:1w 之後", cursorUTF16Offset: 10)
        )
    }

    // MARK: - rec chip

    func testTokensExposeOnlyParseableRec() {
        XCTAssertEqual(
            CaptureAssist.tokens(from: "倒垃圾 rec:1w", today: today, calendar: cal),
            [CaptureAssist.Token(kind: .rec, raw: "rec:1w", displayValue: "每週")]
        )
        XCTAssertEqual(
            CaptureAssist.tokens(from: "倒垃圾 rec:+2w", today: today, calendar: cal),
            [CaptureAssist.Token(kind: .rec, raw: "rec:+2w", displayValue: "每 2 週(固定)")]
        )
        // 無效與空值都不成 chip,原字不被改寫(tokens 本來就不改字串,這裡確認它不誤判)。
        XCTAssertEqual(CaptureAssist.tokens(from: "報告 rec:3x", today: today, calendar: cal), [])
        XCTAssertEqual(CaptureAssist.tokens(from: "報告 rec:", today: today, calendar: cal), [])
    }

    func testRemovingRecTokenLeavesOtherTokens() {
        XCTAssertEqual(
            CaptureAssist.removingToken("rec:1w", from: "倒垃圾 due:fri rec:1w @home"),
            "倒垃圾 due:fri @home"
        )
    }

    // MARK: - 整行讀取(列徽章用)

    /// spec「有效週期顯示徽章」/「無效週期不顯示徽章」的判斷來源。
    func testRecurrenceLabelFromRawLine() {
        XCTAssertEqual(CaptureAssist.recurrenceLabel(inRawLine: "倒垃圾 due:2026-08-20 rec:1w"), "每週")
        XCTAssertEqual(CaptureAssist.recurrenceLabel(inRawLine: "x 倒垃圾 rec:+1m done:2026-08-20"), "每月(固定)")
        XCTAssertNil(CaptureAssist.recurrenceLabel(inRawLine: "報告 due:2026-08-20 rec:3x"))
        XCTAssertNil(CaptureAssist.recurrenceLabel(inRawLine: "報告 due:2026-08-20"))
        XCTAssertNil(CaptureAssist.recurrenceLabel(inRawLine: "報告 rec:"))
    }

    /// 斷詞與 `TaskLine` 同規則:備註內文寫到的 rec: 不算週期設定。
    func testRecurrenceValueIgnoresRecInsideNote() {
        XCTAssertNil(CaptureAssist.recurrenceValue(inRawLine: #"買菜 note:"順便 rec:1w 那家""#))
        XCTAssertNil(CaptureAssist.recurrenceLabel(inRawLine: #"買菜 note:"順便 rec:1w 那家""#))
        // 備註之外真的有 rec: 時仍要讀得到。
        XCTAssertEqual(
            CaptureAssist.recurrenceLabel(inRawLine: #"買菜 note:"順便 rec:9z 那家" rec:2w"#),
            "每 2 週"
        )
    }

    /// 未知 token 與多重空白不影響讀取,且讀取本身不改寫任何字。
    func testRecurrenceValueSurvivesUnknownTokensAndSpacing() {
        let raw = "倒垃圾   zz:9  rec:1w\t+home"
        XCTAssertEqual(CaptureAssist.recurrenceValue(inRawLine: raw), "1w")
        XCTAssertEqual(raw, "倒垃圾   zz:9  rec:1w\t+home")
    }

    /// 與 `TaskLine` 一致:取第一個 `rec:` token。
    func testRecurrenceValueTakesFirstRecToken() {
        XCTAssertEqual(CaptureAssist.recurrenceValue(inRawLine: "a rec:1w rec:2d"), "1w")
    }

    // MARK: - 回歸:既有 due / project / context 行為零變化

    /// spec「非 rec token 行為不變」:同樣的輸入必須得到與本 change 之前逐字相同的結果。
    func testExistingCompletionKindsUnchangedByRecAddition() {
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "寄報價單 +bus", cursorUTF16Offset: 9),
            CaptureAssist.CompletionQuery(kind: .project, fragment: "bus", tokenRange: NSRange(location: 5, length: 4))
        )
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "call @ma later", cursorUTF16Offset: 8),
            CaptureAssist.CompletionQuery(kind: .context, fragment: "ma", tokenRange: NSRange(location: 5, length: 3))
        )
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "安排 due:tom", cursorUTF16Offset: 10),
            CaptureAssist.CompletionQuery(kind: .due, fragment: "tom", tokenRange: NSRange(location: 3, length: 7))
        )
        XCTAssertNil(CaptureAssist.completionQuery(from: "email+a", cursorUTF16Offset: 7))

        let contextQuery = CaptureAssist.CompletionQuery(
            kind: .context, fragment: "ma", tokenRange: NSRange(location: 5, length: 3)
        )
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("mac", query: contextQuery, to: "call @ma later"),
            CaptureAssist.CompletionResult(text: "call @mac later", cursorUTF16Offset: 9)
        )
        let dueQuery = CaptureAssist.CompletionQuery(
            kind: .due, fragment: "tom", tokenRange: NSRange(location: 3, length: 7)
        )
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("tomorrow", query: dueQuery, to: "安排 due:tom"),
            CaptureAssist.CompletionResult(text: "安排 due:tomorrow ", cursorUTF16Offset: 16)
        )
        let projectQuery = CaptureAssist.CompletionQuery(
            kind: .project, fragment: "bus", tokenRange: NSRange(location: 5, length: 4)
        )
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("business", query: projectQuery, to: "寄報價單 +bus"),
            CaptureAssist.CompletionResult(text: "寄報價單 +business ", cursorUTF16Offset: 15)
        )
    }

    /// 不含 rec: 的輸入,chip 清單與本 change 之前逐字相同。
    func testTokensUnchangedForInputWithoutRec() {
        XCTAssertEqual(
            CaptureAssist.tokens(from: "寄報價單 due:fri +business @mac due:someday +", today: today, calendar: cal),
            [
                CaptureAssist.Token(kind: .due, raw: "due:fri", displayValue: "2026-07-10"),
                CaptureAssist.Token(kind: .project, raw: "+business", displayValue: "business"),
                CaptureAssist.Token(kind: .context, raw: "@mac", displayValue: "mac"),
            ]
        )
    }

    /// `rec:` 不得干擾 due 的中文片語建議。
    func testDueSuggestionUnaffectedByRecToken() {
        XCTAssertEqual(
            CaptureAssist.dueSuggestion(from: "明天倒垃圾 rec:1w"),
            CaptureAssist.DueSuggestion(matchedText: "明天", dueValue: "tomorrow", label: "明天")
        )
    }
}
