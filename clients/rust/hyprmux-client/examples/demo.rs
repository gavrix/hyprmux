//! A minimal client: one tile, a solid color that changes on click, and input logged
//! to stderr. Run it next to a test instance:
//!   HYPRMUX_INSTANCE=test cargo run --example demo
use hyprmux_client::{surface::Surface, ButtonState, Client, Event, Toplevel};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

extern "C" {
    fn dispatch_main() -> !;
}

#[derive(Default)]
struct State {
    client: Option<Rc<Client>>,
    top: Option<Toplevel>,
    // Size in pixels -> registered buffer. One buffer is enough for a solid color.
    buffers: HashMap<(usize, usize), (Surface, u64)>,
    size: (usize, usize),
    scale: f64,
    color: usize,
}

const COLORS: [[u8; 4]; 4] = [[0x80, 0x40, 0x20, 0xff], [0x20, 0x80, 0x40, 0xff], [0x40, 0x20, 0x80, 0xff], [0x30, 0x30, 0x30, 0xff]];

impl State {
    fn draw(&mut self) {
        let (Some(client), Some(top)) = (self.client.clone(), self.top) else { return };
        let (w, h) = self.size;
        if w == 0 || h == 0 {
            return;
        }
        let entry = self.buffers.entry((w, h)).or_insert_with(|| {
            let s = Surface::new(w, h).expect("IOSurface");
            let id = client.register_iosurface(s.0);
            (s, id)
        });
        entry.0.fill(COLORS[self.color % COLORS.len()]);
        client.present(top.surface, entry.1, self.scale, false);
    }
}

fn main() {
    let state = Rc::new(RefCell::new(State { scale: 2.0, ..Default::default() }));
    let s = state.clone();
    let client = Client::connect("dev.gavrix.hyprmux.rust-demo", "Rust demo", move |event| {
        eprintln!("event: {event:?}");
        let mut st = s.borrow_mut();
        match event {
            Event::Configure { toplevel, width, height, scale, serial, .. } => {
                let client = st.client.clone().unwrap();
                let top = st.top.unwrap();
                assert_eq!(toplevel, top.id);
                client.ack_configure(top, serial);
                st.scale = if scale > 0.0 { scale } else { 2.0 };
                st.size = ((width * st.scale).round() as usize, (height * st.scale).round() as usize);
                st.draw();
            }
            Event::PointerButton { state: ButtonState::Down, .. } => {
                st.color += 1;
                st.draw();
            }
            Event::CloseRequested { .. } | Event::Disconnected { .. } => std::process::exit(0),
            _ => {}
        }
    })
    .unwrap_or_else(|e| {
        eprintln!("demo: {e}");
        std::process::exit(1);
    });
    let top = client.create_toplevel("Rust demo", None);
    {
        let mut st = state.borrow_mut();
        st.client = Some(client);
        st.top = Some(top);
    }
    unsafe { dispatch_main() }
}
