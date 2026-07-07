// In-tab audit verifier — the "Reproduce it now" button's engine.
// Thin browser face over verify-core.mjs (ONE TRUTH for the encoding; see verify.mjs for the CLI).
// Read-only: eth_getCode + eth_call, no wallet, sends nothing.
import { reproduce, selfTestRows, PUBLISHED } from "./verify-core.mjs";

window.MembraneVerify = { reproduce, selfTestRows, PUBLISHED };
document.dispatchEvent(new CustomEvent("membrane-verify-ready"));
