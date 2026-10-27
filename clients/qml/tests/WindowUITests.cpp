#include "qml/WindowUI.h"

#include <QtCore/QJsonDocument>
#include <QtTest/QtTest>

using namespace hm;

class WindowUITests : public QObject {
    Q_OBJECT

    static QString json(const QJsonArray &a) { return QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact)); }

private slots:
    void filters() {
        QCOMPARE(json(dialogFilters({"Text (*.txt *.md)"})), QString(R"([{"extensions":["txt","md"],"name":"Text"}])"));
        QCOMPARE(json(dialogFilters({"All files (*)"})), QString(R"([{"extensions":["*"],"name":"All files"}])"));
        QCOMPARE(json(dialogFilters({"Any (*.*)"})), QString(R"([{"extensions":["*"],"name":"Any"}])"));
        // A bare pattern names itself.
        QCOMPARE(json(dialogFilters({"*.png"})), QString(R"([{"extensions":["png"],"name":"*.png"}])"));
    }

    void accelerators() {
        QCOMPARE(menuAccelerator("Ctrl+Shift+N"), QString("Cmd+Shift+N"));
        QCOMPARE(menuAccelerator("Meta+Alt+K"), QString("Ctrl+Alt+K"));
        QCOMPARE(menuAccelerator("Ctrl+Backspace"), QString("Cmd+Backspace"));
        QCOMPARE(menuAccelerator("Ctrl+K, Ctrl+S"), QString("Cmd+K"));
        QCOMPARE(menuAccelerator(""), QString());
        QCOMPARE(menuAccelerator("Ctrl++"), QString("Cmd+Plus"));
    }
};

int runWindowUITests(int argc, char **argv) {
    WindowUITests t;
    return QTest::qExec(&t, argc, argv);
}

#include "WindowUITests.moc"
