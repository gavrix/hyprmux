//! A Rust client for the Hyprmux client protocol (docs/CLIENT_PROTOCOL.md).
//!
//! It mirrors the low level of the Swift kit: connect through the broker, send
//! requests, and receive typed [`Event`]s on the main dispatch queue. Frame pacing,
//! swapchains, and input mapping belong to the toolkit using it.
//!
//! ```ignore
//! let client = Client::connect("dev.example.app", "Example", |event| { ... })?;
//! let top = client.create_toplevel("Example", None);
//! let buffer = client.register_iosurface(surface);
//! client.present(top.surface, buffer, 2.0, true);
//! ```
#![cfg(target_os = "macos")]

pub mod surface;
pub mod xpc;

use block2::RcBlock;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::ffi::CString;
use std::rc::Rc;
pub use xpc::{Dict, IOSurfaceRef, Message, Value};

pub const PROTOCOL_VERSION: u64 = 0;
pub const LOOKUP_SERVICE: &str = "dev.gavrix.hyprmux.compositor";
pub const INSTANCE_VARIABLE: &str = "HYPRMUX_INSTANCE";
pub const LAUNCH_TOKEN_VARIABLE: &str = "HYPRMUX_LAUNCH_TOKEN";

/// The Hyprmux instance this process belongs to (`HYPRMUX_INSTANCE`, else "default").
pub fn current_instance() -> String {
    std::env::var(INSTANCE_VARIABLE).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "default".into())
}

/// Whether Hyprmux started this process for a tile. Toolkits use it to pick the
/// Hyprmux backend over the native one.
pub fn launched_by_hyprmux() -> bool {
    std::env::var(LAUNCH_TOKEN_VARIABLE).is_ok_and(|s| !s.is_empty())
}

