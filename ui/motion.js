/**
 * Membrane motion — hub stagger, doc-rail scroll cue.
 * Cold-load vs nav-session class is set inline in <head> (see md-lib pageShell).
 */
(function () {
  "use strict";

  const root = document.documentElement;
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (!root.classList.contains("cold-load") && !root.classList.contains("nav-session")) {
    try {
      const k = "membrane_nav_session";
      const seen = sessionStorage.getItem(k);
      root.classList.add(seen ? "nav-session" : "cold-load");
      if (!seen) sessionStorage.setItem(k, "1");
    } catch {
      root.classList.add("nav-session");
    }
  }

  document.querySelectorAll(".motion-stagger").forEach((el) => {
    if (reduced) return;
    [...el.children].forEach((child, i) => {
      child.style.setProperty("--motion-i", String(i));
    });
  });

  const rail = document.getElementById("docRail");
  if (rail && !reduced) {
    const onScroll = () => {
      root.classList.toggle("doc-rail-scrolled", window.scrollY > 64);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }
})();
