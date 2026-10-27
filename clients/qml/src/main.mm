// hyprmux-qml: renders QML into Hyprmux surfaces.
//
//   hyprmux-qml FILE.qml        an app: its HyprmuxWindows are tiles (a plain Item
//                               root is one tile; a BarItem root is a bar item)
//   hyprmux-qml PLUGIN_DIR      a plugin: PLUGIN_DIR/plugin.json names its QML
//
// See docs/QML.md and docs/PLUGINS.md. The `Hyprmux` QML module is compiled in; its
// types are declared with QML_ELEMENT, so qmllint and qmlls know it.

#include "Host.h"
#include "protocol/Connection.h"
#include "qml/Plugin.h"

#import <AppKit/AppKit.h>

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLoggingCategory>
#include <QtGui/QGuiApplication>
#include <QtGui/qpa/qwindowsysteminterface.h>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickWindow>

#include <cstdio>

static int usage() {
    std::fprintf(stderr, "usage: hyprmux-qml FILE.qml\n       hyprmux-qml PLUGIN_DIR\n");
    return 64;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
    // Core Text glyphs, like the AppKit text around them. Qt's distance-field text
    // tints glyph edges with subpixel colors on a transparent surface.
    QQuickWindow::setTextRenderType(QQuickWindow::NativeTextRendering);
    // Qt Quick Controls' default on macOS is its macOS style, which the app doesn't
    // ship: Basic is the one style bundled (scripts/deploy-qt.sh). It draws from the
    // palette, which Theme fills with Hyprmux's colors.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    // Shortcut matching asks the key mapper about keys that came from Hyprmux, not from
    // this process's own NSEvents; it maps them anyway, after a warning per key.
    QLoggingCategory::setFilterRules("qt.qpa.keymapper.warning=false");
    QGuiApplication app(argc, argv);
    // Surfaces, not windows: no Dock icon and no menu bar.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // Input from Hyprmux goes through Qt's window-system queue (InputBridge); deliver
    // it at once, in order.
    QWindowSystemInterface::setSynchronousWindowSystemEvents(true);
    // The host decides when to quit: when its last tile closes.
    app.setQuitOnLastWindowClosed(false);

    hm::Host &host = hm::Host::get();
    hm::Plugin *plugin = host.plugin();
    QString qmlPath, appID, name;
    // A folder is a plugin. Not a --plugin flag: Qt claims -plugin for its own plugins.
    QString arg = QString::fromLocal8Bit(argv[1]);
    if (QFileInfo(arg).isDir()) {
        QString error;
        if (!plugin->load(arg, &error)) {
            std::fprintf(stderr, "hyprmux-qml: %s\n", qPrintable(error));
            return 65;
        }
        if (plugin->barItem().isEmpty()) {
            std::fprintf(stderr, "hyprmux-qml: %s contributes no bar item\n", qPrintable(plugin->id()));
            return 65;
        }
        qmlPath = QDir(plugin->dir()).filePath(plugin->barItem());
        appID = plugin->id();
        name = plugin->name();
    } else {
        qmlPath = arg;
        name = QFileInfo(qmlPath).completeBaseName();
        appID = "dev.gavrix.hyprmux.qml." + name;
        // An app in a .hmapp takes its id and name from the bundle's Info.json.
        QFile info(QFileInfo(qmlPath).absoluteDir().filePath("Info.json"));
        if (QFileInfo(qmlPath).absolutePath().endsWith(".hmapp") && info.open(QIODevice::ReadOnly)) {
            QJsonObject o = QJsonDocument::fromJson(info.readAll()).object();
            if (!o.value("id").toString().isEmpty()) appID = o.value("id").toString();
            if (!o.value("name").toString().isEmpty()) name = o.value("name").toString();
        }
    }
    QFileInfo file(qmlPath);
    if (!file.exists()) {
        std::fprintf(stderr, "hyprmux-qml: no such file: %s\n", qPrintable(qmlPath));
        return 66;
    }
    app.setApplicationName(name);
    // Where QtCore's `Settings` keeps an app's settings:
    // ~/Library/Preferences/dev.gavrix.hyprmux.qml.<name>.plist, apart from
    // Hyprmux's own defaults (dev.gavrix.hyprmux.<instance>).
    app.setOrganizationName("Hyprmux");
    app.setOrganizationDomain("qml.hyprmux.gavrix.dev");

    std::string error;
    hm::Connection *conn = hm::Connection::connect(appID.toStdString(), name.toStdString(), &error);
    if (!conn) {
        std::fprintf(stderr, "hyprmux-qml: %s\n", error.c_str());
        return 69;
    }
    conn->setDisconnectHandler([](const std::string &reason) {
        std::fprintf(stderr, "hyprmux-qml: %s\n", reason.c_str());
        QCoreApplication::exit(0);
    });
    conn->setHandler([&host](const hm::Event &e) {
        if (e.op() == "error") {
            std::fprintf(stderr, "hyprmux-qml: protocol error %s: %s\n", e.str("code").c_str(), e.str("message").c_str());
            return;
        }
        host.handle(e);
    });
    host.setConnection(conn);

    QQmlEngine engine;
    QObject::connect(&engine, &QQmlEngine::quit, &app, &QCoreApplication::quit);
    QString loadError;
    if (!host.load(&engine, file.absoluteFilePath(), &loadError)) {
        std::fprintf(stderr, "hyprmux-qml: %s\n", qPrintable(loadError));
        return 1;
    }
    return app.exec();
}
