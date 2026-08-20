import XCTest
@testable import txtnimalCore

final class LinkMarkupTests: XCTestCase {

    func testLabeledURLAfterCommaBecomesMarkdownAndDropsTheURL() {
        let rewritten = LinkMarkup.rewrite("連結請參考 yahoo,https://yahoo.com")
        XCTAssertEqual(rewritten, "連結請參考 [yahoo](https://yahoo.com)")
        XCTAssertEqual(
            LinkMarkup.segments("連結請參考 yahoo,https://yahoo.com"),
            [
                .text("連結請參考 "),
                .link(label: "yahoo", url: URL(string: "https://yahoo.com")!),
            ]
        )
    }

    func testLabeledURLAfterSpace() {
        XCTAssertEqual(
            LinkMarkup.rewrite("see docs https://example.com/path"),
            "see [docs](https://example.com/path)"
        )
    }

    func testChineseCommaAndTrailingPunctuation() {
        XCTAssertEqual(
            LinkMarkup.rewrite("請看 雅虎，https://yahoo.com。"),
            "請看 [雅虎](https://yahoo.com)。"
        )
    }

    func testGitHubURLBecomesGithubOwnerRepoLabel() {
        let url = "https://github.com/ZhuLinsen/daily_stock_analysis"
        XCTAssertEqual(
            LinkMarkup.rewrite(url),
            "[Github:ZhuLinsen/daily_stock_analysis](\(url))"
        )
        XCTAssertEqual(
            LinkMarkup.segments(url),
            [.link(label: "Github:ZhuLinsen/daily_stock_analysis",
                   url: URL(string: url)!)]
        )
    }

    func testGitHubDeepLinkKeepsFullHrefButRepoLabel() {
        let url = "https://github.com/ZhuLinsen/daily_stock_analysis/blob/main/README.md"
        let rewritten = LinkMarkup.rewrite(url)
        XCTAssertEqual(rewritten, "[Github:ZhuLinsen/daily_stock_analysis](\(url))")
    }

    func testLabeledGitHubKeepsTheTypedLabel() {
        XCTAssertEqual(
            LinkMarkup.rewrite("分析,https://github.com/ZhuLinsen/daily_stock_analysis"),
            "[分析](https://github.com/ZhuLinsen/daily_stock_analysis)"
        )
    }

    func testBareNonGitHubURLStaysVisibleAndClickable() {
        XCTAssertEqual(LinkMarkup.rewrite("https://example.com"), "https://example.com")
        XCTAssertEqual(
            LinkMarkup.segments("https://example.com"),
            [.link(label: "https://example.com", url: URL(string: "https://example.com")!)]
        )
    }

    func testAlreadyMarkdownIsNotDoubleWrapped() {
        let source = "see [yahoo](https://yahoo.com) please"
        XCTAssertEqual(LinkMarkup.rewrite(source), source)
        XCTAssertEqual(
            LinkMarkup.segments(source),
            [
                .text("see "),
                .link(label: "yahoo", url: URL(string: "https://yahoo.com")!),
                .text(" please"),
            ]
        )
    }

    func testMultipleLinksInOneParagraph() {
        let source = "yahoo,https://yahoo.com\nhttps://github.com/acme/app"
        XCTAssertEqual(
            LinkMarkup.rewrite(source),
            "[yahoo](https://yahoo.com)\n[Github:acme/app](https://github.com/acme/app)"
        )
    }

    func testNoteCaptureRewritesLinksInTheBody() {
        let draft = NoteCapture.parse("連結請參考 yahoo,https://yahoo.com #ref")
        XCTAssertEqual(draft?.kind, .plain)
        XCTAssertEqual(draft?.tags, ["ref"])
        XCTAssertEqual(draft?.body, "連結請參考 [yahoo](https://yahoo.com)")
    }

    func testGitHubDotGitSuffixIsStrippedFromLabel() {
        XCTAssertEqual(
            LinkMarkup.githubLabel(for: URL(string: "https://github.com/acme/app.git")!),
            "Github:acme/app"
        )
    }
}
