#include "scene/FrameDriver.h"

#include <QtCore/QVariantAnimation>
#include <QtTest/QtTest>

#import <QuartzCore/QuartzCore.h>

using namespace hm;

class FrameDriverTests : public QObject {
    Q_OBJECT

    int kicks = 0;
    FrameDriver *driver = nullptr;

private slots:
    void initTestCase() {
        driver = new FrameDriver([this] { kicks++; });
        driver->install();
    }

    // Animations step only on frames, to the frame's time.
    void stepsOnFrames() {
        QVariantAnimation a;
        a.setStartValue(0.0);
        a.setEndValue(1.0);
        a.setDuration(10000);
        int before = kicks;
        a.start();
        // Qt starts the driver from the event loop.
        QTRY_VERIFY(driver->isRunning());
        QCOMPARE(kicks, before + 1);   // started: surfaces asked to draw

        // No frames, no progress, however long it waits.
        QTest::qWait(60);
        QCOMPARE(a.currentTime(), 0);

        double now = CACurrentMediaTime();
        driver->frame(now + 0.008);
        // The time from the start to this frame: the wait above, not the duration.
        int first = a.currentTime();
        QVERIFY(first >= 60 && first < 1000);
        // Another surface's callback for the same frame: no second step.
        driver->frame(now + 0.009);
        QCOMPARE(a.currentTime(), first);
        // An older frame never moves time back.
        driver->frame(now - 1);
        QCOMPARE(a.currentTime(), first);
        // A frame far ahead is held to a frame past now.
        driver->frame(now + 5);
        QVERIFY(a.currentTime() < first + 200);
        a.stop();
    }

    // A second animation, started later, also begins at its start, not at the
    // first one's.
    void restarts() {
        QTRY_VERIFY(!driver->isRunning());
        QTest::qWait(1500);
        QVariantAnimation a;
        a.setStartValue(0.0);
        a.setEndValue(1.0);
        a.setDuration(10000);
        a.start();
        QTRY_VERIFY(driver->isRunning());
        driver->frame(CACurrentMediaTime());
        QVERIFY(a.currentTime() < 1000);
    }
};

int runFrameDriverTests(int argc, char **argv) {
    FrameDriverTests t;
    return QTest::qExec(&t, argc, argv);
}

#include "FrameDriverTests.moc"
