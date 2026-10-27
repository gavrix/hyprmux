// File, folder, and message dialogs, shown by Hyprmux as sheets over the app's
// tile (docs/CLIENT_PROTOCOL.md, section 7). Their API follows QtQuick.Dialogs,
// which doesn't ship: its dialogs would open real windows outside Hyprmux.
//
//   FileDialog {
//       id: exportDialog
//       fileMode: FileDialog.SaveFile
//       nameFilters: ["Text (*.txt)"]
//       onAccepted: save(selectedFile)
//   }
//   Button { text: "Export…"; onClicked: exportDialog.open() }
#pragma once

#include <QtCore/QObject>
#include <QtCore/QStringList>
#include <QtCore/QUrl>
#include <QtQml/qqmlregistration.h>

namespace hm {

class FileDialog : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString title MEMBER title_ NOTIFY changed)
    Q_PROPERTY(FileMode fileMode MEMBER fileMode_ NOTIFY changed)
    /// "Name (*.ext *.ext2)" entries; any `*` entry allows every file.
    Q_PROPERTY(QStringList nameFilters MEMBER nameFilters_ NOTIFY changed)
    /// Where the dialog starts.
    Q_PROPERTY(QUrl currentFolder MEMBER currentFolder_ NOTIFY changed)
    /// The chosen file. Set before opening a save dialog to suggest a name.
    Q_PROPERTY(QUrl selectedFile READ selectedFile WRITE setSelectedFile NOTIFY selectedFileChanged)
    Q_PROPERTY(QList<QUrl> selectedFiles READ selectedFiles NOTIFY selectedFileChanged)
    /// The accept button's text ("Export").
    Q_PROPERTY(QString acceptLabel MEMBER acceptLabel_ NOTIFY changed)
    Q_PROPERTY(bool visible READ isVisible NOTIFY visibleChanged)

public:
    enum FileMode { OpenFile, OpenFiles, SaveFile };
    Q_ENUM(FileMode)

    using QObject::QObject;
    QUrl selectedFile() const { return selectedFiles_.isEmpty() ? QUrl() : selectedFiles_.first(); }
    void setSelectedFile(const QUrl &u);
    QList<QUrl> selectedFiles() const { return selectedFiles_; }
    bool isVisible() const { return visible_; }

    Q_INVOKABLE void open();

signals:
    void changed();
    void selectedFileChanged();
    void visibleChanged();
    void accepted();
    void rejected();

private:
    QString title_, acceptLabel_;
    FileMode fileMode_ = OpenFile;
    QStringList nameFilters_;
    QUrl currentFolder_;
    QList<QUrl> selectedFiles_;
    bool visible_ = false;
};

class FolderDialog : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString title MEMBER title_ NOTIFY changed)
    Q_PROPERTY(QUrl currentFolder MEMBER currentFolder_ NOTIFY changed)
    Q_PROPERTY(QUrl selectedFolder READ selectedFolder NOTIFY selectedFolderChanged)
    Q_PROPERTY(QString acceptLabel MEMBER acceptLabel_ NOTIFY changed)
    Q_PROPERTY(bool visible READ isVisible NOTIFY visibleChanged)

public:
    using QObject::QObject;
    QUrl selectedFolder() const { return selectedFolder_; }
    bool isVisible() const { return visible_; }
    Q_INVOKABLE void open();

signals:
    void changed();
    void selectedFolderChanged();
    void visibleChanged();
    void accepted();
    void rejected();

private:
    QString title_, acceptLabel_;
    QUrl currentFolder_, selectedFolder_;
    bool visible_ = false;
};

class MessageDialog : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString title MEMBER title_ NOTIFY changed)
    /// The question or statement, in bold.
    Q_PROPERTY(QString text MEMBER text_ NOTIFY changed)
    /// More about it, under the text.
    Q_PROPERTY(QString informativeText MEMBER informativeText_ NOTIFY changed)
    /// MessageDialog.Ok | MessageDialog.Cancel, ... Default: Ok.
    Q_PROPERTY(int buttons MEMBER buttons_ NOTIFY changed)
    Q_PROPERTY(bool visible READ isVisible NOTIFY visibleChanged)

public:
    /// QtQuick.Dialogs' values, so code written for it works.
    enum StandardButton {
        NoButton = 0x0,
        Ok = 0x400, Save = 0x800, SaveAll = 0x1000, Open = 0x2000, Yes = 0x4000, YesToAll = 0x8000,
        No = 0x10000, NoToAll = 0x20000, Abort = 0x40000, Retry = 0x80000, Ignore = 0x100000,
        Close = 0x200000, Cancel = 0x400000, Discard = 0x800000, Help = 0x1000000, Apply = 0x2000000,
        Reset = 0x4000000, RestoreDefaults = 0x8000000,
    };
    Q_ENUM(StandardButton)

    using QObject::QObject;
    bool isVisible() const { return visible_; }
    Q_INVOKABLE void open();

signals:
    void changed();
    void visibleChanged();
    /// Every answer: the button clicked.
    void buttonClicked(int button);
    /// Ok, Save, Open, Yes, Apply, and the like.
    void accepted();
    /// Cancel, No, Close, Abort, and the like. Discard is neither.
    void rejected();

private:
    QString title_, text_, informativeText_;
    int buttons_ = Ok;
    bool visible_ = false;
};

} // namespace hm
