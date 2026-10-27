#include "scene/KeyMap.h"

#include <QtTest/QtTest>

using namespace hm;

class KeyMapTests : public QObject {
    Q_OBJECT
private slots:
    // Qt's macOS convention: Command is Control, Control is Meta.
    void modifiers() {
        const uint64_t shift = 1 << 17, control = 1 << 18, option = 1 << 19, command = 1 << 20;
        QCOMPARE(qtModifiers(command), Qt::KeyboardModifiers(Qt::ControlModifier));
        QCOMPARE(qtModifiers(control), Qt::KeyboardModifiers(Qt::MetaModifier));
        QCOMPARE(qtModifiers(option | shift), Qt::KeyboardModifiers(Qt::AltModifier | Qt::ShiftModifier));
    }

    void keys() {
        QCOMPARE(qtKey(0x24, "\r"), int(Qt::Key_Return));
        QCOMPARE(qtKey(0x33, QString(QChar(0x7f))), int(Qt::Key_Backspace));
        QCOMPARE(qtKey(0x7B, QString(QChar(0xF702))), int(Qt::Key_Left));
        QCOMPARE(qtKey(0x00, "a"), int(Qt::Key_A));
        QCOMPARE(qtKey(0x12, "1"), int(Qt::Key_1));
    }

    // Function-key private-use characters and control characters carry no text.
    void text() {
        QCOMPARE(qtKeyText(QString(QChar(0xF700))), QString());
        QCOMPARE(qtKeyText(QString(QChar(0x7f))), QString());
        QCOMPARE(qtKeyText("é"), QString("é"));
        QCOMPARE(qtKeyText("\r"), QString("\r"));
    }

    void buttons() {
        QCOMPARE(qtButton(0), Qt::LeftButton);
        QCOMPARE(qtButton(1), Qt::RightButton);
        QCOMPARE(qtButtons(1 | 4), Qt::MouseButtons(Qt::LeftButton | Qt::MiddleButton));
    }

    void cursors() {
        QCOMPARE(QString(cursorName(Qt::PointingHandCursor)), QString("pointing_hand"));
        QCOMPARE(QString(cursorName(Qt::SplitHCursor)), QString("resize_left_right"));
        QCOMPARE(QString(cursorName(Qt::SizeFDiagCursor)), QString("resize_nwse"));
        QCOMPARE(QString(cursorName(Qt::BitmapCursor)), QString("arrow"));
    }
};

int runKeyMapTests(int argc, char **argv) {
    KeyMapTests t;
    return QTest::qExec(&t, argc, argv);
}

#include "KeyMapTests.moc"
