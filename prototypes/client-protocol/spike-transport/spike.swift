// Transport spike for docs/CLIENT_PROTOCOL.md, section 3.
//
//   spike broker       launchd job; owns the mach service name, stores one endpoint
//   spike compositor   anonymous listener; registers its endpoint with the broker
//   spike client       looks up the endpoint, connects, sends IOSurfaces
//
// Questions: does endpoint brokering work for ad-hoc signed binaries? Does an
// IOSurface survive the trip zero-copy (same memory, not a copy)? What does a
// round trip cost?

import Foundation
import IOSurface
import XPC

let serviceName = "dev.gavrix.hyprmux.spike.compositor"

func log(_ s: String) { FileHandle.standardError.write("[\(CommandLine.arguments[1])] \(s)\n".data(using: .utf8)!) }
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func dict(_ pairs: [String: xpc_object_t]) -> xpc_object_t {
    let d = xpc_dictionary_create(nil, nil, 0)
    for (k, v) in pairs { xpc_dictionary_set_value(d, k, v) }
    return d
}
func str(_ s: String) -> xpc_object_t { xpc_string_create(s) }
func op(_ m: xpc_object_t) -> String? { xpc_dictionary_get_string(m, "op").map { String(cString: $0) } }

// MARK: broker

func runBroker() -> Never {
    var endpoint: xpc_object_t?
    let listener = xpc_connection_create_mach_service(serviceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        let peerConn = peer as xpc_connection_t
        log("peer pid \(xpc_connection_get_pid(peerConn))")
        xpc_connection_set_event_handler(peerConn) { msg in
            guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else { return }
            let reply = xpc_dictionary_create_reply(msg)!
            switch op(msg) {
            case "register":
                endpoint = xpc_dictionary_get_value(msg, "endpoint")
                xpc_dictionary_set_string(reply, "status", "ok")
                log("registered endpoint")
            case "lookup":
                if let e = endpoint { xpc_dictionary_set_value(reply, "endpoint", e); xpc_dictionary_set_string(reply, "status", "ok") }
                else { xpc_dictionary_set_string(reply, "status", "not_running") }
            default:
                xpc_dictionary_set_string(reply, "status", "bad_op")
            }
            xpc_connection_send_message(peerConn, reply)
        }
        xpc_connection_resume(peerConn)
    }
    xpc_connection_resume(listener)
    log("listening on \(serviceName)")
    dispatchMain()
}

// MARK: compositor

func runCompositor() -> Never {
    var buffers: [UInt64: IOSurfaceRef] = [:]
    let listener = xpc_connection_create(nil, nil)
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        let c = peer as xpc_connection_t
        log("client pid \(xpc_connection_get_pid(c)) uid \(xpc_connection_get_euid(c))")
        xpc_connection_set_event_handler(c) { msg in
            guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else { return }
            let reply = xpc_dictionary_create_reply(msg)!
            switch op(msg) {
            case "ping":
                break
            case "buffer.create_iosurface":
                let id = xpc_dictionary_get_uint64(msg, "id")
                guard let obj = xpc_dictionary_get_value(msg, "surface"),
                      let s = IOSurfaceLookupFromXPCObject(obj) else {
                    xpc_dictionary_set_string(reply, "error", "no surface"); break
                }
                buffers[id] = s
                xpc_dictionary_set_uint64(reply, "global_id", UInt64(IOSurfaceGetID(s)))
                xpc_dictionary_set_uint64(reply, "w", UInt64(IOSurfaceGetWidth(s)))
                xpc_dictionary_set_uint64(reply, "h", UInt64(IOSurfaceGetHeight(s)))
            case "surface.commit":
                // Read the first pixel the client wrote, to prove the memory is shared.
                let id = xpc_dictionary_get_uint64(msg, "buffer")
                guard let s = buffers[id] else { xpc_dictionary_set_string(reply, "error", "unknown buffer"); break }
                IOSurfaceLock(s, [.readOnly], nil)
                let px = IOSurfaceGetBaseAddress(s).load(as: UInt32.self)
                IOSurfaceUnlock(s, [.readOnly], nil)
                xpc_dictionary_set_uint64(reply, "pixel", UInt64(px))
            default:
                xpc_dictionary_set_string(reply, "error", "bad op")
            }
            xpc_connection_send_message(c, reply)
        }
        xpc_connection_resume(c)
    }
    xpc_connection_resume(listener)

    let broker = xpc_connection_create_mach_service(serviceName, nil, 0)
    xpc_connection_set_event_handler(broker) { e in if xpc_get_type(e) == XPC_TYPE_ERROR { log("broker error") } }
    xpc_connection_resume(broker)
    let r = xpc_connection_send_message_with_reply_sync(broker, dict(["op": str("register"), "endpoint": xpc_endpoint_create(listener)]))
    log("register → \(xpc_dictionary_get_string(r, "status").map { String(cString: $0) } ?? "error")")
    dispatchMain()
}

