/// JavaScript functions shared by every browser engine for credential capture and fill.
/// Arguments always travel separately through the engine's structured-value API.
enum CredentialJavaScript {
    static let capture = #"""
    function (args) {
        const token = args.credentialToken;
        const topOrigin = document.location.origin;
        const isVisible = element => {
            if (!element || element.getClientRects().length === 0) return false;
            if (typeof element.checkVisibility === "function" &&
                !element.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
            const style = element.ownerDocument.defaultView.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
            const rect = element.getBoundingClientRect();
            const view = element.ownerDocument.defaultView;
            return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 &&
                   rect.top < view.innerHeight && rect.left < view.innerWidth;
        };
        const credentialKind = input => {
            const type = input.type.toLowerCase();
            if (type === "password") return "password";
            if (type === "email") return "username";
            if (type !== "text") return "ineligible";
            const autocomplete = (input.autocomplete || "").toLowerCase().split(/\s+/);
            if (autocomplete.includes("username") || autocomplete.includes("email")) return "username";
            const hint = `${input.id || ""} ${input.name || ""}`;
            return /(^|[^a-z0-9])(user(name|id)?|login(id)?|e-?mail(address)?)([^a-z0-9]|$)/i.test(hint)
                ? "username" : "ineligible";
        };
        let doc = document;
        while (true) {
            const active = doc.activeElement;
            if (!active) return {ok: false, code: "no_input"};
            const tag = active.tagName ? active.tagName.toLowerCase() : "";
            if (tag !== "iframe" && tag !== "frame") break;
            if (!isVisible(active)) return {ok: false, code: "ineligible"};
            let child;
            try {
                child = active.contentDocument;
                if (!child || child.location.origin !== topOrigin) {
                    return {ok: false, code: "cross_origin"};
                }
            } catch (_) {
                return {ok: false, code: "cross_origin"};
            }
            doc = child;
        }
        const input = doc.activeElement;
        const Input = doc.defaultView && doc.defaultView.HTMLInputElement;
        if (!Input || !(input instanceof Input)) return {ok: false, code: "no_input"};
        const kind = credentialKind(input);
        const ariaDisabled = (input.getAttribute("aria-disabled") || "").toLowerCase() === "true";
        if (kind === "ineligible" || input.matches(":disabled") || ariaDisabled || input.readOnly || !isVisible(input)) {
            return {ok: false, code: "ineligible"};
        }
        try {
            Object.defineProperty(input, token, {value: true, configurable: true});
        } catch (_) {
            return {ok: false, code: "mark_failed"};
        }
        return {ok: true, origin: topOrigin, host: document.location.hostname, kind};
    }
    """#

    static let fill = #"""
    function (args) {
        const token = args.credentialToken;
        const expectedOrigin = args.expectedOrigin;
        const expectedKind = args.expectedKind;
        const credentialValue = args.credentialValue;
        if (document.location.origin !== expectedOrigin) return {ok: false, code: "origin_changed"};
        const isVisible = element => {
            if (!element || element.getClientRects().length === 0) return false;
            if (typeof element.checkVisibility === "function" &&
                !element.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
            const style = element.ownerDocument.defaultView.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
            const rect = element.getBoundingClientRect();
            const view = element.ownerDocument.defaultView;
            return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 &&
                   rect.top < view.innerHeight && rect.left < view.innerWidth;
        };
        const credentialKind = input => {
            const type = input.type.toLowerCase();
            if (type === "password") return "password";
            if (type === "email") return "username";
            if (type !== "text") return "ineligible";
            const autocomplete = (input.autocomplete || "").toLowerCase().split(/\s+/);
            if (autocomplete.includes("username") || autocomplete.includes("email")) return "username";
            const hint = `${input.id || ""} ${input.name || ""}`;
            return /(^|[^a-z0-9])(user(name|id)?|login(id)?|e-?mail(address)?)([^a-z0-9]|$)/i.test(hint)
                ? "username" : "ineligible";
        };
        let doc = document;
        while (true) {
            const active = doc.activeElement;
            if (!active) return {ok: false, code: "target_changed"};
            const tag = active.tagName ? active.tagName.toLowerCase() : "";
            if (tag !== "iframe" && tag !== "frame") break;
            if (!isVisible(active)) return {ok: false, code: "target_changed"};
            let child;
            try {
                child = active.contentDocument;
                if (!child || child.location.origin !== expectedOrigin) {
                    return {ok: false, code: "cross_origin"};
                }
            } catch (_) {
                return {ok: false, code: "cross_origin"};
            }
            doc = child;
        }
        const input = doc.activeElement;
        const Input = doc.defaultView && doc.defaultView.HTMLInputElement;
        if (!Input || !(input instanceof Input) || input[token] !== true) {
            return {ok: false, code: "target_changed"};
        }
        const kind = credentialKind(input);
        const ariaDisabled = (input.getAttribute("aria-disabled") || "").toLowerCase() === "true";
        if (kind !== expectedKind || input.matches(":disabled") || ariaDisabled || input.readOnly || !isVisible(input)) {
            return {ok: false, code: "target_changed"};
        }
        delete input[token];
        const descriptor = Object.getOwnPropertyDescriptor(Input.prototype, "value");
        const setter = descriptor && descriptor.set;
        if (typeof setter !== "function") return {ok: false, code: "no_setter"};
        setter.call(input, credentialValue);
        input.dispatchEvent(new doc.defaultView.Event("input", {bubbles: true, composed: true}));
        input.dispatchEvent(new doc.defaultView.Event("change", {bubbles: true, composed: true}));
        return {ok: true};
    }
    """#
}
