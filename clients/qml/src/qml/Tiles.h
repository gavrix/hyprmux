// `Tiles`: Hyprmux's tiles with the CPU and memory of the processes behind each,
// like a browser's task manager (the `tiles` permission).
//
//   import Hyprmux
//   Repeater {
//       model: Tiles.rows
//       delegate: Text { text: modelData.ref + " " + modelData.cpu.toFixed(1) + "%" }
//   }
//
// It samples every `interval` ms while `active` (a popup shows it), and every
// `backgroundInterval` ms otherwise, to keep `history` seconds of history for the
// graphs. One sample walks the process table: about 6 ms for 2,700 processes.
// `history: 0` stops background sampling.
#pragma once

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>
#include <QtQml/qqmlregistration.h>

#include "Attribution.h"

class QJSEngine;
class QQmlEngine;

#include <cstdint>

namespace hm {

class Connection;
struct Event;

class Tiles : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// One map per tile, sorted by CPU, busiest first:
    ///   id, ref ("surface:7"), title, kind, workspace, focused, visible,
    ///   parent (the tile a background job belongs to; 0 if none),
    ///   pillFill, pillInk, pillFontSize (the number pill on the tile's border now),
    ///   cpu (percent of one core, as Activity Monitor counts; -1 until measured;
    ///   includes processes that started and exited between samples, through their
    ///   parent's reaped-children time),
    ///   memory (bytes),
    ///   processes (count), top ([{pid, name, cpu, memory}], the three busiest),
    ///   historyT (seconds before now, oldest first), historyCpu, historyMemory:
    ///   the tile's samples over the last `history` seconds, for a graph.
    /// Plugins get rows too (kind "plugin", a negative id). The last row is Hyprmux
    /// itself (kind "hyprmux"): its process and helpers no tile owns (web tiles
    /// render there).
    Q_PROPERTY(QVariantList rows READ rows NOTIFY rowsChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged)
    Q_PROPERTY(int backgroundInterval READ backgroundInterval WRITE setBackgroundInterval NOTIFY intervalChanged)
    /// Seconds of history to keep. 0: none, and no sampling while inactive.
    Q_PROPERTY(int history READ history WRITE setHistory NOTIFY historyChanged)

public:
    explicit Tiles(Connection *connection, QObject *parent = nullptr);
    /// Needs the "tiles" permission.
    static Tiles *create(QQmlEngine *, QJSEngine *js);

    QVariantList rows() const { return rows_; }
    bool active() const { return active_; }
    void setActive(bool on);
    int interval() const { return interval_; }
    void setInterval(int ms);
    int backgroundInterval() const { return backgroundInterval_; }
    void setBackgroundInterval(int ms);
    int history() const { return history_; }
    void setHistory(int seconds);

    /// Shows and focuses a tile (what clicking a row does).
    Q_INVOKABLE void focus(int id);
    /// Asks Hyprmux for its tiles now.
    Q_INVOKABLE void refresh();

    /// Routes `tiles.result`. False for other events.
    bool handle(const Event &e);

signals:
    void rowsChanged();
    void activeChanged();
    void intervalChanged();
    void historyChanged();

private:
    void build(const QByteArray &json);
    /// Starts, restarts, or stops the timer for the current mode.
    void schedule();

    struct Sample { double t; double cpu; double memory; };

    Connection *conn_;
    QTimer timer_;
    bool active_ = false;
    int interval_ = 2000;
    int backgroundInterval_ = 5000;
    int history_ = 300;
    /// Samples per tile id (0: Hyprmux), oldest first.
    QHash<int, QVector<Sample>> samples_;
    uint64_t pending_ = 0;
    QVariantList rows_;
    /// The last sample's processes, and when it was.
    QHash<int, Seen> lastCPU_;
    uint64_t lastSample_ = 0;
};

} // namespace hm
