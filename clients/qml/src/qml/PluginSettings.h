// A plugin's manifest and settings, without Qt objects: parsing and merging, so
// they test on their own.
#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QSet>
#include <QtCore/QString>
#include <QtCore/QVariantMap>

#include <optional>

namespace hm {

struct PluginManifest {
    QString id, name;
    /// `contributes.bar.item`: the bar item's QML file, relative to the plugin. Empty if none.
    QString barItem;
    QSet<QString> permissions;
    /// `config`: the settings' defaults.
    QVariantMap defaults;

    /// plugin.json's contents. Empty, with `error` set, when it isn't a manifest.
    static std::optional<PluginManifest> parse(const QByteArray &json, QString *error);
};

/// The settings in effect: `defaults`, with the settings file's values on top. The
/// file may be empty (missing). A file that isn't a JSON object leaves the defaults,
/// and says why in `warning`.
QVariantMap mergeSettings(const QVariantMap &defaults, const QByteArray &settingsFile, QString *warning);

} // namespace hm
