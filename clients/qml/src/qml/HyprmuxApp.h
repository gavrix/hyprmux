// `HyprmuxApp`: how Hyprmux launched this app.
//
//   HyprmuxWindow {
//       restoreToken: "main"
//       Connections {
//           target: HyprmuxApp
//           // A restored session: bring back the windows it had.
//           function onLaunched() {
//               for (const t of HyprmuxApp.restoreTokens)
//                   if (t.startsWith("note:")) noteWindow.createObject(null, { restoreToken: t })
//           }
//       }
//   }
#pragma once

#include <QtCore/QObject>
#include <QtCore/QStringList>
#include <QtCore/QVariantList>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;

namespace hm {

class HyprmuxApp : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// The arguments of the latest launch (`hyprmuxctl launch Name ARGS`).
    Q_PROPERTY(QStringList arguments READ arguments NOTIFY launched)
    /// When Hyprmux restores a session: the restore tokens of the windows the app
    /// had. A window with one of them goes back into its tile. Empty otherwise.
    Q_PROPERTY(QStringList restoreTokens READ restoreTokens NOTIFY launched)

public:
    // No default constructor: QML would make its own instance instead of create().
    explicit HyprmuxApp(QObject *parent) : QObject(parent) {}
    static HyprmuxApp *create(QQmlEngine *, QJSEngine *);

    QStringList arguments() const { return arguments_; }
    QStringList restoreTokens() const { return restoreTokens_; }

    /// Instead of a window, offers windows to open: `[{id, title, detail}]`. With
    /// one, Hyprmux opens it; with several, the user picks in Hyprmux's picker.
    /// Either way `openRequested(id)` follows. Only in `launched`.
    Q_INVOKABLE void offer(const QVariantList &windows);

    // For Host:
    void setLaunch(const QStringList &args, const QStringList &tokens) {
        arguments_ = args;
        restoreTokens_ = tokens;
        offered_ = false;
        emit launched();
    }
    bool takeOffered() { bool o = offered_; offered_ = false; return o; }

signals:
    /// Hyprmux started the app, or launched it again (an `"instances": "single"`
    /// app). Open windows here: the windows `restoreTokens` names, or what the
    /// arguments ask for, or `offer` a choice. A launch that opens nothing
    /// ends quietly.
    void launched();
    /// The user picked an offered window: open it now.
    void openRequested(const QString &id);

private:
    QStringList arguments_, restoreTokens_;
    bool offered_ = false;
};

} // namespace hm
