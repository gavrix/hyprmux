//! The libxpc, libdispatch, and IOSurface calls the client needs. All of them are
//! in libSystem and the IOSurface framework, so the crate needs no -sys crates.
#![allow(non_camel_case_types, non_upper_case_globals, dead_code)]

use block2::Block;
use std::ffi::{c_char, c_void, CStr, CString};

pub type xpc_object_t = *mut c_void;
pub type xpc_connection_t = *mut c_void;
pub type xpc_type_t = *const c_void;
pub type dispatch_queue_t = *mut c_void;
pub type IOSurfaceRef = *mut c_void;
pub type CFTypeRef = *const c_void;

#[link(name = "System", kind = "dylib")]
extern "C" {
    pub fn xpc_connection_create_mach_service(name: *const c_char, targetq: dispatch_queue_t, flags: u64) -> xpc_connection_t;
    pub fn xpc_connection_create_from_endpoint(endpoint: xpc_object_t) -> xpc_connection_t;
    pub fn xpc_connection_set_event_handler(connection: xpc_connection_t, handler: &Block<dyn Fn(xpc_object_t)>);
    pub fn xpc_connection_set_target_queue(connection: xpc_connection_t, targetq: dispatch_queue_t);
    pub fn xpc_connection_resume(connection: xpc_connection_t);
    pub fn xpc_connection_cancel(connection: xpc_connection_t);
    pub fn xpc_connection_send_message(connection: xpc_connection_t, message: xpc_object_t);
    pub fn xpc_connection_send_message_with_reply_sync(connection: xpc_connection_t, message: xpc_object_t) -> xpc_object_t;

    pub fn xpc_dictionary_create(keys: *const *const c_char, values: *const xpc_object_t, count: usize) -> xpc_object_t;
    pub fn xpc_dictionary_set_string(d: xpc_object_t, key: *const c_char, value: *const c_char);
    pub fn xpc_dictionary_set_uint64(d: xpc_object_t, key: *const c_char, value: u64);
    pub fn xpc_dictionary_set_int64(d: xpc_object_t, key: *const c_char, value: i64);
    pub fn xpc_dictionary_set_double(d: xpc_object_t, key: *const c_char, value: f64);
    pub fn xpc_dictionary_set_bool(d: xpc_object_t, key: *const c_char, value: bool);
    pub fn xpc_dictionary_set_value(d: xpc_object_t, key: *const c_char, value: xpc_object_t);
    pub fn xpc_dictionary_get_string(d: xpc_object_t, key: *const c_char) -> *const c_char;
    pub fn xpc_dictionary_get_uint64(d: xpc_object_t, key: *const c_char) -> u64;
    pub fn xpc_dictionary_get_int64(d: xpc_object_t, key: *const c_char) -> i64;
    pub fn xpc_dictionary_get_double(d: xpc_object_t, key: *const c_char) -> f64;
    pub fn xpc_dictionary_get_bool(d: xpc_object_t, key: *const c_char) -> bool;
    pub fn xpc_dictionary_get_value(d: xpc_object_t, key: *const c_char) -> xpc_object_t;

    pub fn xpc_array_create(objects: *const xpc_object_t, count: usize) -> xpc_object_t;
    pub fn xpc_array_append_value(a: xpc_object_t, value: xpc_object_t);
    pub fn xpc_array_get_count(a: xpc_object_t) -> usize;
    pub fn xpc_array_get_string(a: xpc_object_t, index: usize) -> *const c_char;
    pub fn xpc_string_create(s: *const c_char) -> xpc_object_t;

    pub fn xpc_get_type(object: xpc_object_t) -> xpc_type_t;
    pub fn xpc_retain(object: xpc_object_t) -> xpc_object_t;
    pub fn xpc_release(object: xpc_object_t);

    pub static _xpc_type_dictionary: c_void;
    pub static _xpc_type_error: c_void;
    pub static _xpc_type_array: c_void;
    pub static _xpc_error_connection_invalid: c_void;
    pub static _xpc_error_connection_interrupted: c_void;

    pub static _dispatch_main_q: c_void;
}

#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    pub fn IOSurfaceCreateXPCObject(surface: IOSurfaceRef) -> xpc_object_t;
}

pub fn main_queue() -> dispatch_queue_t {
    unsafe { &_dispatch_main_q as *const c_void as dispatch_queue_t }
}

pub fn is_dictionary(o: xpc_object_t) -> bool {
    !o.is_null() && unsafe { xpc_get_type(o) == &_xpc_type_dictionary as *const c_void }
}

