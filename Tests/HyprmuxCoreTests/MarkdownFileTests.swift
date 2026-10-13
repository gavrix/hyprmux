import Foundation
import XCTest
@testable import HyprmuxCore

final class MarkdownFileTests: XCTestCase {
    private func viewer(_ s: String, in dir: String? = nil) -> String? {
        let url = URL(string: s) ?? URL(fileURLWithPath: s)
        return MarkdownFile.viewerURL(for: url, relativeTo: dir)?.absoluteString
    }

    func testFileURLs() {
        XCTAssertEqual(viewer("file:///tmp/a.md"), "hyprmux-md://local/tmp/a.md")
        XCTAssertEqual(viewer("file:///tmp/A.MARKDOWN"), "hyprmux-md://local/tmp/A.MARKDOWN")
        XCTAssertEqual(viewer("file:///tmp/my%20notes.md"), "hyprmux-md://local/tmp/my%20notes.md")
        XCTAssertNil(viewer("file:///tmp/a.swift"))
        XCTAssertNil(viewer("https://example.com/a.md"))
    }

    func testPlainPaths() {
        XCTAssertEqual(viewer("/tmp/a.md"), "hyprmux-md://local/tmp/a.md")
        XCTAssertEqual(viewer("/tmp/my notes.md"), "hyprmux-md://local/tmp/my%20notes.md")
        XCTAssertEqual(viewer("docs/a.md", in: "/repo"), "hyprmux-md://local/repo/docs/a.md")
        XCTAssertEqual(viewer("../a.md", in: "/repo/docs"), "hyprmux-md://local/repo/a.md")
        XCTAssertNil(viewer("docs/a.md"))
        XCTAssertEqual(MarkdownFile.viewerURL(for: URL(string: "~/a.md")!)?.path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("a.md"))
    }

    func testLines() {
        XCTAssertEqual(viewer("/tmp/a.md:42"), "hyprmux-md://local/tmp/a.md#L42")
        XCTAssertEqual(viewer("/tmp/a.md:42:7"), "hyprmux-md://local/tmp/a.md#L42")
        XCTAssertEqual(viewer("file:///tmp/a.md#L9"), "hyprmux-md://local/tmp/a.md#L9")
        XCTAssertEqual(viewer("file:///tmp/a.md#install"), "hyprmux-md://local/tmp/a.md#install")
        XCTAssertNil(viewer("/tmp/a.md:x"))
        XCTAssertEqual(MarkdownFile.lineNumber(fragment: "L3"), 3)
        XCTAssertNil(MarkdownFile.lineNumber(fragment: "L0"))
        XCTAssertNil(MarkdownFile.lineNumber(fragment: "install"))
    }

    func testViewerURLs() {
        XCTAssertEqual(viewer("hyprmux-md://local/tmp/a.md#L2"), "hyprmux-md://local/tmp/a.md#L2")
        XCTAssertNil(viewer("hyprmux-md://viewer/viewer.js"))
        let u = URL(string: "hyprmux-md://local/tmp/my%20notes.md#L2")!
        XCTAssertEqual(MarkdownFile.fileURL(fromViewer: u)?.path, "/tmp/my notes.md")
        XCTAssertTrue(MarkdownFile.isDocument(u))
        XCTAssertFalse(MarkdownFile.isDocument(URL(string: "hyprmux-md://local/tmp/a.png")!))
        XCTAssertNil(MarkdownFile.fileURL(fromViewer: URL(string: "file:///tmp/a.md")!))
    }

    func testWebAddressAndConfig() {
        XCTAssertEqual(WebAddress.resolve("hyprmux-md://local/tmp/a.md", search: "%s")?.scheme, "hyprmux-md")
        XCTAssertTrue(ConfigParser.parse("").webOpenMarkdown)
        let c = ConfigParser.parse("web {\n    open_markdown = false\n}")
        XCTAssertEqual(c.errors, [])
        XCTAssertFalse(c.webOpenMarkdown)
    }
}
