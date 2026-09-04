// Polyfills for browser APIs that only exist in a *secure context*
// (HTTPS, or http://localhost).
//
// OpenJarvis is an on-device assistant that is very often served over plain
// HTTP on a LAN hostname (e.g. http://share.box:3700). In that context several
// Web APIs the SPA uses are missing:
//
//   * crypto.randomUUID        -> frontend/src/lib/store.ts calls it at store
//                                 init, so the WHOLE APP crashes on load with
//                                 "TypeError: crypto.randomUUID is not a function"
//   * navigator.clipboard      -> undefined, so the "copy" buttons throw on click
//
// crypto.getRandomValues and document.execCommand('copy') are both available in
// insecure contexts, so build the missing APIs on top of them. Loaded as a
// classic <script> in <head> so it runs before the app bundle.
//
// (crypto.subtle is also secure-context-only and used by lib/analytics.ts, but
// that call is try/catch'd and analytics is opt-in + off by default, so it
// degrades silently and is intentionally not polyfilled here.)
(function () {
  "use strict";

  // --- crypto.randomUUID (RFC 4122 v4) ------------------------------------
  var c = self.crypto;
  if (
    c &&
    typeof c.getRandomValues === "function" &&
    typeof c.randomUUID !== "function"
  ) {
    c.randomUUID = function randomUUID() {
      var b = c.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40; // version 4
      b[8] = (b[8] & 0x3f) | 0x80; // variant 10
      var s = "";
      for (var i = 0; i < 16; i++) {
        s += (b[i] + 0x100).toString(16).slice(1);
        if (i === 3 || i === 5 || i === 7 || i === 9) s += "-";
      }
      return s;
    };
  }

  // --- navigator.clipboard.writeText ------------------------------------
  var nav = self.navigator;
  if (nav && (!nav.clipboard || typeof nav.clipboard.writeText !== "function")) {
    var writeText = function (text) {
      return new Promise(function (resolve, reject) {
        try {
          var ta = document.createElement("textarea");
          ta.value = String(text);
          ta.setAttribute("readonly", "");
          ta.style.position = "fixed";
          ta.style.top = "-9999px";
          document.body.appendChild(ta);
          ta.select();
          var ok = document.execCommand("copy");
          document.body.removeChild(ta);
          ok ? resolve() : reject(new Error("copy command was unsuccessful"));
        } catch (err) {
          reject(err);
        }
      });
    };
    if (nav.clipboard) {
      nav.clipboard.writeText = writeText;
    } else {
      try {
        Object.defineProperty(nav, "clipboard", {
          value: { writeText: writeText },
          configurable: true,
        });
      } catch (_e) {
        /* some engines forbid redefining navigator.clipboard; nothing else to do */
      }
    }
  }
})();
