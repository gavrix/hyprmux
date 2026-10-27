// `Files`: reading and writing text files, which QML can't do on its own.
//
//   const text = Files.readText(dialog.selectedFile)
//   if (!Files.writeText(dialog.selectedFile, notes)) console.log(Files.lastError)
#pragma once

#include <QtCore/QObject>
#include <QtCore/QUrl>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;

namespace hm {

class Files : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// Why the last call failed. Empty after one that worked.
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit Files(QObject *parent) : QObject(parent) {}   // not default: see HyprmuxApp
    static Files *create(QQmlEngine *, QJSEngine *);

    /// The file's text (UTF-8). Empty, with `lastError` set, when it can't be read.
    Q_INVOKABLE QString readText(const QUrl &file);
    /// Writes `text` (UTF-8), replacing the file. False, with `lastError`, on failure.
    Q_INVOKABLE bool writeText(const QUrl &file, const QString &text);
    Q_INVOKABLE bool exists(const QUrl &file) const;
    QString lastError() const { return lastError_; }

signals:
    void lastErrorChanged();

private:
    void fail(const QString &e) { lastError_ = e; emit lastErrorChanged(); }
    QString lastError_;
};

} // namespace hm
