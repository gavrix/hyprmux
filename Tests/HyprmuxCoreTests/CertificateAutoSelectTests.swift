import XCTest
@testable import HyprmuxCore

final class CertificateAutoSelectTests: XCTestCase {
    private func rule(_ pattern: String, issuerCN: String? = nil, subjectO: String? = nil) -> String {
        var filter: [String: Any] = [:]
        if let issuerCN { filter["ISSUER"] = ["CN": issuerCN] }
        if let subjectO { filter["SUBJECT"] = ["O": subjectO] }
        let data = try! JSONSerialization.data(withJSONObject: ["pattern": pattern, "filter": filter])
        return String(decoding: data, as: UTF8.self)
    }

    private let device = CertificateNames(
        subject: CertificatePrincipal(commonName: "P - Minerva Device Trust -", organizations: ["Shopify"],
                                      organizationalUnits: ["fleet-a8f62bdf7"]),
        issuer: CertificatePrincipal(commonName: "Shopify Enterprise Production Trust Device Issuing CA G1",
                                     locality: "Ottawa", organizations: ["Shopify"]))
    private let other = CertificateNames(
        subject: CertificatePrincipal(commonName: "someone"),
        issuer: CertificatePrincipal(commonName: "Some Other CA"))

    /// The shape Shopify's device management pushes to Chrome.
    func testShopifyDevicePolicy() {
        let issuers = ["Shopify Minerva Subordinate CA", "Shopify Minerva Subordinate CA 2026",
                       "Shopify Enterprise Production Trust Device Issuing CA G1"]
        let policy = CertificateAutoSelect(entries: issuers.flatMap { cn in
            ["[*.]shopifycloud.com", "[*.]shopify.io", "[*.]shopify.com"].map { rule($0, issuerCN: cn) }
        })
        XCTAssertEqual(policy.rules.count, 9)
        XCTAssertEqual(policy.select(host: "minerva.shopifycloud.com", port: 443, certificates: [other, device]), 1)
        XCTAssertEqual(policy.select(host: "shopify.io", port: 443, certificates: [device]), 0)
        // Not a Shopify host, or no certificate from those issuers: Chromium asks.
        XCTAssertNil(policy.select(host: "example.com", port: 443, certificates: [device]))
        XCTAssertNil(policy.select(host: "evilshopify.io", port: 443, certificates: [device]))
        XCTAssertNil(policy.select(host: "vault.shopify.io", port: 443, certificates: [other]))
    }

    func testPatterns() {
        func sel(_ pattern: String, _ host: String, _ port: Int = 443) -> Int? {
            CertificateAutoSelect(entries: [rule(pattern)]).select(host: host, port: port, certificates: [device])
        }
        XCTAssertEqual(sel("[*.]example.com", "example.com"), 0)
        XCTAssertEqual(sel("[*.]example.com", "a.b.example.com", 8443), 0)
        XCTAssertNil(sel("example.com", "www.example.com"))
        XCTAssertEqual(sel("EXAMPLE.com", "example.com"), 0)
        XCTAssertEqual(sel("https://example.com", "example.com"), 0)
        XCTAssertNil(sel("https://example.com", "example.com", 8443), "a scheme without a port means its default")
        XCTAssertEqual(sel("https://example.com:8443", "example.com", 8443), 0)
        XCTAssertEqual(sel("https://example.com:*", "example.com", 8443), 0)
        XCTAssertNil(sel("http://example.com", "example.com"))
        XCTAssertEqual(sel("https://[*.]example.com/some/path", "x.example.com"), 0)
        XCTAssertEqual(sel("*", "anything.test"), 0)
    }

    func testFilters() {
        let empty = CertificateAutoSelect(entries: [rule("[*.]example.com")])
        XCTAssertEqual(empty.select(host: "example.com", port: 443, certificates: [other, device]), 0,
                       "an empty filter takes the first certificate")
        let byOrg = CertificateAutoSelect(entries: [rule("[*.]example.com", subjectO: "Shopify")])
        XCTAssertEqual(byOrg.select(host: "example.com", port: 443, certificates: [other, device]), 1)
        let both = CertificateAutoSelect(entries: [
            rule("[*.]example.com", issuerCN: "Shopify Enterprise Production Trust Device Issuing CA G1", subjectO: "Nope"),
        ])
        XCTAssertNil(both.select(host: "example.com", port: 443, certificates: [device]), "every filter field must match")
    }

    func testMalformedEntriesAreSkipped() {
        let policy = CertificateAutoSelect(entries: ["not json", "{\"filter\":{}}", "{\"pattern\":\"\"}",
                                                     "{\"pattern\":\"example.com:abc\"}", rule("[*.]ok.test")])
        XCTAssertEqual(policy.rules.count, 1)
    }
}