#[derive(Debug)]
pub enum Error {
    /// The broker isn't loaded (scripts/dev-broker.sh load, or SMAppService).
    BrokerUnavailable,
    /// No Hyprmux registered under this instance.
    NotRunning(String),
    Handshake(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::BrokerUnavailable => write!(f, "the Hyprmux broker isn't running"),
            Error::NotRunning(i) => write!(f, "no Hyprmux is running as instance \"{i}\""),
            Error::Handshake(m) => write!(f, "Hyprmux refused the connection: {m}"),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ButtonState {
    Down,
    Up,
}

/// Compositor-to-client events. Positions are surface points, top-left origin.
/// `modifiers` are AppKit's device-independent `NSEvent.ModifierFlags`.
#[derive(Debug, Clone)]
pub enum Event {
    Configure { toplevel: u64, width: f64, height: f64, scale: f64, states: Vec<String>, serial: u64 },
    CloseRequested { toplevel: u64 },
    FrameDone { callback: u64, target_time: f64 },
    BufferReleased { buffer: u64 },
    PointerEnter { surface: u64, x: f64, y: f64 },
    PointerLeave { surface: u64 },
    PointerMotion { surface: u64, x: f64, y: f64, buttons: u64, modifiers: u64 },
    PointerButton { surface: u64, x: f64, y: f64, button: u64, state: ButtonState, click_count: u64, modifiers: u64 },
    /// `dx`/`dy`: points when `precise` (trackpads), lines otherwise; `ticks_*` count
    /// raw wheel notches. `phase`/`momentum_phase` are `NSEvent.Phase` raw values.
    PointerScroll {
        surface: u64, x: f64, y: f64, dx: f64, dy: f64, precise: bool,
        phase: u64, momentum_phase: u64, ticks_x: f64, ticks_y: f64, modifiers: u64,
    },
    KeyboardEnter { surface: u64, modifiers: u64 },
    KeyboardLeave { surface: u64 },
    /// `key_code` is the macOS virtual key code; the strings match `NSEvent`.
    Key {
        surface: u64, key_code: u16, down: bool, repeat: bool, time: f64,
        characters: String, characters_ignoring_modifiers: String, modifiers: u64,
    },
    Modifiers { surface: u64, modifiers: u64 },
    TextPreedit { surface: u64, text: String, cursor_begin: u64, cursor_end: u64 },
    TextCommit { surface: u64, text: String },
    TextDeleteSurrounding { surface: u64, before: u64, after: u64 },
    /// Apply the text events since the last `TextDone` together.
    TextDone { surface: u64, serial: u64 },
    DialogResult { id: u64, result_json: String },
    MenuSelected { id: u64, item: Option<String> },
    /// A protocol error; the connection closes after it.
    ProtocolError { code: String, message: String },
    Disconnected { reason: String },
}

fn parse_event(m: Dict) -> Option<Event> {
    let surface = m.u64("surface");
    Some(match m.op().as_str() {
        "toplevel.configure" => Event::Configure {
            toplevel: m.u64("id"), width: m.f64("w"), height: m.f64("h"), scale: m.f64("scale"),
            states: m.strings("states"), serial: m.u64("serial"),
        },
        "toplevel.close_requested" => Event::CloseRequested { toplevel: m.u64("id") },
        "surface.frame_done" => Event::FrameDone { callback: m.u64("callback"), target_time: m.f64("target_time") },
        "buffer.release" => Event::BufferReleased { buffer: m.u64("id") },
        "pointer.enter" => Event::PointerEnter { surface, x: m.f64("x"), y: m.f64("y") },
        "pointer.leave" => Event::PointerLeave { surface },
        "pointer.motion" => Event::PointerMotion {
            surface, x: m.f64("x"), y: m.f64("y"), buttons: m.u64("buttons"), modifiers: m.u64("modifiers"),
        },
        "pointer.button" => Event::PointerButton {
            surface, x: m.f64("x"), y: m.f64("y"), button: m.u64("button"),
            state: if m.string("state").as_deref() == Some("down") { ButtonState::Down } else { ButtonState::Up },
            click_count: m.u64("click_count"), modifiers: m.u64("modifiers"),
        },
        "pointer.scroll" => Event::PointerScroll {
            surface, x: m.f64("x"), y: m.f64("y"), dx: m.f64("dx"), dy: m.f64("dy"), precise: m.bool("precise"),
            phase: m.u64("phase"), momentum_phase: m.u64("momentum_phase"),
            ticks_x: m.f64("ticks_x"), ticks_y: m.f64("ticks_y"), modifiers: m.u64("modifiers"),
        },
        "keyboard.enter" => Event::KeyboardEnter { surface, modifiers: m.u64("modifiers") },
        "keyboard.leave" => Event::KeyboardLeave { surface },
        "keyboard.key" => Event::Key {
            surface, key_code: m.u64("key_code") as u16, down: m.string("state").as_deref() == Some("down"),
            repeat: m.bool("repeat"), time: m.f64("time"),
            characters: m.string("characters").unwrap_or_default(),
            characters_ignoring_modifiers: m.string("characters_ignoring_modifiers").unwrap_or_default(),
            modifiers: m.u64("modifiers"),
        },
        "keyboard.modifiers" => Event::Modifiers { surface, modifiers: m.u64("modifiers") },
        "text_input.preedit" => Event::TextPreedit {
            surface, text: m.string("text").unwrap_or_default(),
            cursor_begin: m.u64("cursor_begin"), cursor_end: m.u64("cursor_end"),
        },
        "text_input.commit" => Event::TextCommit { surface, text: m.string("text").unwrap_or_default() },
        "text_input.delete_surrounding" => Event::TextDeleteSurrounding { surface, before: m.u64("before"), after: m.u64("after") },
        "text_input.done" => Event::TextDone { surface, serial: m.u64("serial") },
        "dialog.result" => Event::DialogResult { id: m.u64("id"), result_json: m.string("result_json").unwrap_or_default() },
        "menu.selected" => Event::MenuSelected { id: m.u64("id"), item: m.string("item") },
        "error" => Event::ProtocolError {
            code: m.string("code").unwrap_or_default(), message: m.string("message").unwrap_or_default(),
        },
        _ => return None,
    })
}

/// A toplevel and the surface under it. Input events name the surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Toplevel {
    pub id: u64,
    pub surface: u64,
}

/// A connection to Hyprmux. Single-threaded: use it, and receive events, on the
/// main thread.
pub struct Client {
    connection: xpc::xpc_connection_t,
    next_id: Cell<u64>,
    connected: Cell<bool>,
    _handler: RefCell<Option<RcBlock<dyn Fn(xpc::xpc_object_t)>>>,
}

impl Client {
    /// Looks up the compositor through the broker and says hello, presenting
    /// `HYPRMUX_LAUNCH_TOKEN` when Hyprmux launched this process. Blocks briefly.
    /// `on_event` runs on the main dispatch queue.
    pub fn connect(app_id: &str, name: &str, on_event: impl FnMut(Event) + 'static) -> Result<Rc<Client>, Error> {
        use xpc::*;
        let instance = current_instance();
        let service = CString::new(LOOKUP_SERVICE).unwrap();
        unsafe {
            let broker = xpc_connection_create_mach_service(service.as_ptr(), std::ptr::null_mut(), 0);
            let ignore = RcBlock::new(|_: xpc_object_t| {});
            xpc_connection_set_event_handler(broker, &ignore);
            xpc_connection_resume(broker);
            let lookup = Message::new("lookup", vec![("instance", Value::Str(instance.clone()))]);
            let found = xpc_connection_send_message_with_reply_sync(broker, lookup.0);
            let result = (|| {
                if !is_dictionary(found) {
                    return Err(Error::BrokerUnavailable);
                }
                let d = Dict(found);
                let endpoint = d.value("endpoint");
                if d.string("status").as_deref() != Some("ok") || endpoint.is_null() {
                    return Err(Error::NotRunning(instance.clone()));
                }
                Ok(xpc_connection_create_from_endpoint(endpoint))
            })();
            if !found.is_null() {
                xpc_release(found);
            }
            xpc_connection_cancel(broker);
            xpc_release(broker);
            let connection = result?;

            let client = Rc::new(Client {
                connection,
                next_id: Cell::new(1),
                connected: Cell::new(false),
                _handler: RefCell::new(None),
            });
            let weak = Rc::downgrade(&client);
            let on_event = RefCell::new(on_event);
            // Events that arrive while one is being handled (a handler that pumps the run
            // loop) wait their turn. Dropping one, a FrameDone say, can stall a window
            // forever.
            let queue: RefCell<VecDeque<Event>> = RefCell::new(VecDeque::new());
            let handler = RcBlock::new(move |o: xpc_object_t| {
                let event = if is_error(o) {
                    if let Some(c) = weak.upgrade() {
                        c.connected.set(false);
                    }
                    let reason = if is_connection_invalid(o) { "Hyprmux went away" } else { "connection interrupted" };
                    Some(Event::Disconnected { reason: reason.into() })
                } else if is_dictionary(o) {
                    parse_event(Dict(o))
                } else {
                    None
                };
                let Some(e) = event else { return };
                queue.borrow_mut().push_back(e);
                // Already delivering further up the stack: that loop picks this one up.
                let Ok(mut f) = on_event.try_borrow_mut() else { return };
                loop {
                    let next = queue.borrow_mut().pop_front();
                    let Some(next) = next else { break };
                    f(next);
                }
            });
            xpc_connection_set_target_queue(connection, main_queue());
            xpc_connection_set_event_handler(connection, &handler);
            *client._handler.borrow_mut() = Some(handler);
            xpc_connection_resume(connection);

            let mut hello = vec![
                ("version", Value::U64(PROTOCOL_VERSION)),
                ("app_id", Value::from(app_id)),
                ("name", Value::from(name)),
            ];
            if let Ok(token) = std::env::var(LAUNCH_TOKEN_VARIABLE) {
                if !token.is_empty() {
                    hello.push(("launch_token", Value::Str(token)));
                }
            }
            let hello = Message::new("hello", hello);
            let welcome = xpc_connection_send_message_with_reply_sync(connection, hello.0);
            let ok = is_dictionary(welcome) && Dict(welcome).op() == "welcome";
            let message = if is_dictionary(welcome) { Dict(welcome).string("message") } else { None };
            if !welcome.is_null() {
                xpc_release(welcome);
            }
            if !ok {
                xpc_connection_cancel(connection);
                return Err(Error::Handshake(message.unwrap_or_else(|| "no reply".into())));
            }
            client.connected.set(true);
            Ok(client)
        }
    }

