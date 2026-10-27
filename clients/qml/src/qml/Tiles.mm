#include "Tiles.h"

#include "../Host.h"
#include "../Trace.h"
#include "../protocol/Connection.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSet>
#include <QtGui/QColor>

#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/proc_info.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace hm {

static double nowSeconds() { return double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9; }

Tiles *Tiles::create(QQmlEngine *, QJSEngine *js) { return Host::get().tiles(js); }

Tiles::Tiles(Connection *connection, QObject *parent) : QObject(parent), conn_(connection) {
    connect(&timer_, &QTimer::timeout, this, &Tiles::refresh);
    // Start once QML had its chance to set `history`, so `history: 0` never samples.
    QTimer::singleShot(0, this, [this] { schedule(); if (history_ > 0) refresh(); });
}

void Tiles::schedule() {
    int ms = active_ ? interval_ : history_ > 0 ? backgroundInterval_ : 0;
    if (ms == 0) { timer_.stop(); return; }
    if (!timer_.isActive() || timer_.interval() != ms) timer_.start(ms);
}

void Tiles::setActive(bool on) {
    if (on == active_) return;
    active_ = on;
    if (on) {
        // CPU is a difference of two samples. A background sample is recent enough to
        // measure against; without one, take a baseline and read again soon.
        bool recent = lastSample_ && nowSeconds() - double(lastSample_) / 1e9 < 10;
        if (!recent) {
            lastCPU_.clear();
            lastSample_ = 0;
            QTimer::singleShot(600, this, [this] { if (active_) refresh(); });
        }
        refresh();
    }
    schedule();
    emit activeChanged();
}

void Tiles::setInterval(int ms) {
    ms = qMax(500, ms);
    if (ms == interval_) return;
    interval_ = ms;
    schedule();
    emit intervalChanged();
}

void Tiles::setBackgroundInterval(int ms) {
    ms = qMax(1000, ms);
    if (ms == backgroundInterval_) return;
    backgroundInterval_ = ms;
    schedule();
    emit intervalChanged();
}

void Tiles::setHistory(int seconds) {
    seconds = qMax(0, seconds);
    if (seconds == history_) return;
    history_ = seconds;
    if (history_ == 0) samples_.clear();
    schedule();
    emit historyChanged();
}

void Tiles::refresh() {
    pending_ = conn_->allocate();
    Message m("tiles.query");
    m.u64("id", pending_);
    conn_->send(m);
}

void Tiles::focus(int id) {
    Message m("tiles.focus");
    m.u64("surface", uint64_t(id));
    conn_->send(m);
}

bool Tiles::handle(const Event &e) {
    if (e.op() != "tiles.result") return false;
    if (e.u64("id") == pending_) build(QByteArray::fromStdString(e.str("tiles_json")));
    return true;
}

namespace {

/// `#RRGGBBAA`, as Hyprmux sends colors. (Qt reads `#AARRGGBB`.)
QColor rgba(const QString &hex) {
    bool ok = false;
    uint v = hex.mid(1).toUInt(&ok, 16);
    if (!ok || hex.size() != 9) return QColor();
    return QColor(int(v >> 24), int((v >> 16) & 0xff), int((v >> 8) & 0xff), int(v & 0xff));
}

/// Mach ticks to nanoseconds: rusage times are ticks on Apple Silicon.
uint64_t ticksToNs(uint64_t t) {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t i; mach_timebase_info(&i); return i; }();
    return t * tb.numer / tb.denom;
}

/// Every process, now. About 6 ms for 2,700 processes.
std::vector<Proc> allProcesses() {
    int n = proc_listallpids(nullptr, 0);
    std::vector<int> pids(size_t(qMax(0, n)) + 64);
    n = proc_listallpids(pids.data(), int(pids.size() * sizeof(int)));
    std::vector<Proc> out;
    out.reserve(size_t(qMax(0, n)));
    for (int i = 0; i < n; i++) {
        Proc p;
        p.pid = pids[size_t(i)];
        if (p.pid <= 0) continue;
        proc_bsdshortinfo info;
        if (proc_pidinfo(p.pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info)) != int(sizeof(info))) continue;
        p.ppid = int(info.pbsi_ppid);
        p.sid = int(getsid(p.pid));
        p.name = QString::fromUtf8(info.pbsi_comm);
        rusage_info_v4 ru;
        if (proc_pid_rusage(p.pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru) == 0) {
            p.cpuNs = ticksToNs(ru.ri_user_time + ru.ri_system_time);
            p.childNs = ticksToNs(ru.ri_child_user_time + ru.ri_child_system_time);
            p.footprint = ru.ri_phys_footprint;
            p.readable = true;
        }
        out.push_back(p);
    }
    return out;
}

QVariantMap usageRow(const Usage &u, bool measured) {
    QVariantList top;
    for (const TopProcess &t : u.top)
        top.push_back(QVariantMap{{"pid", t.pid}, {"name", t.name}, {"cpu", t.cpu}, {"memory", double(t.memory)}});
    return QVariantMap{{"cpu", measured ? u.cpu : -1.0}, {"memory", double(u.memory)}, {"processes", u.processes}, {"top", top}};
}

} // namespace

