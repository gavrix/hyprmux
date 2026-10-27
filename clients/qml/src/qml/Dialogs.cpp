#include "Dialogs.h"

#include "../Host.h"
#include "../protocol/Connection.h"
#include "../scene/Scene.h"
#include "WindowUI.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QPointer>

#include <cstdio>

namespace hm {

namespace {

/// Asks Hyprmux for a dialog over `owner`'s tile. `reply` gets `result_json`, or
/// nothing when there's no tile to show it over.
bool showDialog(QObject *owner, const char *kind, const QJsonObject &options, std::function<void(QJsonObject)> reply) {
    Host &host = Host::get();
    Scene *tile = host.tileFor(owner);
    if (!tile || !host.connection()) {
        std::fprintf(stderr, "hyprmux-qml: a dialog needs an open window to show over\n");
        return false;
    }
    uint64_t id = host.expectReply([reply](const Event &e) {
        reply(QJsonDocument::fromJson(QByteArray::fromStdString(e.str("result_json"))).object());
    });
    Message m("dialog.open");
    m.u64("id", id).u64("surface", tile->surfaceID()).str("kind", kind)
        .str("options_json", QJsonDocument(options).toJson(QJsonDocument::Compact).toStdString());
    host.connection()->send(m);
    return true;
}

} // namespace

// MARK: FileDialog

void FileDialog::setSelectedFile(const QUrl &u) {
    if (selectedFiles_.size() == 1 && selectedFiles_.first() == u) return;
    selectedFiles_ = u.isEmpty() ? QList<QUrl>() : QList<QUrl>{u};
    emit selectedFileChanged();
}

void FileDialog::open() {
    if (visible_) return;
    QJsonObject o{{"title", title_}, {"filters", dialogFilters(nameFilters_)}};
    if (!acceptLabel_.isEmpty()) o["buttonLabel"] = acceptLabel_;
    // A save dialog starts with the suggested file, others in the folder.
    QString start = currentFolder_.toLocalFile();
    if (fileMode_ == SaveFile && !selectedFile().isEmpty()) {
        QString file = selectedFile().isLocalFile() ? selectedFile().toLocalFile() : selectedFile().path(QUrl::FullyDecoded);
        start = file.contains('/') ? file : (start.isEmpty() ? file : start + "/" + file);
    }
    if (!start.isEmpty()) o["defaultPath"] = start;
    QJsonArray props{"createDirectory"};
    if (fileMode_ != SaveFile) props.append("openFile");
    if (fileMode_ == OpenFiles) props.append("multiSelections");
    o["properties"] = props;

    // The dialog object may be gone by the time the user answers.
    QPointer<FileDialog> self(this);
    bool shown = showDialog(this, fileMode_ == SaveFile ? "save" : "open", o, [self](QJsonObject r) {
        if (!self) return;
        FileDialog *d = self;
        d->visible_ = false;
        emit d->visibleChanged();
        if (r.value("canceled").toBool(true)) { emit d->rejected(); return; }
        QList<QUrl> urls;
        if (d->fileMode_ == SaveFile) urls << QUrl::fromLocalFile(r.value("filePath").toString());
        else for (const QJsonValue &p : r.value("filePaths").toArray()) urls << QUrl::fromLocalFile(p.toString());
        d->selectedFiles_ = urls;
        emit d->selectedFileChanged();
        emit d->accepted();
    });
    if (!shown) { emit rejected(); return; }
    visible_ = true;
    emit visibleChanged();
}

// MARK: FolderDialog

void FolderDialog::open() {
    if (visible_) return;
    QJsonObject o{{"title", title_}, {"properties", QJsonArray{"openDirectory", "createDirectory"}}};
    if (!acceptLabel_.isEmpty()) o["buttonLabel"] = acceptLabel_;
    if (!currentFolder_.isEmpty()) o["defaultPath"] = currentFolder_.toLocalFile();
    QPointer<FolderDialog> self(this);
    bool shown = showDialog(this, "open", o, [self](QJsonObject r) {
        if (!self) return;
        FolderDialog *d = self;
        d->visible_ = false;
        emit d->visibleChanged();
        QJsonArray paths = r.value("filePaths").toArray();
        if (r.value("canceled").toBool(true) || paths.isEmpty()) { emit d->rejected(); return; }
        d->selectedFolder_ = QUrl::fromLocalFile(paths.first().toString());
        emit d->selectedFolderChanged();
        emit d->accepted();
    });
    if (!shown) { emit rejected(); return; }
    visible_ = true;
    emit visibleChanged();
}

// MARK: MessageDialog

namespace {

struct ButtonInfo {
    MessageDialog::StandardButton button;
    const char *label;
    enum Role { Accept, Reject, Destructive, Other } role;
};

/// In NSAlert's order: the default first (rightmost), then Cancel, then the rest.
const ButtonInfo kButtons[] = {
    {MessageDialog::Ok, "OK", ButtonInfo::Accept}, {MessageDialog::Save, "Save", ButtonInfo::Accept},
    {MessageDialog::SaveAll, "Save All", ButtonInfo::Accept}, {MessageDialog::Open, "Open", ButtonInfo::Accept},
    {MessageDialog::Yes, "Yes", ButtonInfo::Accept}, {MessageDialog::YesToAll, "Yes to All", ButtonInfo::Accept},
    {MessageDialog::Apply, "Apply", ButtonInfo::Accept}, {MessageDialog::Retry, "Retry", ButtonInfo::Accept},
    {MessageDialog::Cancel, "Cancel", ButtonInfo::Reject}, {MessageDialog::Close, "Close", ButtonInfo::Reject},
    {MessageDialog::Abort, "Abort", ButtonInfo::Reject}, {MessageDialog::No, "No", ButtonInfo::Reject},
    {MessageDialog::NoToAll, "No to All", ButtonInfo::Reject}, {MessageDialog::Ignore, "Ignore", ButtonInfo::Other},
    {MessageDialog::Discard, "Don't Save", ButtonInfo::Destructive}, {MessageDialog::Reset, "Reset", ButtonInfo::Other},
    {MessageDialog::RestoreDefaults, "Restore Defaults", ButtonInfo::Other}, {MessageDialog::Help, "Help", ButtonInfo::Other},
};

} // namespace

void MessageDialog::open() {
    if (visible_) return;
    std::vector<ButtonInfo> shown;
    for (const ButtonInfo &b : kButtons) if (buttons_ & b.button) shown.push_back(b);
    if (shown.empty()) shown.push_back(kButtons[0]);
    QJsonArray labels;
    int cancelId = -1;
    for (size_t i = 0; i < shown.size(); i++) {
        labels.append(shown[i].label);
        if (cancelId < 0 && shown[i].role == ButtonInfo::Reject) cancelId = int(i);
    }
    QJsonObject o{{"type", "info"}, {"title", title_}, {"message", text_.isEmpty() ? title_ : text_},
                  {"detail", informativeText_}, {"buttons", labels}, {"defaultId", 0}};
    if (cancelId >= 0) o["cancelId"] = cancelId;
    QPointer<MessageDialog> self(this);
    bool ok = showDialog(this, "message", o, [self, shown](QJsonObject r) {
        if (!self) return;
        MessageDialog *d = self;
        d->visible_ = false;
        emit d->visibleChanged();
        int i = r.value("response").toInt(-1);
        if (i < 0 || i >= int(shown.size())) { emit d->rejected(); return; }
        emit d->buttonClicked(shown[size_t(i)].button);
        if (shown[size_t(i)].role == ButtonInfo::Accept) emit d->accepted();
        else if (shown[size_t(i)].role == ButtonInfo::Reject) emit d->rejected();
    });
    if (!ok) { emit rejected(); return; }
    visible_ = true;
    emit visibleChanged();
}

} // namespace hm
