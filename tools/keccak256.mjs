// keccak256.mjs — Keccak-256 (the Ethereum one), vendored, zero dependencies.
//
// WHY VENDORED. dan-check's whole job is refusing, and a refusal tool that drags in a
// dependency tree to compute one hash has a supply chain — the exact shape FC-14 exists to
// stand against (the Lisbon lesson was NpmGuard standing in the path of the action; shipping
// an npm-install-shaped hole in the thing that guards npm installs would be absurd).
// Node has no built-in Keccak: `crypto.createHash('sha3-256')` is NIST SHA3, which uses a
// DIFFERENT PADDING BYTE (0x06 vs 0x01) and returns a different digest for the same input.
// That substitution is silent — it produces a plausible 32-byte hash that never matches a
// codehash — so it is exactly the kind of wrong answer this repo keeps paying for.
//
// VERIFICATION. This is asserted against published Keccak-256 vectors in
// dan-check.test.mjs before any dan-check test runs. If those fail, nothing else is trusted.
// Correctness here is not a matter of reading the code and nodding: it is a matter of the
// empty-string vector being c5d24601… and nothing else.

const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

// r[x][y] — rotation offsets for the rho step.
const R = [
  [0n, 36n, 3n, 41n, 18n],
  [1n, 44n, 10n, 45n, 2n],
  [62n, 6n, 43n, 15n, 61n],
  [28n, 55n, 25n, 21n, 56n],
  [27n, 20n, 39n, 8n, 14n],
];

const M = (1n << 64n) - 1n;
const rotl = (v, n) => n === 0n ? v : (((v << n) | (v >> (64n - n))) & M);

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    // theta
    const C = [];
    for (let x = 0; x < 5; x++) C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1n);
      for (let y = 0; y < 5; y++) A[x][y] ^= D;
    }
    // rho + pi
    const B = [[], [], [], [], []];
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        B[y][(2 * x + 3 * y) % 5] = rotl(A[x][y], R[x][y]);
      }
    }
    // chi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        A[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y] & M) & B[(x + 2) % 5][y]);
      }
    }
    // iota
    A[0][0] ^= RC[round];
  }
  return A;
}

/** Keccak-256 over a byte array. Returns a lowercase 0x-prefixed hex string. */
export function keccak256Bytes(bytes) {
  const RATE = 136;                                   // 1088 bits
  const A = [[], [], [], [], []];
  for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x][y] = 0n;

  // pad10*1 with Keccak's 0x01 domain byte (NOT SHA3's 0x06 — see header)
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / RATE) * RATE);
  padded.set(bytes);
  padded[bytes.length] = 0x01;
  padded[padded.length - 1] |= 0x80;

  for (let off = 0; off < padded.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      A[i % 5][(i / 5) | 0] ^= lane;
    }
    keccakF(A);
  }

  let out = "";
  for (let i = 0; i < 4; i++) {                       // 4 lanes = 32 bytes
    let lane = A[i % 5][(i / 5) | 0];
    for (let b = 0; b < 8; b++) {
      out += ((lane >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, "0");
    }
  }
  return "0x" + out;
}

/** Keccak-256 over a 0x-prefixed hex string (e.g. contract runtime code). */
export function keccak256Hex(hex) {
  const h = (hex || "").replace(/^0x/, "");
  if (h.length % 2) throw new Error("odd-length hex");
  const b = new Uint8Array(h.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return keccak256Bytes(b);
}

/** Keccak-256 over a UTF-8 string — used for ABI selectors. */
export function keccak256Utf8(s) {
  return keccak256Bytes(new TextEncoder().encode(s));
}

/** First 4 bytes of keccak256(signature), the ABI function selector. */
export function selector(sig) {
  return keccak256Utf8(sig).slice(0, 10);
}
