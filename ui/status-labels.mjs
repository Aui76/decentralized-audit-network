/** Audit state → human label + gloss (single map for explorer, manage, indexer). */

export const STATE_ENUM = [
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

/** @type {Record<string, { label: string, gloss: string, pill: [string, string, string], outcome?: string }>} */
export const STATUS = {
  None: {
    label: "None",
    gloss: "",
    pill: ["None", "#21262d", "#adb6c0"],
  },
  Submitted: {
    label: "In review",
    gloss: "Submitted — waiting for an auditor",
    pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    outcome: "In review · submitted",
  },
  Assigned: {
    label: "In review",
    gloss: "Assigned — protocol decides on the auditor",
    pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    outcome: "In review · assigned",
  },
  InAudit: {
    label: "In review",
    gloss: "Auditor is running tools on the contract",
    pill: ["In review (being checked)", "#21262d", "#adb6c0"],
    outcome: "In review · auditor working",
  },
  AwaitingWindow: {
    label: "Passed — window open",
    gloss: "Passed; challenge window open — can still be disputed",
    pill: ["Passed — window open (can be challenged)", "#10243a", "#6cb0f5"],
    outcome: "Passed — window open",
  },
  Audited: {
    label: "Settled",
    gloss: "Audited — confirm pending or recently closed",
    pill: ["Settled ✓ (paid)", "#10311b", "#3fb950"],
    outcome: "Settled",
  },
  InBlock: {
    label: "Settled",
    gloss: "Settled and paid — positive block",
    pill: ["Settled ✓ (paid)", "#10311b", "#3fb950"],
    outcome: "Settled · paid",
  },
  Claimed: {
    label: "Disputed",
    gloss: "Bug reported — independent re-check in progress",
    pill: ["Disputed (being re-checked)", "#33270f", "#e3b341"],
    outcome: "Disputed · open",
  },
  Exploited: {
    label: "Bug confirmed",
    gloss: "Bug confirmed — original pass was wrong",
    pill: ["Bug confirmed ✗ (original audit was wrong)", "#3a1d1d", "#f85149"],
    outcome: "Bug confirmed",
  },
  Invalidated: {
    label: "Void",
    gloss: "Spec invalidated — audit voided, bounty returned",
    pill: ["Void (spec invalidated)", "#21262d", "#adb6c0"],
    outcome: "Void",
  },
};

function resolve(state) {
  if (typeof state === "number") return STATE_ENUM[state] ?? null;
  return state == null ? null : String(state);
}

export function stateName(index) {
  return STATE_ENUM[index] ?? null;
}

export function labelFor(state) {
  const name = resolve(state);
  return (name && STATUS[name]?.label) || name || "—";
}

export function glossFor(state) {
  const name = resolve(state);
  return (name && STATUS[name]?.gloss) || "";
}

/** Human line for detail rows — label plus gloss, no raw enum name. */
export function detailState(state) {
  const label = labelFor(state);
  const gloss = glossFor(state);
  return gloss ? `${label} — ${gloss}` : label;
}

export function humanPill(state) {
  const name = resolve(state);
  if (name && STATUS[name]?.pill) return STATUS[name].pill;
  return [labelFor(state), "#21262d", "#adb6c0"];
}

export function humanPillHtml(state) {
  const h = humanPill(state);
  return `<span class="pill" style="background:${h[1]};color:${h[2]};border-left-color:${h[2]}">${h[0]}</span>`;
}

export function labelByIndex(index) {
  return labelFor(stateName(index));
}

/** Indexer / Bob-style one-line outcome. */
export function outcomeOf(state) {
  const name = resolve(state);
  return (name && STATUS[name]?.outcome) || labelFor(state);
}
