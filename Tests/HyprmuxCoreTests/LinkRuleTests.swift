import Foundation
import XCTest
@testable import HyprmuxCore

final class LinkRuleTests: XCTestCase {
    private func rule(_ s: String) -> LinkRule? { try? LinkRule.parse(s).get() }
    private func url(_ s: String) -> URL { URL(string: s) ?? URL(fileURLWithPath: s) }

    func testParse() {
        XCTAssertEqual(rule("scheme:source ext:md, web"), LinkRule(scheme: "source", ext: "md", action: .web))
        XCTAssertEqual(rule("scheme:source, exec, nvim"), LinkRule(scheme: "source", action: .exec("nvim")))
        XCTAssertEqual(rule("SCHEME:Zed, launch, Visual Studio Code"), LinkRule(scheme: "zed", action: .launch("Visual Studio Code")))
        XCTAssertEqual(rule("ext:.MD, web"), LinkRule(ext: "md", action: .web))
        XCTAssertEqual(rule("scheme:source:, exec, nvim -c 'set ft=swift', -R"),
                       LinkRule(scheme: "source", action: .exec("nvim -c 'set ft=swift', -R")))
    }

    func testParseErrors() {
        for bad in ["", "scheme:source", ", web", "scheme:, web", "host:x, web", "scheme:a scheme:b, web",
                    "scheme:source, exec", "scheme:source, launch", "scheme:source, web, x", "scheme:source, open, x"] {
            XCTAssertNil(rule(bad), bad)
        }
    }

    func testMatching() {
        let md = LinkRule(scheme: "source", ext: "md", action: .web)
        XCTAssertTrue(md.matches(url("source:///a/b.md")))
        XCTAssertTrue(md.matches(url("SOURCE:///a/B.MD#L12")))
        XCTAssertTrue(md.matches(url("source:///a/b.md:42")))
        XCTAssertTrue(md.matches(url("source:///a/b.md:42:7")))
        XCTAssertFalse(md.matches(url("source:///a/b.swift#L3")))
        XCTAssertFalse(md.matches(url("file:///a/b.md")))
        XCTAssertFalse(md.matches(url("source:///a/md")))

        let anyMarkdown = LinkRule(ext: "md", action: .web)
        XCTAssertTrue(anyMarkdown.matches(url("docs/a.md:3")), "a scheme-less path")
        XCTAssertTrue(anyMarkdown.matches(url("/tmp/my notes.md")))
    }

    func testFirstMatchWins() {
        let rules = [LinkRule(scheme: "source", ext: "md", action: .web),
                     LinkRule(scheme: "source", action: .exec("nvim")),
                     LinkRule(scheme: "source", ext: "swift", action: .launch("Zed"))]
        XCTAssertEqual(LinkRule.first(matching: url("source:///a.md#L2"), in: rules)?.action, .web)
        XCTAssertEqual(LinkRule.first(matching: url("source:///a.swift"), in: rules)?.action, .exec("nvim"))
        XCTAssertNil(LinkRule.first(matching: url("https://example.com/a.md"), in: rules))
    }

    func testConfigLines() {
        let c = ConfigParser.parse("linkrule = scheme:source ext:md, web\nlinkrule = scheme:source, exec, nvim\nlinkrule = scheme:x")
        XCTAssertEqual(c.linkRules.map(\.action), [.web, .exec("nvim")])
        XCTAssertEqual(c.errors.count, 1)
        XCTAssertTrue(ConfigParser.parse(defaultConfig).linkRules.isEmpty)
    }

    func testSourceLinksAreLocalFiles() {
        XCTAssertEqual(MarkdownFile.viewerURL(for: url("source:///tmp/a.md#L9"))?.absoluteString, "hyprmux-md://local/tmp/a.md#L9")
        XCTAssertEqual(MarkdownFile.viewerURL(for: url("source:///tmp/a.md:4"))?.absoluteString, "hyprmux-md://local/tmp/a.md#L4")
        XCTAssertNil(MarkdownFile.viewerURL(for: url("source:///tmp/a.swift")))
        XCTAssertEqual(WebAddress.resolve("source:///tmp/a.md#L9", search: "%s")?.scheme, "source")
    }
}
