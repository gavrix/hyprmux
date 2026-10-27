#include "scene/FrameStats.h"

#include <QtTest/QtTest>

using namespace hm;

class FrameStatsTests : public QObject {
    Q_OBJECT

private slots:
    void summary() {
        Samples s;
        QCOMPARE(s.summary().value("n").toInt(), 0);
        QVERIFY(!s.summary().contains("avg"));
        for (int i = 1; i <= 20; i++) s.add(i);
        QJsonObject o = s.summary();
        QCOMPARE(o.value("n").toInt(), 20);
        QCOMPARE(o.value("avg").toDouble(), 10.5);
        QCOMPARE(o.value("p95").toDouble(), 19.0);   // nearest rank: the 19th of 20
        QCOMPARE(o.value("max").toDouble(), 20.0);
    }

    void one() {
        Samples s;
        s.add(1.234);
        QCOMPARE(s.summary().value("p95").toDouble(), 1.23);
    }

    void takeResets() {
        FrameStats f;
        f.render.add(2);
        f.starved = 3;
        QJsonObject o = f.take();
        QCOMPARE(o.value("frames").toInt(), 1);
        QCOMPARE(o.value("starved").toInt(), 3);
        QCOMPARE(f.render.count(), size_t(0));
        QCOMPARE(f.take().value("starved").toInt(), 0);
    }
};

int runFrameStatsTests(int argc, char **argv) {
    FrameStatsTests t;
    return QTest::qExec(&t, argc, argv);
}

#include "FrameStatsTests.moc"
