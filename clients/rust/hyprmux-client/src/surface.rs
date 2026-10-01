//! IOSurface allocation, for clients without their own (GPU toolkits usually
//! wrap these in Metal textures).
#![allow(non_upper_case_globals)]

use crate::xpc::{CFTypeRef, IOSurfaceRef};
use std::ffi::c_void;

type CFStringRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFNumberRef = *const c_void;

#[repr(C)]
struct CFDictionaryCallBacks([usize; 6]);

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeDictionaryKeyCallBacks: CFDictionaryCallBacks;
    static kCFTypeDictionaryValueCallBacks: CFDictionaryCallBacks;
    fn CFDictionaryCreate(
        allocator: *const c_void, keys: *const CFTypeRef, values: *const CFTypeRef, count: isize,
        key_callbacks: *const CFDictionaryCallBacks, value_callbacks: *const CFDictionaryCallBacks,
    ) -> CFDictionaryRef;
    fn CFNumberCreate(allocator: *const c_void, the_type: isize, value_ptr: *const c_void) -> CFNumberRef;
    fn CFRelease(cf: CFTypeRef);
}

#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    static kIOSurfaceWidth: CFStringRef;
    static kIOSurfaceHeight: CFStringRef;
    static kIOSurfaceBytesPerElement: CFStringRef;
    static kIOSurfacePixelFormat: CFStringRef;
    fn IOSurfaceCreate(properties: CFDictionaryRef) -> IOSurfaceRef;
    fn IOSurfaceLock(buffer: IOSurfaceRef, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceUnlock(buffer: IOSurfaceRef, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceGetBaseAddress(buffer: IOSurfaceRef) -> *mut c_void;
    fn IOSurfaceGetBytesPerRow(buffer: IOSurfaceRef) -> usize;
    fn IOSurfaceGetWidth(buffer: IOSurfaceRef) -> usize;
    fn IOSurfaceGetHeight(buffer: IOSurfaceRef) -> usize;
}

/// 'BGRA', the only format protocol v0 accepts.
pub const PIXEL_FORMAT_BGRA: u32 = 0x4247_5241;

/// An owned BGRA8 IOSurface.
pub struct Surface(pub IOSurfaceRef);

impl Surface {
    pub fn new(width: usize, height: usize) -> Option<Surface> {
        const K_CF_NUMBER_SINT64: isize = 4;
        unsafe {
            let values: [i64; 4] = [width as i64, height as i64, 4, PIXEL_FORMAT_BGRA as i64];
            let numbers: Vec<CFTypeRef> = values
                .iter()
                .map(|v| CFNumberCreate(std::ptr::null(), K_CF_NUMBER_SINT64, v as *const i64 as *const c_void))
                .collect();
            let keys: [CFTypeRef; 4] = [kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat];
            let dict = CFDictionaryCreate(
                std::ptr::null(), keys.as_ptr(), numbers.as_ptr(), 4,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks,
            );
            for n in numbers {
                CFRelease(n);
            }
            let s = IOSurfaceCreate(dict);
            CFRelease(dict);
            (!s.is_null()).then_some(Surface(s))
        }
    }

    pub fn width(&self) -> usize { unsafe { IOSurfaceGetWidth(self.0) } }
    pub fn height(&self) -> usize { unsafe { IOSurfaceGetHeight(self.0) } }

    /// Fills the surface with one BGRA color, for demos and placeholders.
    pub fn fill(&self, bgra: [u8; 4]) {
        unsafe {
            IOSurfaceLock(self.0, 0, std::ptr::null_mut());
            let base = IOSurfaceGetBaseAddress(self.0) as *mut u8;
            let stride = IOSurfaceGetBytesPerRow(self.0);
            let (w, h) = (self.width(), self.height());
            for y in 0..h {
                let row = std::slice::from_raw_parts_mut(base.add(y * stride), w * 4);
                for px in row.chunks_exact_mut(4) {
                    px.copy_from_slice(&bgra);
                }
            }
            IOSurfaceUnlock(self.0, 0, std::ptr::null_mut());
        }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0 as CFTypeRef) }
    }
}
