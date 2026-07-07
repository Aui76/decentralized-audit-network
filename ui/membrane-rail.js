/**
 * Mount Your links on non-docs pages (layout-docs full panel, layout-tool collapsed rail).
 * Skip when docs-rail.js is present (docs reading pages handle their own third rail).
 */
(function () {
  if (document.querySelector('script[src*="docs-rail.js"]') || !window.MembraneYourLinks) return;
  // toolbelt hosts all personal tools now — no rail mounts needed
  if (document.getElementById("toolbelt")) return;

  const docsLayout = document.querySelector(".layout-docs");
  const toolLayout = document.querySelector(".layout-tool");

  if (docsLayout) {
    let rail = document.getElementById("docRail");
    if (!rail) rail = docsLayout.querySelector("aside");
    if (!rail) {
      rail = document.createElement("aside");
      docsLayout.appendChild(rail);
    }
    rail.id = "docRail";
    rail.setAttribute("aria-label", "Your links");
    const pageAside = rail.querySelector(".doc-aside-page");
    const pageAsideHtml = pageAside ? pageAside.outerHTML : "";
    MembraneYourLinks.mount(rail, { mode: "collapsed" });
    if (pageAsideHtml) rail.insertAdjacentHTML("afterbegin", pageAsideHtml);
    docsLayout.classList.add("layout-docs--rail");
    return;
  }

  if (!toolLayout) return;

  let rail = document.getElementById("toolRail");
  if (!rail) {
    rail = document.createElement("aside");
    rail.id = "toolRail";
    toolLayout.appendChild(rail);
  }
  rail.setAttribute("aria-label", "Your links");
  MembraneYourLinks.mount(rail, { mode: "collapsed" });
})();
