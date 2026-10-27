#include "HyprmuxWindow.h"

#include "../Host.h"
#include "Theme.h"

namespace hm {

HyprmuxWindow::HyprmuxWindow(QQuickItem *parent) : QQuickItem(parent) {
    // The default color is the theme's, so it changes with it.
    connect(Host::get().theme(), &Theme::changed, this, [this] { if (!color_.isValid()) emit colorChanged(); });
}

HyprmuxWindow::~HyprmuxWindow() { Host::get().windowDestroyed(this); }

void HyprmuxWindow::setTitle(const QString &t) {
    if (t == title_) return;
    title_ = t;
    emit titleChanged();
}

QColor HyprmuxWindow::color() const { return color_.isValid() ? color_ : Host::get().theme()->background(); }

void HyprmuxWindow::setColor(const QColor &c) {
    if (c == color_) return;
    color_ = c;
    emit colorChanged();
}

void HyprmuxWindow::resetColor() { setColor(QColor()); }

void HyprmuxWindow::setActive(bool a) {
    if (a == active_) return;
    active_ = a;
    emit activeChanged();
}

void HyprmuxWindow::close() { emit closeRequestedByApp(); }

void HyprmuxWindow::activate() { emit activateRequested(); }

void HyprmuxWindow::classBegin() {
    QQuickItem::classBegin();
    Host::get().windowCreated(this);
}

void HyprmuxWindow::componentComplete() {
    QQuickItem::componentComplete();
    // Declared inside another window, the engine put it in that one's scene since.
    Host::get().windowCompleted(this);
}

} // namespace hm
