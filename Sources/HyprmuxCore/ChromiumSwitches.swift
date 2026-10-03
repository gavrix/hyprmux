import Foundation

/// Builds the Chromium command-line switches Hyprmux starts CEF with.
public enum ChromiumSwitches {
    /// Features Hyprmux turns on unless the user's flags turn them off.
    ///
    /// `ThrottleResizeIpc`: on Mac, Chromium 154 sends the renderer every size of a
    /// drag resize, without waiting for it to finish the previous one. Slow pages
    /// then replay every size after the drag ends. With the feature on, the
    /// renderer gets one size at a time and skips to the latest.
    public static let defaultEnabledFeatures = ["ThrottleResizeIpc"]

    /// Chrome 137+ ignores `--load-extension` unless this feature is off.
    static let loadExtensionFeature = "DisableLoadExtensionCommandLineSwitch"

    /// User flags, plus the extensions to load and Hyprmux's default features.
    ///
    /// Chromium keeps only the last `enable-features` and `disable-features`
    /// switch, so every value goes into one switch of each kind. A feature the
    /// user disables is never enabled by default.
    public static func build(flags: [String], extensions: [String]) -> [String] {
        var out: [String] = []
        var enabled: [String] = []
        var disabled: [String] = []
        for flag in flags {
            switch featureSwitch(flag) {
            case let ("enable-features", values)?: enabled.append(contentsOf: values)
            case let ("disable-features", values)?: disabled.append(contentsOf: values)
            default: out.append(flag)
            }
        }
        if !extensions.isEmpty {
            out.append("load-extension=" + extensions.joined(separator: ","))
            disabled.append(loadExtensionFeature)
        }
        let off = Set(disabled.map(featureName))
        enabled.append(contentsOf: defaultEnabledFeatures)
        enabled = unique(enabled.filter { !off.contains(featureName($0)) })
        disabled = unique(disabled)
        if !enabled.isEmpty { out.append("enable-features=" + enabled.joined(separator: ",")) }
        if !disabled.isEmpty { out.append("disable-features=" + disabled.joined(separator: ",")) }
        return out
    }

    /// The switch name and its feature list, for `enable-features` and `disable-features`.
    private static func featureSwitch(_ raw: String) -> (String, [String])? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("-") { s.removeFirst() }
        let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard name == "enable-features" || name == "disable-features" else { return nil }
        let value = parts.count > 1 ? String(parts[1]) : ""
        let features = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (name, features)
    }

    /// `Name` from `Name`, `Name:param/value`, or `Name<Trial`.
    private static func featureName(_ entry: String) -> String {
        String(entry.prefix { $0 != ":" && $0 != "<" })
    }

    /// Drops later entries for a feature already listed.
    private static func unique(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { seen.insert(featureName($0)).inserted }
    }
}
