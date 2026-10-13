import Foundation

// Chrome's AutoSelectCertificateForUrls policy: which client certificate to send, without
// asking, when a site requests one (mutual TLS). Hyprmux's Chromium is a separate app and
// doesn't get Chrome's managed policies, so Hyprmux reads Chrome's and applies the same rules.
// https://chromeenterprise.google/policies/#AutoSelectCertificateForUrls

/// The name fields of a certificate's subject or issuer that a policy filter can test.
public struct CertificatePrincipal: Equatable, Sendable {
    public var commonName: String
    public var locality: String
    public var organizations: [String]
    public var organizationalUnits: [String]

    public init(commonName: String = "", locality: String = "", organizations: [String] = [],
                organizationalUnits: [String] = []) {
        self.commonName = commonName
        self.locality = locality
        self.organizations = organizations
        self.organizationalUnits = organizationalUnits
    }
}

public struct CertificateNames: Equatable, Sendable {
    public var subject: CertificatePrincipal
    public var issuer: CertificatePrincipal

    public init(subject: CertificatePrincipal, issuer: CertificatePrincipal) {
        self.subject = subject
        self.issuer = issuer
    }
}

public struct CertificateAutoSelect: Equatable, Sendable {
    /// One policy entry: `{"pattern": "[*.]example.com", "filter": {"ISSUER": {"CN": "..."}}}`.
    public struct Rule: Equatable, Sendable {
        public var pattern: SitePattern
        public var issuer: Filter?
        public var subject: Filter?
    }

    /// Chrome's filter fields. Each one set must match; an empty filter matches any certificate.
    public struct Filter: Equatable, Sendable {
        public var commonName: String?
        public var locality: String?
        public var organization: String?
        public var organizationalUnit: String?

        init?(_ json: Any?) {
            guard let json else { return nil }
            guard let d = json as? [String: Any] else { return nil }
            commonName = d["CN"] as? String
            locality = d["L"] as? String
            organization = d["O"] as? String
            organizationalUnit = d["OU"] as? String
        }

        func matches(_ p: CertificatePrincipal) -> Bool {
            if let commonName, commonName != p.commonName { return false }
            if let locality, locality != p.locality { return false }
            if let organization, !p.organizations.contains(organization) { return false }
            if let organizationalUnit, !p.organizationalUnits.contains(organizationalUnit) { return false }
            return true
        }
    }

    /// A content-settings pattern as the policy writes it: `[*.]example.com`,
    /// `https://www.example.com:443`, `*`. A path is ignored.
    public struct SitePattern: Equatable, Sendable {
        /// Nil: any scheme.
        var scheme: String?
        /// Nil: any host.
        var host: String?
        /// `[*.]`: the host and its subdomains.
        var subdomains: Bool
        /// Nil: any port, or the scheme's default when a scheme is given.
        var port: Int?
        var anyPort: Bool

        public init?(_ raw: String) {
            var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty else { return nil }
            scheme = nil
            if let r = s.range(of: "://") {
                let sch = String(s[..<r.lowerBound])
                scheme = sch == "*" ? nil : sch
                s = String(s[r.upperBound...])
            }
            if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
            port = nil
            anyPort = false
            if let colon = s.lastIndex(of: ":") {
                let p = String(s[s.index(after: colon)...])
                if p == "*" { anyPort = true } else if let n = Int(p) { port = n } else { return nil }
                s = String(s[..<colon])
            }
            subdomains = s.hasPrefix("[*.]")
            if subdomains { s.removeFirst(4) }
            if s == "*" { host = nil } else if s.isEmpty { return nil } else { host = s }
        }

        func matches(scheme reqScheme: String, host reqHost: String, port reqPort: Int) -> Bool {
            if let scheme, scheme != reqScheme { return false }
            if let host {
                let h = reqHost.lowercased()
                guard h == host || (subdomains && h.hasSuffix("." + host)) else { return false }
            }
            if anyPort { return true }
            if let port { return port == reqPort }
            // No port: any, unless a scheme was given, which means its default port.
            guard let scheme else { return true }
            return reqPort == (scheme == "http" ? 80 : scheme == "https" ? 443 : reqPort)
        }
    }

    public private(set) var rules: [Rule]

    /// Each entry is a JSON string, as the policy stores them. Malformed entries are skipped.
    public init(entries: [String]) {
        rules = entries.compactMap { entry in
            guard let data = entry.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = d["pattern"] as? String, let pattern = SitePattern(raw) else { return nil }
            let filter = d["filter"] as? [String: Any] ?? [:]
            return Rule(pattern: pattern, issuer: Filter(filter["ISSUER"]), subject: Filter(filter["SUBJECT"]))
        }
    }

    /// The certificate to send to `host:port`: the first one a matching rule's filter accepts,
    /// as Chrome does. Nil: no rule applies, so the user is asked.
    public func select(scheme: String = "https", host: String, port: Int, certificates: [CertificateNames]) -> Int? {
        let applicable = rules.filter { $0.pattern.matches(scheme: scheme, host: host, port: port) }
        guard !applicable.isEmpty else { return nil }
        return certificates.firstIndex { cert in
            applicable.contains { rule in
                (rule.issuer?.matches(cert.issuer) ?? true) && (rule.subject?.matches(cert.subject) ?? true)
            }
        }
    }
}
