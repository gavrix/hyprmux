// `Plugin`: the running plugin's manifest and settings, for QML.
//
//   Plugin.config.cpu_warn   // the user's setting, else plugin.json's default
//
// Settings live in the plugin's own folder, which Hyprmux hands over in
// HYPRMUX_PLUGIN_CONFIG_DIR and never reads: `config.json` there, a JSON object.
// Edits apply live: `config` changes, and bindings on it update.
#pragma once

#include "PluginSettings.h"

#include <QtCore/QFileSystemWatcher>
#include <QtCore/QObject>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;

namespace hm {

class Plugin : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString id READ id CONSTANT)
    Q_PROPERTY(QString name READ name CONSTANT)
    /// The plugin's folder, for its own files.
    Q_PROPERTY(QString dir READ dir CONSTANT)
    /// The plugin's settings folder. It may not exist yet.
    Q_PROPERTY(QString configDir READ configDir CONSTANT)
    /// plugin.json's `config` defaults, with the settings file's values on top.
    Q_PROPERTY(QVariantMap config READ config NOTIFY configChanged)

public:
    // No default constructor: with one, QML would make its own instance instead of
    // calling create(), and miss the host's (qqmlprivate.h, singletonConstructionMode).
    explicit Plugin(QObject *parent) : QObject(parent) {}
    static Plugin *create(QQmlEngine *, QJSEngine *);

    /// Reads DIR/plugin.json and the settings file, and watches the settings. False,
    /// with `error` set, when the manifest can't be read. A broken settings file only
    /// logs: the defaults stand.
    bool load(const QString &dir, QString *error);

    QString id() const { return manifest_.id; }
    QString name() const { return manifest_.name; }
    QString dir() const { return dir_; }
    QString configDir() const { return configDir_; }
    QVariantMap config() const { return config_; }
    QString barItem() const { return manifest_.barItem; }
    QSet<QString> permissions() const { return manifest_.permissions; }

signals:
    void configChanged();

private:
    void readSettings();
    void watch();

    PluginManifest manifest_;
    QString dir_, configDir_;
    QVariantMap config_;
    QFileSystemWatcher watcher_;
};

} // namespace hm