    pub fn is_connected(&self) -> bool { self.connected.get() }

    /// A fresh object id. Clients allocate every id.
    pub fn allocate(&self) -> u64 {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        id
    }

    pub fn send(&self, op: &str, fields: Vec<(&str, Value)>) {
        if !self.connected.get() {
            return;
        }
        let m = Message::new(op, fields);
        unsafe { xpc::xpc_connection_send_message(self.connection, m.0) }
    }

    // MARK: Requests

    /// A new tile. Draw after its first `Configure`. A restore token lets a restored
    /// session put the toplevel back in its tile.
    pub fn create_toplevel(&self, title: &str, restore_token: Option<&str>) -> Toplevel {
        let surface = self.allocate();
        let id = self.allocate();
        self.send("surface.create", vec![("id", Value::U64(surface))]);
        let mut create = vec![("id", Value::U64(id)), ("surface", Value::U64(surface))];
        if let Some(t) = restore_token {
            create.push(("restore_token", Value::from(t)));
        }
        self.send("toplevel.create", create);
        self.set_title(Toplevel { id, surface }, title);
        Toplevel { id, surface }
    }

    pub fn set_title(&self, t: Toplevel, title: &str) {
        self.send("toplevel.set_title", vec![("id", Value::U64(t.id)), ("title", Value::from(title))]);
    }

    pub fn set_restore_token(&self, t: Toplevel, token: &str) {
        self.send("toplevel.set_restore_token", vec![("id", Value::U64(t.id)), ("token", Value::from(token))]);
    }

