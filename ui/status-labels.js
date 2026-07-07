/* Browser bundle — keep in sync with status-labels.mjs */
(function (global) {
  "use strict";

  var STATE_ENUM = [
    "None",
    "Submitted",
    "Assigned",
    "InAudit",
    "AwaitingWindow",
    "Audited",
    "InBlock",
    "Claimed",
    "Exploited",
    "Invalidated",
  ];

  var STATUS = {
    None: { label: "None", gloss: "", pill: ["None", "#21262d", "#adb6c0"] },
    Submitted: {
      label: "In review",
      gloss: "Submitted — waiting for an auditor",
      pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    },
    Assigned: {
      label: "In review",
      gloss: "Assigned — protocol decides on the auditor",
      pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    },
    InAudit: {
      label: "In review",
      gloss: "Auditor is running tools on the contract",
      pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    },
    AwaitingWindow: {
      label: "Passed — window open",
      gloss: "Passed; challenge window open — can still be disputed",
      pill: ["Passed — window open (can be challenged)", "#10243a", "#6cb0f5"],
    },
    Audited: {
      label: "Settled",
      gloss: "Audited — confirm pending or recently closed",
      pill: ["Settled ✓ (paid)", "#10311b", "#3fb950"],
    },
    InBlock: {
      label: "Settled",
      gloss: "Settled and paid — positive block",
      pill: ["Settled ✓ (paid)", "#10311b", "#3fb950"],
    },
    Claimed: {
      label: "Disputed",
      gloss: "Bug reported — independent re-check in progress",
      pill: ["Disputed (being re-checked)", "#33270f", "#e3b341"],
    },
    Exploited: {
      label: "Bug confirmed",
      gloss: "Bug confirmed — original pass was wrong",
      pill: ["Bug confirmed ✗ (original audit was wrong)", "#3a1d1d", "#f85149"],
    },
    Invalidated: {
      label: "Void",
      gloss: "Spec invalidated — audit voided, bounty returned",
      pill: ["Void (spec invalidated)", "#21262d", "#adb6c0"],
    },
  };

  function resolve(state) {
    if (typeof state === "number") return STATE_ENUM[state] || null;
    return state == null ? null : String(state);
  }

  function stateName(index) {
    return STATE_ENUM[index] || null;
  }

  function labelFor(state) {
    var name = resolve(state);
    return (name && STATUS[name] && STATUS[name].label) || name || "—";
  }

  function glossFor(state) {
    var name = resolve(state);
    return (name && STATUS[name] && STATUS[name].gloss) || "";
  }

  function detailState(state) {
    var label = labelFor(state);
    var gloss = glossFor(state);
    return gloss ? label + " — " + gloss : label;
  }

  function humanPill(state) {
    var name = resolve(state);
    if (name && STATUS[name] && STATUS[name].pill) return STATUS[name].pill;
    return [labelFor(state), "#21262d", "#adb6c0"];
  }

  function humanPillHtml(state) {
    var h = humanPill(state);
    return (
      '<span class="pill" style="background:' +
      h[1] +
      ";color:" +
      h[2] +
      ";border-left-color:" +
      h[2] +
      '">' +
      h[0] +
      "</span>"
    );
  }

  function labelByIndex(index) {
    return labelFor(stateName(index));
  }

  global.MembraneStatus = {
    STATE_ENUM: STATE_ENUM,
    STATUS: STATUS,
    stateName: stateName,
    labelFor: labelFor,
    glossFor: glossFor,
    detailState: detailState,
    humanPill: humanPill,
    humanPillHtml: humanPillHtml,
    labelByIndex: labelByIndex,
  };
})(typeof window !== "undefined" ? window : globalThis);
