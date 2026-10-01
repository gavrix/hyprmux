//! Measures frame-callback latency: request_frame -> FrameDone. Idle requests (100 ms
//! apart, like a GPUI window that just got dirty) and back-to-back ones (continuous
//! animation). Run next to a test instance: HYPRMUX_INSTANCE=test cargo run --example latency
use hyprmux_client::{surface::Surface, Client, Event, Toplevel};
use std::cell::RefCell;
use std::ffi::c_void;
use std::rc::Rc;
use std::time::Instant;

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRunLoopRun();
}

extern "C" {
    fn dispatch_time(when: u64, delta: i64) -> u64;
    fn dispatch_after_f(when: u64, queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
}

struct S {
    client: Option<Rc<Client>>,
    top: Option<Toplevel>,
    buffer: Option<(Surface, u64)>,
    sent: Option<Instant>,
    idle: Vec<f64>,
    busy: Vec<f64>,
}

thread_local!(static STATE: RefCell<S> = RefCell::new(S { client: None, top: None, buffer: None, sent: None, idle: vec![], busy: vec![] }));

extern "C" fn tick(_: *mut c_void) { request(); }

fn request() {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let (c, t) = (s.client.clone().unwrap(), s.top.unwrap());
        s.sent = Some(Instant::now());
        c.request_frame(t.surface);
    });
}

fn after_ms(ms: u64) {
    unsafe { dispatch_after_f(dispatch_time(0, (ms * 1_000_000) as i64), hyprmux_client::xpc::main_queue(), std::ptr::null_mut(), tick) }
}

fn report(name: &str, v: &mut Vec<f64>) {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{name:6} n={} p50 {:.1} ms  p90 {:.1} ms  max {:.1} ms", v.len(), v[v.len() / 2], v[v.len() * 9 / 10], v[v.len() - 1]);
}

fn main() {
    let client = Client::connect("dev.gavrix.hyprmux.latency", "Latency", |e| match { if std::env::var("LAT_DEBUG").is_ok() { eprintln!("{e:?}"); } e } {
        Event::Configure { width, height, scale, serial, .. } => STATE.with(|s| {
            let mut s = s.borrow_mut();
            let (c, t) = (s.client.clone().unwrap(), s.top.unwrap());
            c.ack_configure(t, serial);
            if s.buffer.is_none() {
                let surf = Surface::new((width * scale) as usize, (height * scale) as usize).unwrap();
                surf.fill([0x30, 0x30, 0x30, 0xff]);
                let id = c.register_iosurface(surf.0);
                c.present(t.surface, id, scale, false);
                s.buffer = Some((surf, id));
                drop(s);
                after_ms(500);
            }
        }),
        Event::FrameDone { .. } => {
            let done = STATE.with(|s| {
                let mut s = s.borrow_mut();
                let ms = s.sent.take().unwrap().elapsed().as_secs_f64() * 1000.0;
                if s.idle.len() < 40 { s.idle.push(ms); } else { s.busy.push(ms); }
                (s.idle.len(), s.busy.len())
            });
            match done {
                (i, 0) if i < 40 => after_ms(100),
                (_, b) if b < 120 => request(),
                _ => {
                    STATE.with(|s| { let mut s = s.borrow_mut(); report("idle", &mut s.idle); report("busy", &mut s.busy); });
                    std::process::exit(0);
                }
            }
        }
        _ => {}
    }).unwrap();
    let top = client.create_toplevel("Latency", None);
    STATE.with(|s| { let mut s = s.borrow_mut(); s.client = Some(client); s.top = Some(top); });
    // Not dispatch_main(): it ends the main thread, which drops thread-locals (the client).
    unsafe { CFRunLoopRun() }
}
