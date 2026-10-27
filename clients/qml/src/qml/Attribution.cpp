#include "Attribution.h"

#include <algorithm>

namespace hm {

QHash<int, double> cpuSince(const std::vector<Proc> &procs, const QHash<int, Seen> &last, double wallNs,
                            QHash<int, Seen> *seen) {
    QHash<int, Seen> now;
    for (const Proc &p : procs)
        if (p.readable) now.insert(p.pid, {p.cpuNs, p.childNs, p.ppid});

    // Per parent: what its children that exited since were already counted for.
    QHash<int, uint64_t> counted;
    for (auto it = last.cbegin(); it != last.cend(); ++it)
        if (!now.contains(it.key())) counted[it->ppid] += it->cpuNs + it->childNs;

    QHash<int, double> cpu;
    if (wallNs > 0) {
        for (auto it = now.cbegin(); it != now.cend(); ++it) {
            auto before = last.find(it.key());
            // New since the last sample: all its time is since then.
            uint64_t was = before == last.end() ? 0 : before->cpuNs + before->childNs;
            double ns = double(it->cpuNs + it->childNs) - double(was) - double(counted.value(it.key()));
            cpu.insert(it.key(), 100.0 * std::max(0.0, ns) / wallNs);
        }
    }
    if (seen) *seen = now;
    return cpu;
}

std::vector<Usage> attribute(const std::vector<Proc> &procs, const QHash<int, double> &cpu,
                             const std::vector<Owner> &owners, int topCount) {
    QHash<int, const Proc *> byPid;
    QHash<int, QVector<int>> children;
    for (const Proc &p : procs) {
        byPid.insert(p.pid, &p);
        children[p.ppid].push_back(p.pid);
    }

    QSet<int> claimed;
    std::vector<Usage> out;
    out.reserve(owners.size());
    for (const Owner &o : owners) {
        QVector<int> roots = o.pids;
        if (!o.sessions.isEmpty())
            for (const Proc &p : procs) if (o.sessions.contains(p.sid)) roots.push_back(p.pid);
        Usage u;
        std::vector<std::pair<double, const Proc *>> busiest;
        while (!roots.isEmpty()) {
            int pid = roots.takeLast();
            if (claimed.contains(pid) || !byPid.contains(pid)) continue;
            claimed.insert(pid);
            roots += children.value(pid);
            const Proc *p = byPid.value(pid);
            u.processes++;
            if (!p->readable) continue;
            double c = cpu.value(pid);
            u.cpu += c;
            u.memory += p->footprint;
            busiest.push_back({c + double(p->footprint) * 1e-12, p});
        }
        std::sort(busiest.begin(), busiest.end(), [](auto &a, auto &b) { return a.first > b.first; });
        for (size_t i = 0; i < std::min(size_t(std::max(0, topCount)), busiest.size()); i++) {
            const Proc *p = busiest[i].second;
            u.top.push_back({p->pid, p->name, cpu.value(p->pid), p->footprint});
        }
        out.push_back(std::move(u));
    }
    return out;
}

} // namespace hm
