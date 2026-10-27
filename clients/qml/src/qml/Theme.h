// `Theme`: Hyprmux's look, for QML. Hyprmux sends it (its terminal colors and font,
// the active border's accent, the tiles' rounding) and sends it again when its
// config reloads; everything bound to `Theme` follows.
//
//   Rectangle { color: Theme.background; radius: Theme.rounding }
//   Text { color: Theme.foreground; font.family: Theme.monoFamily }
//
// The same colors become the application palette, so Qt Quick Controls (the Basic
// style) look like Hyprmux without any styling.
#pragma once

#include <QtCore/QJsonObject>
#include <QtCore/QObject>
#include <QtCore/QVariantList>
#include <QtGui/QColor>
#include <QtGui/QPalette>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;
class QQuickItem;
class QQuickWindow;

namespace hm {

class Theme : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// The active border's first color: focus, selection, links.
    Q_PROPERTY(QColor accent READ accent NOTIFY changed)
    /// Text, from the terminal.
    Q_PROPERTY(QColor foreground READ foreground NOTIFY changed)
    /// Secondary text: the foreground, faded.
    Q_PROPERTY(QColor secondary READ secondary NOTIFY changed)
    /// The terminal's background, with its opacity.
    Q_PROPERTY(QColor background READ background NOTIFY changed)
    /// The terminal's 16 ANSI colors: 1 red, 2 green, 3 yellow, 4 blue, +8 bright.
    Q_PROPERTY(QVariantList colors READ colors NOTIFY changed)
    /// Tiles' corner radius, in points.
    Q_PROPERTY(qreal rounding READ rounding NOTIFY changed)
    /// The terminal's font, its family and size.
    Q_PROPERTY(QString terminalFamily READ terminalFamily NOTIFY changed)
    Q_PROPERTY(qreal terminalFontSize READ terminalFontSize NOTIFY changed)
    /// The system UI font (SF Pro), as the bar's title uses.
    Q_PROPERTY(QString uiFamily READ uiFamily CONSTANT)
    /// SF Mono, as the bar's workspace pills use. Menlo when it can't be loaded.
    Q_PROPERTY(QString monoFamily READ monoFamily CONSTANT)
    /// The bar's text: plugins' bar items sit on it, so they use its colors.
    Q_PROPERTY(QColor barText READ barText CONSTANT)
    Q_PROPERTY(int barFontSize READ barFontSize CONSTANT)

public:
    // No default constructor: with one, QML would make its own instance instead of
    // calling create(), and miss the host's (qqmlprivate.h, singletonConstructionMode).
    explicit Theme(QObject *parent);
    static Theme *create(QQmlEngine *, QJSEngine *);

    /// Gives a scene's window the theme's palette, so everything in it, popups and
    /// dialogs included, uses Hyprmux's colors: Qt Quick Controls otherwise take
    /// macOS's own palette, whatever the application palette says. Scenes call it,
    /// and again when the theme changes.
    void style(QQuickWindow *window) const;

    /// Hyprmux's `theme_json` (welcome, `theme.changed`). Missing keys keep their
    /// values; an empty or bad document changes nothing.
    void apply(const QByteArray &json);

    QColor accent() const { return accent_; }
    QColor foreground() const { return foreground_; }
    QColor secondary() const { return secondary_; }
    QColor background() const { return background_; }
    QVariantList colors() const { return colors_; }
    qreal rounding() const { return rounding_; }
    QString terminalFamily() const { return terminalFamily_; }
    qreal terminalFontSize() const { return terminalFontSize_; }
    QString uiFamily() const { return ui_; }
    QString monoFamily() const { return mono_; }
    QColor barText() const { return QColor(235, 235, 235); }
    int barFontSize() const { return 11; }

signals:
    void changed();

private:
    void applyPalette();
    QPalette palette_;


    QString mono_, ui_;
    QColor accent_{51, 204, 255}, foreground_{230, 230, 230}, secondary_{230, 230, 230, 158}, background_{30, 31, 36};
    QVariantList colors_;
    qreal rounding_ = 10;
    QString terminalFamily_;
    qreal terminalFontSize_ = 13;
};

} // namespace hm
