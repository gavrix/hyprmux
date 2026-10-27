#include "PluginSettings.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>

namespace hm {

std::optional<PluginManifest> PluginManifest::parse(const QByteArray &json, QString *error) {
    QJsonParseError parse;
    QJsonDocument doc = QJsonDocument::fromJson(json, &parse);
    if (parse.error != QJsonParseError::NoError) {
        *error = "plugin.json: " + parse.errorString();
        return std::nullopt;
    }
    if (!doc.isObject()) {
        *error = "plugin.json isn't a JSON object";
        return std::nullopt;
    }
    QJsonObject o = doc.object();
    PluginManifest m;
    m.id = o.value("id").toString();
    if (m.id.isEmpty()) {
        *error = "plugin.json has no id";
        return std::nullopt;
    }
    m.name = o.value("name").toString(m.id);
    m.barItem = o.value("contributes").toObject().value("bar").toObject().value("item").toString();
    for (const QJsonValue &p : o.value("permissions").toArray()) m.permissions.insert(p.toString());
    m.defaults = o.value("config").toObject().toVariantMap();
    return m;
}

QVariantMap mergeSettings(const QVariantMap &defaults, const QByteArray &settingsFile, QString *warning) {
    QVariantMap merged = defaults;
    if (settingsFile.trimmed().isEmpty()) return merged;
    QJsonParseError parse;
    QJsonDocument doc = QJsonDocument::fromJson(settingsFile, &parse);
    if (parse.error != QJsonParseError::NoError) {
        if (warning) *warning = parse.errorString();
        return merged;
    }
    if (!doc.isObject()) {
        if (warning) *warning = "not a JSON object";
        return merged;
    }
    QJsonObject o = doc.object();
    for (auto it = o.begin(); it != o.end(); ++it) merged.insert(it.key(), it.value().toVariant());
    return merged;
}

} // namespace hm
