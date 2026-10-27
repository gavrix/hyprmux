#include "System.h"

#include "../Host.h"

#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <mach/mach.h>
#include <sys/sysctl.h>

namespace hm {

System *System::create(QQmlEngine *, QJSEngine *js) { return Host::get().system(js); }

System::System(QObject *parent) : QObject(parent) {
    uint64_t mem = 0;
    size_t size = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &size, nullptr, 0) == 0) memoryTotal_ = double(mem);
    timer_.setInterval(2000);
    connect(&timer_, &QTimer::timeout, this, &System::sample);
    timer_.start();
    sample();
}

void System::setInterval(int ms) {
    ms = qMax(250, ms);
    if (ms == timer_.interval()) return;
    timer_.setInterval(ms);
    cpuHistory_.clear();   // one sample per interval: the old ones were at another pace
    emit intervalChanged();
}

void System::setHistory(int seconds) {
    seconds = qMax(0, seconds);
    if (seconds == history_) return;
    history_ = seconds;
    trimHistory();
    emit intervalChanged();
}

void System::trimHistory() {
    qsizetype keep = history_ * 1000 / qMax(1, timer_.interval());
    while (cpuHistory_.size() > keep) cpuHistory_.removeFirst();
}

void System::sample() {
    bool baseline = lastTotal_ == 0;
    sampleCPU();
    if (!baseline) {
        cpuHistory_.push_back(cpu_);
        trimHistory();
    }
    sampleMemory();
    samplePower();
    emit updated();
}

void System::sampleCPU() {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return;
    uint64_t user = info.cpu_ticks[CPU_STATE_USER], sys = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t nice = info.cpu_ticks[CPU_STATE_NICE], idle = info.cpu_ticks[CPU_STATE_IDLE];
    uint64_t busy = user + sys + nice, total = busy + idle;
    if (lastTotal_ != 0 && total > lastTotal_) cpu_ = 100.0 * double(busy - lastBusy_) / double(total - lastTotal_);
    lastBusy_ = busy;
    lastTotal_ = total;
}

void System::sampleMemory() {
    int level = 0;
    size_t size = sizeof(level);
    // 1 normal, 2 warning, 4 critical (kVMPressure* in the kernel).
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nullptr, 0) == 0)
        memoryPressure_ = level >= 4 ? QStringLiteral("critical") : level >= 2 ? QStringLiteral("warning") : QStringLiteral("normal");

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    uint64_t app = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
    memoryUsed_ = double((app + vm.wire_count + vm.compressor_page_count) * uint64_t(page));
}

void System::samplePower() {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return;
    CFStringRef providing = IOPSGetProvidingPowerSourceType(info);
    onBattery_ = providing && CFStringCompare(providing, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo;
    hasBattery_ = false;
    batteryPercent_ = -1;
    charging_ = false;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    for (CFIndex i = 0, n = list ? CFArrayGetCount(list) : 0; i < n; i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if (!d) continue;
        CFStringRef type = (CFStringRef)CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
        if (!type || CFStringCompare(type, CFSTR(kIOPSInternalBatteryType), 0) != kCFCompareEqualTo) continue;
        int current = 0, max = 0;
        if (auto c = (CFNumberRef)CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey))) CFNumberGetValue(c, kCFNumberIntType, &current);
        if (auto m = (CFNumberRef)CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey))) CFNumberGetValue(m, kCFNumberIntType, &max);
        if (auto ch = (CFBooleanRef)CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey))) charging_ = CFBooleanGetValue(ch);
        hasBattery_ = true;
        batteryPercent_ = max > 0 ? int(100.0 * current / max + 0.5) : current;
        break;
    }
    if (list) CFRelease(list);
    CFRelease(info);
}

} // namespace hm