// MARK: client

func makeSurface(_ w: Int, _ h: Int) -> IOSurfaceRef {
    let props: [String: Any] = [
        kIOSurfaceWidth as String: w, kIOSurfaceHeight as String: h,
        kIOSurfaceBytesPerElement as String: 4, kIOSurfacePixelFormat as String: 0x42475241, // 'BGRA'
    ]
    return IOSurfaceCreate(props as CFDictionary)!
}

func runClient() {
    let broker = xpc_connection_create_mach_service(serviceName, nil, 0)
    xpc_connection_set_event_handler(broker) { _ in }
    xpc_connection_resume(broker)
    let t0 = now()
    let lookup = xpc_connection_send_message_with_reply_sync(broker, dict(["op": str("lookup")]))
    guard xpc_get_type(lookup) == XPC_TYPE_DICTIONARY,
          let endpoint = xpc_dictionary_get_value(lookup, "endpoint") else {
        log("lookup failed: \(xpc_get_type(lookup) == XPC_TYPE_ERROR ? "xpc error" : (xpc_dictionary_get_string(lookup, "status").map { String(cString: $0) } ?? "?"))")
        exit(1)
    }
    let c = xpc_connection_create_from_endpoint(endpoint as xpc_endpoint_t)
    xpc_connection_set_event_handler(c) { e in if xpc_get_type(e) == XPC_TYPE_ERROR { log("compositor connection error") } }
    xpc_connection_resume(c)
    _ = xpc_connection_send_message_with_reply_sync(c, dict(["op": str("ping")]))
    log(String(format: "lookup + connect + first ping: %.2f ms", Double(now() - t0) / 1e6))

    // Round-trip cost of a bare message.
    var samples: [Double] = []
    for _ in 0..<500 {
        let s = now(); _ = xpc_connection_send_message_with_reply_sync(c, dict(["op": str("ping")])); samples.append(Double(now() - s) / 1e3)
    }
    samples.sort()
    log(String(format: "ping round trip: p50 %.0f µs, p99 %.0f µs", samples[250], samples[495]))

    // Register a retina-tile-sized swapchain once.
    let (w, h) = (2216, 1308)
    var surfaces: [IOSurfaceRef] = []
    for i in 0..<3 {
        let s = makeSurface(w, h); surfaces.append(s)
        let t = now()
        let r = xpc_connection_send_message_with_reply_sync(c, dict([
            "op": str("buffer.create_iosurface"), "id": xpc_uint64_create(UInt64(i)), "surface": IOSurfaceCreateXPCObject(s)]))
        let same = xpc_dictionary_get_uint64(r, "global_id") == UInt64(IOSurfaceGetID(s))
        log(String(format: "register buffer %d (%dx%d): %.0f µs, same IOSurface on both sides: %@", i, w, h, Double(now() - t) / 1e3, same ? "yes" : "NO"))
    }

    // Per frame: draw into a buffer, commit by id, compositor reads the memory back.
    var ok = 0; var commit: [Double] = []
    for f in 0..<300 {
        let s = surfaces[f % 3]
        let value = UInt32(0xFF00_0000) | UInt32(f)
        IOSurfaceLock(s, [], nil); IOSurfaceGetBaseAddress(s).storeBytes(of: value, as: UInt32.self); IOSurfaceUnlock(s, [], nil)
        let t = now()
        let r = xpc_connection_send_message_with_reply_sync(c, dict([
            "op": str("surface.commit"), "buffer": xpc_uint64_create(UInt64(f % 3))]))
        commit.append(Double(now() - t) / 1e3)
        if xpc_dictionary_get_uint64(r, "pixel") == UInt64(value) { ok += 1 }
    }
    commit.sort()
    log(String(format: "300 commits: compositor saw the client's pixel %d/300 times; p50 %.0f µs, p99 %.0f µs", ok, commit[150], commit[297]))
}

switch CommandLine.arguments.dropFirst().first {
case "broker": runBroker()
case "compositor": runCompositor()
case "client": runClient()
default: print("usage: spike broker|compositor|client"); exit(2)
}
