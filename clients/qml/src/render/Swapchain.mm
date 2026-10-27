#include "Swapchain.h"

#include "../protocol/Connection.h"

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <QtCore/QElapsedTimer>
#include <QtCore/QHash>
#include <QtCore/QString>
#include <QtGui/QImage>
#include <rhi/qrhi.h>

#include <cstdlib>

namespace hm {

void *metalDevice() {
    static id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return (__bridge void *)d;
}

void *metalQueue() {
    static id<MTLCommandQueue> q = [(__bridge id<MTLDevice>)metalDevice() newCommandQueue];
    return (__bridge void *)q;
}

static size_t gSurfaceBytes = 0;
size_t surfaceBytes() { return gSurfaceBytes; }
size_t metalAllocatedBytes() { return [(__bridge id<MTLDevice>)metalDevice() currentAllocatedSize]; }

Swapchain::~Swapchain() {
    for (auto &b : buffers_) free(b.get());
    delete pass_;
    delete depth_;
}

void Swapchain::free(Buffer *b) {
    delete b->renderTarget;
    delete b->color;
    b->renderTarget = nullptr;
    b->color = nullptr;
    if (b->texture) CFRelease(b->texture);
    if (b->surface) {
        gSurfaceBytes -= IOSurfaceGetAllocSize(b->surface);
        CFRelease(b->surface);
    }
    b->texture = nullptr;
    b->surface = nullptr;
}

bool Swapchain::ensureShared(QSize pixels) {
    if (depth_ && sharedSize_ == pixels) return true;
    // Buffers of the old size still alive keep their own render pass; only new
    // ones use these.
    delete pass_;
    pass_ = nullptr;
    delete depth_;
    // On Apple GPUs the depth-stencil buffer costs next to nothing: Metal's total
    // stays within a few MB of the IOSurfaces' (HM_QML_STATS).
    depth_ = rhi_->newRenderBuffer(QRhiRenderBuffer::DepthStencil, pixels);
    if (!depth_->create()) {
        delete depth_;
        depth_ = nullptr;
        return false;
    }
    sharedSize_ = pixels;
    return true;
}

Buffer *Swapchain::acquire(QSize pixels, double scale) {
    size_t live = 0;
    for (auto &b : buffers_) {
        if (b->retired) continue;
        live++;
        if (!b->busy && b->size == pixels && b->scale == scale) return b.get();
    }
    if (live >= length) return nullptr;
    return make(pixels, scale);
}

Buffer *Swapchain::make(QSize pixels, double scale) {
    int w = pixels.width(), h = pixels.height();
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size_t(w) * 4)),
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),   // the only format protocol v0 takes
    };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s) return nullptr;
    gSurfaceBytes += IOSurfaceGetAllocSize(s);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                   width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;   // Hyprmux ships for Apple Silicon only
    id<MTLTexture> t = [(__bridge id<MTLDevice>)metalDevice() newTextureWithDescriptor:td iosurface:s plane:0];
    if (!t) {
        CFRelease(s);
        return nullptr;
    }

    auto b = std::make_unique<Buffer>();
    b->surface = s;
    b->texture = (__bridge_retained void *)t;
    b->size = pixels;
    b->scale = scale;
    // A render target of our own, kept with the image: Qt Quick reuses it as is.
    if (!ensureShared(pixels)) {
        free(b.get());
        return nullptr;
    }
    b->color = rhi_->newTexture(QRhiTexture::BGRA8, pixels, 1, QRhiTexture::RenderTarget);
    if (!b->color->createFrom({quint64(quintptr((__bridge void *)t)), 0})) {
        free(b.get());
        return nullptr;
    }
    QRhiTextureRenderTargetDescription desc{QRhiColorAttachment(b->color)};
    desc.setDepthStencilBuffer(depth_);
    b->renderTarget = rhi_->newTextureRenderTarget(desc, QRhiTextureRenderTarget::DoNotStoreDepthStencilContents);
    if (!pass_) pass_ = b->renderTarget->newCompatibleRenderPassDescriptor();
    b->renderTarget->setRenderPassDescriptor(pass_);
    if (!b->renderTarget->create()) {
        free(b.get());
        return nullptr;
    }
    b->target = QQuickRenderTarget::fromRhiRenderTarget(b->renderTarget);
    b->target.setDevicePixelRatio(scale);
    b->id = conn_->allocate();
    Message m("buffer.create_iosurface");
    m.u64("id", b->id).object("surface", IOSurfaceCreateXPCObject(s));
    conn_->send(m);
    buffers_.push_back(std::move(b));
    return buffers_.back().get();
}

void Swapchain::destroy(Buffer *b) {
    Message m("buffer.destroy");
    m.u64("id", b->id);
    conn_->send(m);
    for (auto it = buffers_.begin(); it != buffers_.end(); ++it) {
        if (it->get() != b) continue;
        free(b);
        buffers_.erase(it);
        return;
    }
}

void Swapchain::retireStale(QSize pixels, double scale) {
    std::vector<Buffer *> gone;
    for (auto &b : buffers_) {
        if (b->size == pixels && b->scale == scale) continue;
        b->retired = true;
        if (!b->busy) gone.push_back(b.get());
    }
    for (Buffer *b : gone) destroy(b);
}

bool Swapchain::release(uint64_t id) {
    for (auto &b : buffers_) {
        if (b->id != id) continue;
        b->busy = false;
        if (b->retired) destroy(b.get());
        return true;
    }
    return false;
}

void Swapchain::releaseAll() {
    while (!buffers_.empty()) destroy(buffers_.back().get());
    delete pass_;
    pass_ = nullptr;
    delete depth_;
    depth_ = nullptr;
    sharedSize_ = QSize();
}

void dumpFrame(const Buffer *b, const char *role) {
    static const char *dir = std::getenv("HM_QML_DUMP");
    if (!dir || !b) return;
    static QElapsedTimer clock;
    if (!clock.isValid()) clock.start();
    static QHash<QString, std::pair<qint64, QSize>> last;
    QString name = QString("%1/%2.png").arg(dir, role);
    qint64 now = clock.elapsed();
    auto it = last.find(name);
    if (it != last.end() && now - it->first < 1000 && it->second == b->size) return;
    last[name] = {now, b->size};
    IOSurfaceLock(b->surface, kIOSurfaceLockReadOnly, nullptr);
    QImage img((const uchar *)IOSurfaceGetBaseAddress(b->surface), int(IOSurfaceGetWidth(b->surface)),
               int(IOSurfaceGetHeight(b->surface)), int(IOSurfaceGetBytesPerRow(b->surface)),
               QImage::Format_ARGB32_Premultiplied);
    img.copy().save(name);
    IOSurfaceUnlock(b->surface, kIOSurfaceLockReadOnly, nullptr);
}

} // namespace hm
