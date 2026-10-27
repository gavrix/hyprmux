#include "Plugin.h"

#include "../Host.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtQml/QJSEngine>

#include <cstdio>

namespace hm {

Plugin *Plugin::create(QQmlEngine *, QJSEngine *) {
    Plugin *p = Host::get().plugin();
    QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership);
    return p;
}

bool Plugin::load(const QString &dir, QString *error) {
    dir_ = QDir(dir).absolutePath();
    QFile file(QDir(dir_).filePath("plugin.json"));
    if (!file.open(QIODevice::ReadOnly)) {
        *error = "no plugin.json in " + dir_;
        return false;
    }
    auto m = PluginManifest::parse(file.readAll(), error);
    if (!m) return false;
    manifest_ = *m;
    // Hyprmux names the folder. Started by hand, the plugin uses the same default.
    configDir_ = qEnvironmentVariable("HYPRMUX_PLUGIN_CONFIG_DIR");
    if (configDir_.isEmpty()) configDir_ = QDir::homePath() + "/.config/hyprmux/plugin-config/" + manifest_.id;
    readSettings();
    watch();
    return true;
}

void Plugin::readSettings() {
    QFile file(QDir(configDir_).filePath("config.json"));
    QByteArray contents = file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
    QString warning;
    QVariantMap merged = mergeSettings(manifest_.defaults, contents, &warning);
    if (!warning.isEmpty())
        std::fprintf(stderr, "hyprmux-qml: %s: %s; using the defaults\n", qPrintable(file.fileName()), qPrintable(warning));
    if (merged == config_) return;
    config_ = merged;
    emit configChanged();
}

/// Watches the folder as well as the file: editors save by replacing the file, which
/// ends a watch on it, and the folder may not exist until the user makes it.
void Plugin::watch() {
    auto rewatch = [this] {
        QString path = QDir(configDir_).filePath("config.json");
        QStringList want;
        // The nearest folder that exists, so creating plugin-config/<id>/ is noticed.
        QString dir = configDir_;
        while (!QFileInfo::exists(dir) && dir != QDir::rootPath()) dir = QFileInfo(dir).absolutePath();
        want << dir;
        if (QFileInfo::exists(path)) want << path;
        for (const QString &w : want)
            if (!watcher_.files().contains(w) && !watcher_.directories().contains(w)) watcher_.addPath(w);
    };
    auto changed = [this, rewatch] {
        rewatch();
        readSettings();
    };
    connect(&watcher_, &QFileSystemWatcher::fileChanged, this, changed);
    connect(&watcher_, &QFileSystemWatcher::directoryChanged, this, changed);
    rewatch();
}

} // namespace hm