pub fn is_error(o: xpc_object_t) -> bool {
    !o.is_null() && unsafe { xpc_get_type(o) == &_xpc_type_error as *const c_void }
}

pub fn is_connection_invalid(o: xpc_object_t) -> bool {
    o == unsafe { &_xpc_error_connection_invalid as *const c_void as xpc_object_t }
}

fn key(k: &str) -> CString {
    CString::new(k).expect("protocol keys have no NUL")
}

/// A value in an outgoing message. Ids and counts are `U64`: the compositor reads
/// them with `xpc_dictionary_get_uint64`, which returns 0 for an int64.
pub enum Value {
    Str(String),
    U64(u64),
    I64(i64),
    F64(f64),
    Bool(bool),
    Strings(Vec<String>),
    /// An XPC object the message takes over (released after sending).
    Object(xpc_object_t),
}

impl From<&str> for Value {
    fn from(v: &str) -> Self { Value::Str(v.to_owned()) }
}
impl From<String> for Value {
    fn from(v: String) -> Self { Value::Str(v) }
}
impl From<u64> for Value {
    fn from(v: u64) -> Self { Value::U64(v) }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self { Value::F64(v) }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self { Value::Bool(v) }
}

/// An owned XPC dictionary.
pub struct Message(pub xpc_object_t);

impl Message {
    pub fn new(op: &str, fields: Vec<(&str, Value)>) -> Self {
        let d = unsafe { xpc_dictionary_create(std::ptr::null(), std::ptr::null(), 0) };
        let m = Message(d);
        m.set("op", Value::Str(op.to_owned()));
        for (k, v) in fields {
            m.set(k, v);
        }
        m
    }

    pub fn set(&self, k: &str, v: Value) {
        let k = key(k);
        unsafe {
            match v {
                Value::Str(s) => {
                    let s = CString::new(s.replace('\0', "")).unwrap();
                    xpc_dictionary_set_string(self.0, k.as_ptr(), s.as_ptr())
                }
                Value::U64(n) => xpc_dictionary_set_uint64(self.0, k.as_ptr(), n),
                Value::I64(n) => xpc_dictionary_set_int64(self.0, k.as_ptr(), n),
                Value::F64(n) => xpc_dictionary_set_double(self.0, k.as_ptr(), n),
                Value::Bool(b) => xpc_dictionary_set_bool(self.0, k.as_ptr(), b),
                Value::Strings(list) => {
                    let a = xpc_array_create(std::ptr::null(), 0);
                    for s in list {
                        let s = CString::new(s.replace('\0', "")).unwrap();
                        let o = xpc_string_create(s.as_ptr());
                        xpc_array_append_value(a, o);
                        xpc_release(o);
                    }
                    xpc_dictionary_set_value(self.0, k.as_ptr(), a);
                    xpc_release(a);
                }
                Value::Object(o) => {
                    xpc_dictionary_set_value(self.0, k.as_ptr(), o);
                    xpc_release(o);
                }
            }
        }
    }
}

impl Drop for Message {
    fn drop(&mut self) {
        unsafe { xpc_release(self.0) }
    }
}

/// Read access to a dictionary someone else owns (an event or a reply).
#[derive(Clone, Copy)]
pub struct Dict(pub xpc_object_t);

impl Dict {
    pub fn string(&self, k: &str) -> Option<String> {
        let k = key(k);
        let p = unsafe { xpc_dictionary_get_string(self.0, k.as_ptr()) };
        (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    }
    pub fn u64(&self, k: &str) -> u64 {
        let k = key(k);
        unsafe { xpc_dictionary_get_uint64(self.0, k.as_ptr()) }
    }
    pub fn f64(&self, k: &str) -> f64 {
        let k = key(k);
        unsafe { xpc_dictionary_get_double(self.0, k.as_ptr()) }
    }
    pub fn bool(&self, k: &str) -> bool {
        let k = key(k);
        unsafe { xpc_dictionary_get_bool(self.0, k.as_ptr()) }
    }
    pub fn value(&self, k: &str) -> xpc_object_t {
        let k = key(k);
        unsafe { xpc_dictionary_get_value(self.0, k.as_ptr()) }
    }
    pub fn strings(&self, k: &str) -> Vec<String> {
        let a = self.value(k);
        if a.is_null() || unsafe { xpc_get_type(a) } != unsafe { &_xpc_type_array as *const c_void } {
            return Vec::new();
        }
        (0..unsafe { xpc_array_get_count(a) })
            .filter_map(|i| {
                let p = unsafe { xpc_array_get_string(a, i) };
                (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
            })
            .collect()
    }
    pub fn op(&self) -> String {
        self.string("op").unwrap_or_default()
    }
}
