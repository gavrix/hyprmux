// `System`: machine-wide load for QML (the `system-stats` permission).
//
//   import Hyprmux
//   Text { text: "CPU " + Math.round(System.cpu) + "%" }
//
// Values refresh every `interval` ms.
#pragma once

#include <QtCore/QObject>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;

#include <cstdint>

namespace hm {

class System : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// All cores, busy share since the last sample: 0–100.
    Q_PROPERTY(double cpu READ cpu NOTIFY updated)
    /// The kernel's memory pressure: "normal", "warning", or "critical". The right
    /// signal for "memory is low": macOS keeps free RAM near zero on purpose.
    Q_PROPERTY(QString memoryPressure READ memoryPressure NOTIFY updated)
    /// Activity Monitor's "Memory Used": app memory, wired, and compressed. Bytes.
    Q_PROPERTY(double memoryUsed READ memoryUsed NOTIFY updated)
    Q_PROPERTY(double memoryTotal READ memoryTotal CONSTANT)
    Q_PROPERTY(bool hasBattery READ hasBattery NOTIFY updated)
    /// Running on battery, not on the adapter.
    Q_PROPERTY(bool onBattery READ onBattery NOTIFY updated)
    Q_PROPERTY(bool charging READ charging NOTIFY updated)
    /// Charge, 0–100. -1 without a battery.
    Q_PROPERTY(int batteryPercent READ batteryPercent NOTIFY updated)
    Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged)
    /// `cpu` at each sample over the last `history` seconds, oldest first, one per
    /// `interval`.
    Q_PROPERTY(QVariantList cpuHistory READ cpuHistory NOTIFY updated)
    Q_PROPERTY(int history READ history WRITE setHistory NOTIFY intervalChanged)

public:
    // No default constructor: with one, QML would make its own instance instead of
    // calling create(), and miss the host's (qqmlprivate.h, singletonConstructionMode).
    explicit System(QObject *parent);
    /// Needs the "system-stats" permission.
    static System *create(QQmlEngine *, QJSEngine *js);

    double cpu() const { return cpu_; }
    QString memoryPressure() const { return memoryPressure_; }
    double memoryUsed() const { return memoryUsed_; }
    double memoryTotal() const { return memoryTotal_; }
    bool hasBattery() const { return hasBattery_; }
    bool onBattery() const { return onBattery_; }
    bool charging() const { return charging_; }
    int batteryPercent() const { return batteryPercent_; }
    int interval() const { return timer_.interval(); }
    void setInterval(int ms);
    QVariantList cpuHistory() const { return cpuHistory_; }
    int history() const { return history_; }
    void setHistory(int seconds);

signals:
    void updated();
    void intervalChanged();

private:
    void sample();
    void sampleCPU();
    void sampleMemory();
    void samplePower();

    QTimer timer_;
    uint64_t lastBusy_ = 0, lastTotal_ = 0;
    double cpu_ = 0;
    QString memoryPressure_ = QStringLiteral("normal");
    double memoryUsed_ = 0, memoryTotal_ = 0;
    bool hasBattery_ = false, onBattery_ = false, charging_ = false;
    int batteryPercent_ = -1;
    QVariantList cpuHistory_;
    int history_ = 300;
    void trimHistory();
};

} // namespace hm
