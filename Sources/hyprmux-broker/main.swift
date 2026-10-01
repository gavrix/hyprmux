// hyprmux-broker: launchd owns our mach service names; this job answers them.
// Hyprmux registers its anonymous XPC endpoint here, and clients look it up.
// See docs/CLIENT_PROTOCOL.md, section 3.
import Foundation
import HyprmuxClientProtocol
import Security
import XPC

func log(_ s: String) { FileHandle.standardError.write("hyprmux-broker: \(s)\n".data(using: .utf8)!) }

/// Registered compositors by instance name. A registration lives as long as the
/// connection that made it.
var endpoints: [String: xpc_object_t] = [:]
var owners: [String: xpc_connection_t] = [:]
let queue = DispatchQueue(label: "dev.gavrix.hyprmux.broker")

/// The requirement a registering peer must meet: Hyprmux's bundle identifier,
/// signed the way this broker is signed. An ad-hoc signature has no certificate to
/// compare, so ad-hoc builds only check the identifier.
func registrarRequirement() -> String {
    let app = "identifier \"dev.gavrix.hyprmux\""
    var me: SecCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return app }
    var staticMe: SecStaticCode?
    guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return app }
    var dr: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticMe, [], &dr) == errSecSuccess, let dr else { return app }
    var text: CFString?
    guard SecRequirementCopyString(dr, [], &text) == errSecSuccess, let text = text as String? else { return app }
    // A certificate-based designated requirement starts with our own identifier:
    // `identifier "hyprmux-broker" and anchor apple generic and ...`. Swap in the app's.
    guard text.hasPrefix("identifier \""),
          let close = text.dropFirst("identifier \"".count).firstIndex(of: "\"") else { return app }
    return app + String(text[text.index(after: close)...])
}

func reply(to message: xpc_object_t, _ fields: [String: Any], on peer: xpc_connection_t) {
    guard let r = xpc_dictionary_create_reply(message) else { return }
    for (k, v) in fields { xpcSet(r, k, v) }
    xpc_connection_send_message(peer, r)
}

func listen(_ name: String, requirement: String?, handler: @escaping (xpc_connection_t, xpc_object_t) -> Void) -> xpc_connection_t {
    let listener = xpc_connection_create_mach_service(name, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { event in
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        let peer = event as xpc_connection_t
        if let requirement {
            let rc = xpc_connection_set_peer_code_signing_requirement(peer, requirement)
            if rc != 0 { log("bad requirement (\(rc)): \(requirement)"); xpc_connection_cancel(peer); return }
        }
        xpc_connection_set_target_queue(peer, queue)
        xpc_connection_set_event_handler(peer) { message in
            if xpc_get_type(message) == XPC_TYPE_ERROR {
                if #available(macOS 15, *), message === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT {
                    log("rejected pid \(xpc_connection_get_pid(peer)) on \(name): code signature doesn't match")
                }
                // A compositor that goes away takes its registration with it.
                for (instance, owner) in owners where owner === peer {
                    owners[instance] = nil
                    endpoints[instance] = nil
                    log("instance '\(instance)' went away")
                }
                return
            }
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            handler(peer, message)
        }
        xpc_connection_resume(peer)
    }
    xpc_connection_resume(listener)
    return listener
}

let requirement = registrarRequirement()
log("registrar requirement: \(requirement)")

let registrar = listen(HMProtocol.registrarService, requirement: requirement) { peer, message in
    guard message.op == HMOp.register, let endpoint = message.value("endpoint"),
          xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT else {
        reply(to: message, ["status": "bad_request"], on: peer); return
    }
    let instance = message.string("instance") ?? HMProtocol.defaultInstance
    if let old = owners[instance], old !== peer { log("instance '\(instance)' replaced") }
    endpoints[instance] = endpoint
    owners[instance] = peer
    log("instance '\(instance)' registered by pid \(xpc_connection_get_pid(peer))")
    reply(to: message, ["status": "ok"], on: peer)
}

let lookup = listen(HMProtocol.lookupService, requirement: nil) { peer, message in
    guard message.op == HMOp.lookup else { reply(to: message, ["status": "bad_request"], on: peer); return }
    let instance = message.string("instance") ?? HMProtocol.defaultInstance
    if let endpoint = endpoints[instance] {
        reply(to: message, ["status": "ok", "endpoint": endpoint], on: peer)
    } else {
        reply(to: message, ["status": "not_running"], on: peer)
    }
}

withExtendedLifetime((registrar, lookup)) { dispatchMain() }
