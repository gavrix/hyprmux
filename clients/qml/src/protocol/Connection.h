// A minimal Hyprmux client-protocol connection over raw libxpc
// (docs/CLIENT_PROTOCOL.md). Single-threaded: events arrive on the main queue,
// which Qt's Cocoa event loop drains.
#pragma once

#include <xpc/xpc.h>

#include <cstdint>
#include <functional>
#include <string>

namespace hm {

/// An outgoing message. Owns its XPC dictionary until it is sent.
class Message {
public:
    explicit Message(const char *op);
    ~Message();
    Message(const Message &) = delete;
    Message &operator=(const Message &) = delete;

    Message &u64(const char *key, uint64_t v);
    Message &f64(const char *key, double v);
    Message &boolean(const char *key, bool v);
    Message &str(const char *key, const std::string &v);
    /// Takes ownership of `v`.
    Message &object(const char *key, xpc_object_t v);

    xpc_object_t raw() const { return dict_; }

private:
    xpc_object_t dict_;
};

/// Read access to an incoming event. The connection owns the dictionary.
struct Event {
    xpc_object_t dict;

    std::string op() const { return str("op"); }
    std::string str(const char *key) const;
    uint64_t u64(const char *key) const { return xpc_dictionary_get_uint64(dict, key); }
    double f64(const char *key) const { return xpc_dictionary_get_double(dict, key); }
    bool boolean(const char *key) const { return xpc_dictionary_get_bool(dict, key); }
    bool hasString(const char *key, const char *value) const;
};

class Connection {
public:
    using Handler = std::function<void(const Event &)>;
    using DisconnectHandler = std::function<void(const std::string &reason)>;

    /// Looks Hyprmux up through the broker and says hello. Blocks briefly.
    /// Returns nullptr and sets `error` when Hyprmux can't be reached.
    static Connection *connect(const std::string &appID, const std::string &name, std::string *error);

    void setHandler(Handler h) { handler_ = std::move(h); }
    void setDisconnectHandler(DisconnectHandler h) { onDisconnect_ = std::move(h); }

    /// Scale from the welcome message: the main screen's backing scale.
    double welcomeScale() const { return welcomeScale_; }
    /// Hyprmux's look from the welcome message (`theme_json`); empty from an older Hyprmux.
    const std::string &welcomeTheme() const { return welcomeTheme_; }

    /// A fresh object id. Clients allocate every id.
    uint64_t allocate() { return nextID_++; }
    void send(const Message &m);

private:
    Connection() = default;
    void deliver(xpc_object_t o);

    xpc_connection_t conn_ = nullptr;
    uint64_t nextID_ = 1;
    double welcomeScale_ = 2;
    std::string welcomeTheme_;
    bool connected_ = false;
    Handler handler_;
    DisconnectHandler onDisconnect_;
};

} // namespace hm
