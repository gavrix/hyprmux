#include "qml/Attribution.h"

#include <QtTest/QtTest>

using namespace hm;

namespace {

Proc proc(int pid, int ppid, int sid, uint64_t cpuMs, uint64_t childMs = 0, uint64_t memMB = 1, bool readable = true) {
    Proc p;
    p.pid = pid;
    p.ppid = ppid;
    p.sid = sid;
    p.cpuNs = cpuMs * 1000000;
    p.childNs = childMs * 1000000;
    p.footprint = memMB * 1048576;
    p.name = QString("p%1").arg(pid);
    p.readable = readable;
    return p;
}

constexpr double second = 1e9;

} // namespace

class AttributionTests : public QObject {
    Q_OBJECT
private slots:
    void firstSampleHasNoCPU() {
        QHash<int, Seen> seen;
        auto cpu = cpuSince({proc(10, 1, 10, 500)}, {}, 0, &seen);
        QVERIFY(cpu.isEmpty());
        QCOMPARE(seen.value(10).cpuNs, uint64_t(500000000));
    }

    void cpuIsTheDifferenceOverWallTime() {
        QHash<int, Seen> seen;
        cpuSince({proc(10, 1, 10, 1000)}, {}, 0, &seen);
        auto cpu = cpuSince({proc(10, 1, 10, 1500)}, seen, 1 * second, &seen);
        QCOMPARE(cpu.value(10), 50.0);
    }

    // A compiler that starts and exits between samples shows only in its parent's
    // reaped-children time. It still counts, for the parent.
    void shortLivedChildCountsForItsParent() {
        QHash<int, Seen> seen;
        cpuSince({proc(10, 1, 10, 100)}, {}, 0, &seen);
        auto cpu = cpuSince({proc(10, 1, 10, 100, 300)}, seen, 1 * second, &seen);
        QCOMPARE(cpu.value(10), 30.0);
    }

    // A child seen alive, then reaped: its time isn't counted twice.
    void reapedChildIsNotCountedTwice() {
        QHash<int, Seen> seen;
        cpuSince({proc(10, 1, 10, 0), proc(11, 10, 10, 200)}, {}, 0, &seen);
        // The child ran 200 ms more, then exited; the parent reaped all 400 ms.
        auto cpu = cpuSince({proc(10, 1, 10, 0, 400)}, seen, 1 * second, &seen);
        QCOMPARE(cpu.value(10), 20.0);
    }

    void newProcessCountsAllItsTime() {
        QHash<int, Seen> seen;
        cpuSince({proc(10, 1, 10, 0)}, {}, 0, &seen);
        auto cpu = cpuSince({proc(10, 1, 10, 0), proc(12, 10, 10, 250)}, seen, 1 * second, &seen);
        QCOMPARE(cpu.value(12), 25.0);
    }

    void ownersClaimTreesAndSessionsOnce() {
        // Hyprmux (1) started a terminal session 100 (login 100, shell 101, job 200's
        // session separate) and a plugin host 300 with a child 301.
        std::vector<Proc> procs = {
            proc(1, 0, 1, 0, 0, 500), proc(100, 1, 100, 0), proc(101, 100, 100, 0),
            proc(150, 101, 150, 0),                       // a daemon that left the session
            proc(200, 1, 200, 0), proc(201, 200, 200, 0), // a background job's terminal
            proc(300, 1, 1, 0), proc(301, 300, 1, 0),
            proc(400, 1, 400, 0, 0, 1, false),            // another user's process
        };
        QHash<int, double> cpu = {{101, 40}, {150, 10}, {201, 90}, {301, 5}, {1, 3}};
        std::vector<Owner> owners = {
            Owner{{}, {200}},   // the job first
            Owner{{}, {100}},   // its terminal
            Owner{{300}, {}},   // a plugin
            Owner{{1}, {}},     // Hyprmux: what's left
        };
        auto u = attribute(procs, cpu, owners);
        QCOMPARE(int(u.size()), 4);
        QCOMPARE(u[0].processes, 2);
        QCOMPARE(u[0].cpu, 90.0);
        QCOMPARE(u[1].processes, 3);   // the session, and the daemon as a descendant
        QCOMPARE(u[1].cpu, 50.0);
        QCOMPARE(u[2].processes, 2);
        QCOMPARE(u[2].cpu, 5.0);
        // Hyprmux itself and the unreadable process, nothing already claimed.
        QCOMPARE(u[3].processes, 2);
        QCOMPARE(u[3].cpu, 3.0);
        QCOMPARE(u[3].memory, uint64_t(500 * 1048576));
    }

    void topIsBusiestFirst() {
        std::vector<Proc> procs = {proc(10, 1, 10, 0, 0, 1), proc(11, 10, 10, 0, 0, 9), proc(12, 10, 10, 0, 0, 2)};
        auto u = attribute(procs, {{10, 1}, {12, 7}}, {Owner{{10}, {}}}, 2);
        QCOMPARE(int(u[0].top.size()), 2);
        QCOMPARE(u[0].top[0].pid, 12);
        QCOMPARE(u[0].top[1].pid, 10);
    }
};

int runAttributionTests(int argc, char **argv) {
    AttributionTests t;
    return QTest::qExec(&t, argc, argv);
}

#include "AttributionTests.moc"
