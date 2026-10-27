#include "Menus.h"

#include "../Host.h"
#include "../protocol/Connection.h"
#include "../scene/Scene.h"
#include "WindowUI.h"

#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QPointer>
#include <QtQuick/QQuickItem>

#include <cmath>
#include <cstdio>

namespace hm {

void NativeMenuItem::trigger() {
    if (checkable_) {
        checked_ = !checked_;
        emit checkedChanged();
    }
    emit triggered();
}

QQmlListProperty<QObject> NativeMenu::data() {
    return QQmlListProperty<QObject>(
        this, &data_,
        [](QQmlListProperty<QObject> *l, QObject *o) {
            static_cast<QList<QObject *> *>(l->data)->append(o);
            if (!o->parent()) o->setParent(l->object);
        },
        [](QQmlListProperty<QObject> *l) { return static_cast<QList<QObject *> *>(l->data)->size(); },
        [](QQmlListProperty<QObject> *l, qsizetype i) { return static_cast<QList<QObject *> *>(l->data)->at(i); },
        [](QQmlListProperty<QObject> *l) { static_cast<QList<QObject *> *>(l->data)->clear(); });
}

/// The protocol's item tree; `ids` maps each item's id back to it.
QJsonArray NativeMenu::items(QHash<QString, NativeMenuItem *> &ids) const {
    QJsonArray out;
    for (QObject *o : data_) {
        if (qobject_cast<NativeMenuSeparator *>(o)) {
            out.append(QJsonObject{{"type", "separator"}});
        } else if (auto *sub = qobject_cast<NativeMenu *>(o)) {
            out.append(QJsonObject{{"id", QString("m%1").arg(ids.size())}, {"label", sub->title_},
                                   {"enabled", sub->enabled_}, {"type", "submenu"}, {"submenu", sub->items(ids)}});
        } else if (auto *item = qobject_cast<NativeMenuItem *>(o)) {
            QString id = QString("i%1").arg(ids.size());
            ids.insert(id, item);
            QJsonObject j{{"id", id}, {"label", item->text()}, {"enabled", item->isEnabled()},
                          {"type", item->isCheckable() ? "checkbox" : "normal"}, {"checked", item->isChecked()}};
            if (!item->shortcut().isEmpty()) j["accelerator"] = menuAccelerator(item->shortcut());
            out.append(j);
        }
    }
    return out;
}

void NativeMenu::popup(QObject *anchor, qreal x, qreal y) {
    Host &host = Host::get();
    QObject *owner = anchor ? anchor : parent();
    Scene *tile = host.tileFor(owner ? owner : this);
    if (!tile || !host.connection()) {
        std::fprintf(stderr, "hyprmux-qml: a menu needs an open window to show over\n");
        return;
    }
    QPointF at = tile->pointerPosition();
    if (!std::isnan(x) && !std::isnan(y)) {
        at = QPointF(x, y);
        if (auto *item = qobject_cast<QQuickItem *>(owner)) at = item->mapToScene(at);
    }
    auto ids = std::make_shared<QHash<QString, NativeMenuItem *>>();
    QJsonArray tree = items(*ids);
    QPointer<NativeMenu> self(this);
    uint64_t id = host.expectReply([self, ids](const Event &e) {
        if (!self) return;
        QString picked = QString::fromStdString(e.str("item"));
        // The menu's items may have gone while it was open.
        if (NativeMenuItem *item = ids->value(picked); item && self->findChildren<NativeMenuItem *>().contains(item)) item->trigger();
        emit self->closed();
    });
    Message m("menu.popup");
    m.u64("id", id).u64("surface", tile->surfaceID()).f64("x", at.x()).f64("y", at.y())
        .str("items_json", QJsonDocument(tree).toJson(QJsonDocument::Compact).toStdString());
    host.connection()->send(m);
}

} // namespace hm