    pub fn ack_configure(&self, t: Toplevel, serial: u64) {
        self.send("toplevel.ack_configure", vec![("id", Value::U64(t.id)), ("serial", Value::U64(serial))]);
    }

    pub fn destroy_toplevel(&self, t: Toplevel) {
        self.send("toplevel.destroy", vec![("id", Value::U64(t.id))]);
        self.send("surface.destroy", vec![("id", Value::U64(t.surface))]);
    }

    /// Registers an IOSurface once; later frames refer to it by the returned id.
    pub fn register_iosurface(&self, surface: IOSurfaceRef) -> u64 {
        let id = self.allocate();
        let object = unsafe { xpc::IOSurfaceCreateXPCObject(surface) };
        self.send("buffer.create_iosurface", vec![("id", Value::U64(id)), ("surface", Value::Object(object))]);
        id
    }

    pub fn destroy_buffer(&self, buffer: u64) {
        self.send("buffer.destroy", vec![("id", Value::U64(buffer))]);
    }

    /// Attaches `buffer` to the surface and commits it. With `frame_callback`, asks
    /// for a `FrameDone` and returns its id.
    pub fn present(&self, surface: u64, buffer: u64, scale: f64, frame_callback: bool) -> Option<u64> {
        self.send("surface.attach", vec![("id", Value::U64(surface)), ("buffer", Value::U64(buffer))]);
        self.send("surface.set_scale", vec![("id", Value::U64(surface)), ("scale", Value::F64(scale))]);
        let callback = frame_callback.then(|| {
            let cb = self.allocate();
            self.send("surface.frame", vec![("id", Value::U64(surface)), ("callback", Value::U64(cb))]);
            cb
        });
        self.send("surface.commit", vec![("id", Value::U64(surface))]);
        callback
    }

    /// Asks for a `FrameDone` without a new buffer: "tell me when to draw next".
    pub fn request_frame(&self, surface: u64) -> u64 {
        let cb = self.allocate();
        self.send("surface.frame", vec![("id", Value::U64(surface)), ("callback", Value::U64(cb))]);
        self.send("surface.commit", vec![("id", Value::U64(surface))]);
        cb
    }

    /// A named cursor: "arrow", "ibeam", "pointing_hand", "crosshair", "open_hand",
    /// "closed_hand", "resize_left_right", "resize_up_down", "not_allowed", "hidden".
    pub fn set_cursor(&self, name: &str) {
        self.send("pointer.set_cursor", vec![("name", Value::from(name))]);
    }

    /// Text input for a surface. Without `compositor_preedit`, the client draws
    /// compositions itself (TextPreedit).
    pub fn enable_text_input(&self, surface: u64, compositor_preedit: bool) {
        self.send("text_input.enable", vec![
            ("surface", Value::U64(surface)),
            ("preedit", Value::from(if compositor_preedit { "compositor" } else { "client" })),
        ]);
    }

    pub fn disable_text_input(&self, surface: u64) {
        self.send("text_input.disable", vec![("surface", Value::U64(surface))]);
    }

    /// The caret, in surface points, for the input method's candidate window.
    pub fn set_text_cursor_rect(&self, surface: u64, x: f64, y: f64, w: f64, h: f64) {
        self.send("text_input.set_cursor_rect", vec![
            ("surface", Value::U64(surface)), ("x", Value::F64(x)), ("y", Value::F64(y)),
            ("w", Value::F64(w)), ("h", Value::F64(h)),
        ]);
    }

    /// A native dialog over the tile ("open", "save", "message"; options and result in
    /// Electron's `dialog` shapes, as JSON). Returns the id `DialogResult` answers to.
    pub fn open_dialog(&self, surface: u64, kind: &str, options_json: &str) -> u64 {
        let id = self.allocate();
        self.send("dialog.open", vec![
            ("id", Value::U64(id)), ("surface", Value::U64(surface)),
            ("kind", Value::from(kind)), ("options_json", Value::from(options_json)),
        ]);
        id
    }

    /// A native menu at a point in the tile. Returns the id `MenuSelected` answers to.
    pub fn popup_menu(&self, surface: u64, x: f64, y: f64, items_json: &str) -> u64 {
        let id = self.allocate();
        self.send("menu.popup", vec![
            ("id", Value::U64(id)), ("surface", Value::U64(surface)),
            ("x", Value::F64(x)), ("y", Value::F64(y)), ("items_json", Value::from(items_json)),
        ]);
        id
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        unsafe {
            xpc::xpc_connection_cancel(self.connection);
            xpc::xpc_release(self.connection);
        }
    }
}
