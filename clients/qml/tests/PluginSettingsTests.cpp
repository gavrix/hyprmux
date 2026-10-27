#include "qml/PluginSettings.h"

#include <QtTest/QtTest>

using namespace hm;

class PluginSettingsTests : public QObject {
    Q_OBJECT
private slots:
    void parsesAManifest() {
        QString error;
        auto m = PluginManifest::parse(R"({"id": "dev.x.load", "name": "Load",
            "contributes": {"bar": {"item": "Bar.qml"}}, "permissions": ["tiles"], "config": {"warn": 85}})", &error);
        QVERIFY2(m.has_value(), qPrintable(error));
        QCOMPARE(m->id, QString("dev.x.load"));
        QCOMPARE(m->barItem, QString("Bar.qml"));
        QVERIFY(m->permissions.contains("tiles"));
        QCOMPARE(m->defaults.value("warn").toInt(), 85);
    }

    void nameDefaultsToTheId() {
        QString error;
        auto m = PluginManifest::parse(R"({"id": "dev.x.load"})", &error);
        QCOMPARE(m->name, QString("dev.x.load"));
        QVERIFY(m->barItem.isEmpty());
    }

    void rejectsBadManifests() {
        QString error;
        QVERIFY(!PluginManifest::parse("{", &error));
        QVERIFY(!PluginManifest::parse("[]", &error));
        QVERIFY(!PluginManifest::parse(R"({"name": "no id"})", &error));
        QVERIFY(error.contains("id"));
    }

    void settingsOverrideDefaults() {
        QVariantMap d{{"warn", 85}, {"history_s", 300}};
        QString warning;
        auto m = mergeSettings(d, R"({"warn": 70, "extra": true})", &warning);
        QCOMPARE(m.value("warn").toInt(), 70);
        QCOMPARE(m.value("history_s").toInt(), 300);
        QVERIFY(m.value("extra").toBool());
        QVERIFY(warning.isEmpty());
    }

    void noFileMeansDefaults() {
        QVariantMap d{{"warn", 85}};
        QString warning;
        QCOMPARE(mergeSettings(d, QByteArray(), &warning), d);
        QVERIFY(warning.isEmpty());
    }

    void brokenFileKeepsDefaultsAndSaysWhy() {
        QVariantMap d{{"warn", 85}};
        QString warning;
        QCOMPARE(mergeSettings(d, "{ warn: 70", &warning), d);
        QVERIFY(!warning.isEmpty());
        warning.clear();
        QCOMPARE(mergeSettings(d, "[1, 2]", &warning), d);
        QCOMPARE(warning, QString("not a JSON object"));
    }
};

int runPluginSettingsTests(int argc, char **argv) {
    PluginSettingsTests t;
    return QTest::qExec(&t, argc, argv);
}

#include "PluginSettingsTests.moc"