void Tiles::build(const QByteArray &json) {
    QJsonObject result = QJsonDocument::fromJson(json).object();
    if (result.contains("error")) {
        std::fprintf(stderr, "hyprmux-qml: tiles: %s\n", qPrintable(result.value("error").toString()));
        return;
    }
    std::vector<Proc> procs = allProcesses();
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double wall = lastSample_ ? double(now - lastSample_) : 0;
    QHash<int, double> cpu = cpuSince(procs, lastCPU_, wall, &lastCPU_);
    lastSample_ = now;
    // A first sample only sets the baseline: keep showing the last rows until the
    // next one can tell CPU use. With nothing to show yet, CPU reads as unknown (-1).
    bool measured = wall > 0;
    if (!measured && !rows_.isEmpty()) return;

    // Owners in claiming order: jobs before the terminals that started them, tiles,
    // plugins, then Hyprmux, which gets the helpers nothing else owns.
    std::vector<QJsonObject> tiles;
    for (const QJsonValue &v : result.value("tiles").toArray()) if (v.toObject().contains("attached")) tiles.push_back(v.toObject());
    for (const QJsonValue &v : result.value("tiles").toArray()) if (!v.toObject().contains("attached")) tiles.push_back(v.toObject());
    QJsonArray plugins = result.value("plugins").toArray();
    int hyprmux = result.value("hyprmux_pid").toInt();

    std::vector<Owner> owners;
    for (const QJsonObject &t : tiles) {
        Owner o;
        for (const QJsonValue &pid : t.value("pids").toArray()) o.pids.push_back(pid.toInt());
        for (const QJsonValue &sid : t.value("sessions").toArray()) o.sessions.insert(sid.toInt());
        owners.push_back(o);
    }
    for (const QJsonValue &v : plugins) owners.push_back(Owner{{v.toObject().value("pid").toInt()}, {}});
    if (hyprmux > 0) owners.push_back(Owner{{hyprmux}, {}});
    std::vector<Usage> usage = attribute(procs, cpu, owners);

    // History: this sample appended per row, the old ones trimmed, closed tiles gone.
    double tNow = double(now) / 1e9;
    QSet<int> seen;
    auto record = [&](QVariantMap &row) {
        int id = row.value("id").toInt();
        seen.insert(id);
        if (history_ <= 0 || !measured || row.value("processes").toInt() == 0) return;
        QVector<Sample> &s = samples_[id];
        s.push_back({tNow, row.value("cpu").toDouble(), row.value("memory").toDouble()});
        while (!s.isEmpty() && tNow - s.first().t > history_) s.removeFirst();
        QVariantList ts, cpus, mems;
        for (const Sample &x : s) {
            ts.push_back(x.t - tNow);
            cpus.push_back(x.cpu);
            mems.push_back(x.memory);
        }
        row.insert("historyT", ts);
        row.insert("historyCpu", cpus);
        row.insert("historyMemory", mems);
    };

    QVariantList rows;
    size_t i = 0;
    for (const QJsonObject &t : tiles) {
        QVariantMap row = usageRow(usage[i++], measured);
        row.insert("id", t.value("id").toInt());
        row.insert("ref", t.value("ref").toString());
        row.insert("title", t.value("title").toString());
        row.insert("kind", t.value("kind").toString());
        row.insert("workspace", t.value("workspace").toString());
        row.insert("focused", t.value("focused").toBool());
        row.insert("visible", t.value("visible").toBool());
        row.insert("parent", t.value("attached").toObject().value("parent").toInt());
        QJsonObject pill = t.value("pill").toObject();
        row.insert("pillFill", rgba(pill.value("fill").toString()));
        row.insert("pillInk", rgba(pill.value("ink").toString()));
        row.insert("pillFontSize", pill.value("font_size").toDouble(11));
        record(row);
        HM_TRACE("tile %s: %d processes, cpu %.1f", qPrintable(t.value("ref").toString()),
                 row.value("processes").toInt(), row.value("cpu").toDouble());
        rows.push_back(row);
    }
    // Plugins' history is keyed by plugin id, so it survives a restart.
    for (const QJsonValue &v : plugins) {
        QJsonObject o = v.toObject();
        QVariantMap row = usageRow(usage[i++], measured);
        row.insert("id", -int(qHash(o.value("id").toString()) & 0x3fffffff) - 1);
        row.insert("ref", "");
        row.insert("title", o.value("name").toString());
        row.insert("kind", "plugin");
        row.insert("parent", 0);
        record(row);
        rows.push_back(row);
    }
    std::sort(rows.begin(), rows.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("cpu").toDouble() > b.toMap().value("cpu").toDouble();
    });
    if (hyprmux > 0) {
        QVariantMap row = usageRow(usage[i++], measured);
        row.insert("id", 0);
        row.insert("ref", "");
        row.insert("title", "Hyprmux");
        row.insert("kind", "hyprmux");
        row.insert("parent", 0);
        record(row);
        rows.push_back(row);
    }
    for (auto it = samples_.begin(); it != samples_.end();) {
        if (seen.contains(it.key())) ++it; else it = samples_.erase(it);
    }
    rows_ = rows;
    emit rowsChanged();
}

} // namespace hm
