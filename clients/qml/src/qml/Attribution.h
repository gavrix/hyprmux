// Which processes belong to which owner (a tile, a plugin, Hyprmux), and what they
// cost. Pure functions over a process snapshot, so they test without real processes.
#pragma once

#include <QtCore/QHash>
#include <QtCore/QSet>
#include <QtCore/QString>
#include <QtCore/QVector>

#include <cstdint>
#include <vector>

namespace hm {

/// One process, as one sample saw it.
struct Proc {
    int pid = 0, ppid = 0, sid = 0;
    /// Its own CPU time, and its reaped children's (exited, waited for), in ns.
    uint64_t cpuNs = 0, childNs = 0;
    /// Activity Monitor's "Memory".
    uint64_t footprint = 0;
    QString name;
    /// Its usage could be read (same user). Others still count for the tree.
    bool readable = false;
};

/// What the last sample remembers of a process.
struct Seen {
    uint64_t cpuNs = 0, childNs = 0;
    int ppid = 0;
};

/// CPU per pid since the last sample, in percent of one core (Activity Monitor's
/// count). Processes that started and exited between samples, like a build's
/// compilers, show in their parent's reaped-children time; that counts, less what
/// those children were already counted for while alive. `seen` gets this sample,
/// for the next call. `wallNs` 0 (no last sample): no CPU, only `seen`.
QHash<int, double> cpuSince(const std::vector<Proc> &procs, const QHash<int, Seen> &last, double wallNs,
                            QHash<int, Seen> *seen);

/// Who claims processes: roots (with their descendants) and whole sessions.
struct Owner {
    QVector<int> pids;
    QSet<int> sessions;
};

struct TopProcess {
    int pid = 0;
    QString name;
    double cpu = 0;
    uint64_t memory = 0;
};

struct Usage {
    double cpu = 0;
    uint64_t memory = 0;
    int processes = 0;
    /// The busiest few, CPU first, memory breaking ties.
    std::vector<TopProcess> top;
};

/// Owners claim processes in order, each process once: a later owner gets only what
/// earlier ones left. So callers list jobs before the terminals that started them,
/// and Hyprmux last, to get the helpers nothing else owns.
std::vector<Usage> attribute(const std::vector<Proc> &procs, const QHash<int, double> &cpu,
                             const std::vector<Owner> &owners, int topCount = 3);

} // namespace hm
