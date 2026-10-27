// The images a surface renders into: IOSurfaces Hyprmux reads, each wrapped as
// the Metal texture Qt Quick draws into. No pixels are copied.
#pragma once

#include <QtCore/QSize>
#include <QtQuick/QQuickRenderTarget>

#include <IOSurface/IOSurfaceRef.h>

#include <cstdint>
#include <memory>
#include <vector>

namespace hm {

class Connection;

struct Buffer {
    IOSurfaceRef surface = nullptr;
    /// The Metal texture over `surface` (an id<MTLTexture>, retained).
    void *texture = nullptr;
    QQuickRenderTarget target;
    uint64_t id = 0;
    QSize size;
    double scale = 0;
    /// Attached by a commit, not yet released. Drawing into it would tear.
    bool busy = false;
    /// From an older size: destroyed once Hyprmux releases it.
    bool retired = false;
};

class Swapchain {
public:
    /// Three images: one on screen, one queued, one being drawn.
    static constexpr size_t length = 3;

    explicit Swapchain(Connection *connection) : conn_(connection) {}
    ~Swapchain();
    Swapchain(const Swapchain &) = delete;
    Swapchain &operator=(const Swapchain &) = delete;

    /// A free image of this size, registered with Hyprmux; made if needed. Null when
    /// all are busy: draw again when one is released.
    Buffer *acquire(QSize pixels, double scale);

    /// A new size or scale: free images of another go now, busy ones on release.
    void retireStale(QSize pixels, double scale);

    /// `buffer.release`. False when the id isn't one of ours.
    bool release(uint64_t id);

    /// Hyprmux let go of every image at once (a dismissed popup).
    void markAllFree();

private:
    Buffer *make(QSize pixels, double scale);
    void destroy(Buffer *b);

    Connection *conn_;
    std::vector<std::unique_ptr<Buffer>> buffers_;
};

/// The process's one Metal device and command queue (id<MTLDevice>, id<MTLCommandQueue>).
void *metalDevice();
void *metalQueue();

/// HM_QML_DUMP=DIR writes the latest frame of each role to DIR/<role>.png, at most
/// once a second unless its size changed. For checking popups and bar items, which
/// `hyprmuxctl snapshot` doesn't reach.
void dumpFrame(const Buffer *b, const char *role);

} // namespace hm
