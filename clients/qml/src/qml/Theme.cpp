#include "Theme.h"

#include "../Host.h"
#include "../Trace.h"

#include <QtCore/QDir>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtGui/QFontDatabase>
#include <QtGui/QGuiApplication>
#include <QtGui/QPalette>
#include <QtQuick/QQuickItem>
#include <QtQuick/private/qquickpalette_p.h>
#include <QtQuick/private/qquickwindow_p.h>

namespace hm {

Theme *Theme::create(QQmlEngine *, QJSEngine *) { return Host::get().theme(); }

/// `#RRGGBBAA` (Hyprmux's form; Qt reads `#AARRGGBB`).
static QColor rgba(const QJsonValue &v, const QColor &fallback) {
    QString hex = v.toString();
    bool ok = false;
    uint n = hex.mid(1).toUInt(&ok, 16);
    if (!ok || hex.size() != 9 || !hex.startsWith('#')) return fallback;
    return QColor(int(n >> 24), int((n >> 16) & 0xff), int((n >> 8) & 0xff), int(n & 0xff));
}

static QColor mix(const QColor &a, const QColor &b, qreal t) {
    return QColor::fromRgbF(float(a.redF() + (b.redF() - a.redF()) * t), float(a.greenF() + (b.greenF() - a.greenF()) * t),
                            float(a.blueF() + (b.blueF() - a.blueF()) * t), 1);
}

Theme::Theme(QObject *parent) : QObject(parent) {
    ui_ = QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
    mono_ = QFontDatabase::systemFont(QFontDatabase::FixedFont).family();
    // AppKit's monospaced system font isn't installed for other toolkits. Terminal
    // ships it as files, so load those into this process.
    QDir fonts("/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts");
    for (const QString &f : fonts.entryList({"SF-Mono-*.otf"}, QDir::Files)) {
        int id = QFontDatabase::addApplicationFont(fonts.filePath(f));
        QStringList families = id >= 0 ? QFontDatabase::applicationFontFamilies(id) : QStringList();
        if (!families.isEmpty()) mono_ = families.first();
    }
    terminalFamily_ = mono_;
    const char *ansi[] = {"#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                          "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"};
    for (const char *c : ansi) colors_.push_back(QColor(c));
    applyPalette();
}

void Theme::apply(const QByteArray &json) {
    QJsonObject o = QJsonDocument::fromJson(json).object();
    if (o.isEmpty()) return;
    accent_ = rgba(o.value("accent"), accent_);
    foreground_ = rgba(o.value("foreground"), foreground_);
    secondary_ = rgba(o.value("secondary"), secondary_);
    background_ = rgba(o.value("background"), background_);
    QJsonArray ansi = o.value("colors").toArray();
    if (ansi.size() >= 16) {
        colors_.clear();
        for (const QJsonValue &c : ansi) colors_.push_back(rgba(c, QColor()));
    }
    rounding_ = o.value("rounding").toDouble(rounding_);
    QString family = o.value("terminal_font").toString();
    if (!family.isEmpty()) terminalFamily_ = family;
    terminalFontSize_ = o.value("terminal_font_size").toDouble(terminalFontSize_);
    applyPalette();
    HM_TRACE("theme: background %s, accent %s", qPrintable(background_.name(QColor::HexArgb)), qPrintable(accent_.name()));
    emit changed();
}

/// Qt Quick Controls' Basic style draws from the palette: Hyprmux's colors there make
/// buttons, fields, lists, and menus match it.
void Theme::applyPalette() {
    QColor bg = background_;
    bg.setAlpha(255);
    const bool dark = bg.lightness() < 128;
    QColor ink = accent_.lightness() > 150 ? QColor(20, 20, 20) : QColor(250, 250, 250);
    QPalette p;
    p.setColor(QPalette::Window, bg);
    p.setColor(QPalette::WindowText, foreground_);
    p.setColor(QPalette::Base, mix(bg, dark ? Qt::black : Qt::white, 0.25));
    p.setColor(QPalette::AlternateBase, mix(bg, foreground_, 0.05));
    p.setColor(QPalette::Text, foreground_);
    p.setColor(QPalette::PlaceholderText, secondary_);
    p.setColor(QPalette::Button, mix(bg, foreground_, 0.12));
    p.setColor(QPalette::ButtonText, foreground_);
    p.setColor(QPalette::BrightText, Qt::white);
    p.setColor(QPalette::Highlight, accent_);
    p.setColor(QPalette::HighlightedText, ink);
    p.setColor(QPalette::Accent, accent_);
    p.setColor(QPalette::Link, accent_);
    p.setColor(QPalette::ToolTipBase, mix(bg, foreground_, 0.08));
    p.setColor(QPalette::ToolTipText, foreground_);
    // Basic draws selected rows, menu items, and checked boxes on Light, with
    // HighlightedText on top: an accent tint, like macOS's selection, readable with
    // the same ink as the accent itself.
    p.setColor(QPalette::Light, mix(bg, accent_, 0.75));
    p.setColor(QPalette::Midlight, mix(bg, accent_, 0.6));
    p.setColor(QPalette::Mid, mix(bg, foreground_, 0.35));
    p.setColor(QPalette::Dark, mix(bg, Qt::black, 0.4));
    p.setColor(QPalette::Shadow, Qt::black);
    p.setColor(QPalette::Disabled, QPalette::WindowText, secondary_);
    p.setColor(QPalette::Disabled, QPalette::Text, secondary_);
    p.setColor(QPalette::Disabled, QPalette::ButtonText, secondary_);
    palette_ = p;
    if (qobject_cast<QGuiApplication *>(QCoreApplication::instance())) QGuiApplication::setPalette(p);
}


void Theme::style(QQuickWindow *window) const {
    // The window's palette is what its items and popups inherit; QQuickWindow keeps
    // it in its private part (the QML Window type exposes it as `palette`).
    if (window) QQuickWindowPrivate::get(window)->palette()->fromQPalette(palette_);
}

} // namespace hm
