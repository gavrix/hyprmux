#include "Connection.h"

#include <cstdlib>
#include <cstring>

namespace hm {

static const char *kLookupService = "dev.gavrix.hyprmux.compositor";
static const uint64_t kProtocolVersion = 0;

Message::Message(const char *op) : dict_(xpc_dictionary_create(nullptr, nullptr, 0)) {
    xpc_dictionary_set_string(dict_, "op", op);
}

Message::~Message() { xpc_release(dict_); }

Message &Message::u64(const char *key, uint64_t v) { xpc_dictionary_set_uint64(dict_, key, v); return *this; }
Message &Message::f64(const char *key, double v) { xpc_dictionary_set_double(dict_, key, v); return *this; }
Message &Message::boolean(const char *key, bool v) { xpc_dictionary_set_bool(dict_, key, v); return *this; }
Message &Message::str(const char *key, const std::string &v) { xpc_dictionary_set_string(dict_, key, v.c_str()); return *this; }
Message &Message::object(const char *key, xpc_object_t v) {
    xpc_dictionary_set_value(dict_, key, v);
    xpc_release(v);
    return *this;
}

std::string Event::str(const char *key) const {
    const char *s = xpc_dictionary_get_string(dict, key);
    return s ? std::string(s) : std::string();
}

bool Event::hasString(const char *key, const char *value) const {
    const char *s = xpc_dictionary_get_string(dict, key);
    return s && std::strcmp(s, value) == 0;
}

static std::string env(const char *name, const char *fallback) {
    const char *v = std::getenv(name);
    return (v && *v) ? std::string(v) : std::string(fallback);
}

Connection *Connection::connect(const std::string &appID, const std::string &name, std::string *error) {
    std::string instance = env("HYPRMUX_INSTANCE", "default");

    // 1. Ask the broker for this instance's endpoint.
    xpc_connection_t broker = xpc_connection_create_mach_service(kLookupService, nullptr, 0);
    xpc_connection_set_event_handler(broker, ^(xpc_object_t) {});
    xpc_connection_resume(broker);
    Message lookup("lookup");
    lookup.str("instance", instance);
    xpc_object_t found = xpc_connection_send_message_with_reply_sync(broker, lookup.raw());
    xpc_connection_t conn = nullptr;
    if (xpc_get_type(found) != XPC_TYPE_DICTIONARY) {
        if (error) *error = "the Hyprmux broker isn't running";
    } else {
        const char *status = xpc_dictionary_get_string(found, "status");
        xpc_object_t endpoint = xpc_dictionary_get_value(found, "endpoint");
        if (!status || std::strcmp(status, "ok") != 0 || !endpoint) {
            if (error) *error = "no Hyprmux is running as instance \"" + instance + "\"";
        } else {
            conn = xpc_connection_create_from_endpoint((xpc_endpoint_t)endpoint);
        }
    }
    xpc_release(found);
    xpc_connection_cancel(broker);
    xpc_release(broker);
    if (!conn) return nullptr;

    // 2. Connect and say hello.
    auto *c = new Connection();
    c->conn_ = conn;
    xpc_connection_set_target_queue(conn, dispatch_get_main_queue());
    xpc_connection_set_event_handler(conn, ^(xpc_object_t o) { c->deliver(o); });
    xpc_connection_resume(conn);

    Message hello("hello");
    hello.u64("version", kProtocolVersion).str("app_id", appID).str("name", name);
    // The host answers configures at once (Scene::configure renders right away), so
    // Hyprmux may show its frames 1:1 during a resize instead of stretching them.
    xpc_object_t caps = xpc_array_create(nullptr, 0);
    xpc_array_set_string(caps, XPC_ARRAY_APPEND, "anchored-resize");
    hello.object("capabilities", caps);
    std::string token = env("HYPRMUX_LAUNCH_TOKEN", "");
    if (!token.empty()) hello.str("launch_token", token);
    xpc_object_t welcome = xpc_connection_send_message_with_reply_sync(conn, hello.raw());
    bool ok = xpc_get_type(welcome) == XPC_TYPE_DICTIONARY
        && xpc_dictionary_get_string(welcome, "op")
        && std::strcmp(xpc_dictionary_get_string(welcome, "op"), "welcome") == 0;
    if (ok) {
        double scale = xpc_dictionary_get_double(welcome, "scale");
        if (scale > 0) c->welcomeScale_ = scale;
        if (const char *theme = xpc_dictionary_get_string(welcome, "theme_json")) c->welcomeTheme_ = theme;
    } else if (error) {
        const char *m = xpc_get_type(welcome) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(welcome, "message") : nullptr;
        *error = std::string("Hyprmux refused the connection: ") + (m ? m : "no reply");
    }
    xpc_release(welcome);
    if (!ok) {
        xpc_connection_cancel(conn);
        return nullptr;
    }
    c->connected_ = true;
    return c;
}

void Connection::send(const Message &m) {
    if (connected_) xpc_connection_send_message(conn_, m.raw());
}

void Connection::deliver(xpc_object_t o) {
    xpc_type_t type = xpc_get_type(o);
    if (type == XPC_TYPE_ERROR) {
        connected_ = false;
        if (onDisconnect_) onDisconnect_(o == XPC_ERROR_CONNECTION_INVALID ? "Hyprmux went away" : "connection interrupted");
        return;
    }
    if (type == XPC_TYPE_DICTIONARY && handler_) handler_(Event{o});
}

} // namespace hm
