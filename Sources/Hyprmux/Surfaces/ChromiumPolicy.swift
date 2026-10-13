import ChromiumBridge
import Foundation
import HyprmuxCore

/// Where the Chromium profile lives. HYPRMUX_CHROMIUM_PROFILE moves it, so a second
/// instance can run (Chromium allows one process per profile).
enum ChromiumProfile {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["HYPRMUX_CHROMIUM_PROFILE"], !p.isEmpty { return p }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hyprmux/Chromium").path
    }
}

/// Google Chrome's managed policies that Hyprmux's Chromium applies too. Managed policies
/// arrive per app (by bundle id), so Hyprmux's own Chromium never gets Chrome's.
enum ChromeManagedPolicy {
    private static let chrome = "com.google.Chrome" as CFString

    /// AutoSelectCertificateForUrls, if device management sets it. Only forced (managed)
    /// values count, as in Chrome; a value someone wrote with `defaults` is ignored.
    static var certificateAutoSelect: CertificateAutoSelect {
        let key = "AutoSelectCertificateForUrls" as CFString
        CFPreferencesAppSynchronize(chrome)
        guard CFPreferencesAppValueIsForced(key, chrome),
              let entries = CFPreferencesCopyAppValue(key, chrome) as? [String] else { return CertificateAutoSelect(entries: []) }
        return CertificateAutoSelect(entries: entries)
    }
}

extension CertificatePrincipal {
    init(_ p: HMCertificatePrincipal) {
        self.init(commonName: p.commonName, locality: p.locality,
                  organizations: p.organizations, organizationalUnits: p.organizationalUnits)
    }
}
