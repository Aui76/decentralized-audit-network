/* Membrane sign hero — "What you're about to sign" (function · args · to) */
(function (global) {
  "use strict";

  const observers = new WeakMap();

  function esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function disconnect(el) {
    const io = observers.get(el);
    if (io) {
      io.disconnect();
      observers.delete(el);
    }
  }

  function bindScrollAck(el) {
    if (!el) return;
    disconnect(el);
    el.classList.add("sign-hero--unread");
    if (!("IntersectionObserver" in global)) {
      el.classList.remove("sign-hero--unread");
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting && e.intersectionRatio >= 0.55) {
            el.classList.remove("sign-hero--unread");
            disconnect(el);
          }
        });
      },
      { threshold: [0.55, 0.85] }
    );
    observers.set(el, io);
    io.observe(el);
  }

  function fill(id, spec) {
    spec = spec || {};
    const el = typeof id === "string" ? document.getElementById(id) : id;
    if (!el) return el;

    disconnect(el);

    if (!spec.fn) {
      el.className = "sign-hero sign-hero--idle";
      el.innerHTML =
        '<div class="sign-hero__head">What you\u2019re about to sign</div>' +
        '<p class="sign-hero__idle">' +
        esc(spec.idle || "Not ready yet.") +
        "</p>";
      return el;
    }

    el.className = "sign-hero";
    el.innerHTML =
      '<div class="sign-hero__head">What you\u2019re about to sign</div>' +
      '<div class="sign-hero__row"><span class="sign-hero__k">Function</span>' +
      '<span class="sign-hero__v mono">' +
      esc(spec.fn) +
      "</span></div>" +
      '<div class="sign-hero__row"><span class="sign-hero__k">Key args</span>' +
      '<span class="sign-hero__v mono">' +
      esc(spec.args || "\u2014") +
      "</span></div>" +
      '<div class="sign-hero__row"><span class="sign-hero__k">To</span>' +
      '<span class="sign-hero__v mono">' +
      esc(spec.to) +
      (spec.toLabel
        ? ' <span class="sign-hero__tag">(' + esc(spec.toLabel) + ")</span>"
        : "") +
      "</span></div>" +
      (spec.note
        ? '<p class="sign-hero__note tiny">' + spec.note + "</p>"
        : "");

    if (spec.unread !== false) bindScrollAck(el);
    else el.classList.remove("sign-hero--unread");

    return el;
  }

  function arm(id, spec) {
    return fill(id, Object.assign({}, spec, { unread: true }));
  }

  global.MembraneSignHero = { fill, arm, bindScrollAck };
})(typeof window !== "undefined" ? window : globalThis);
