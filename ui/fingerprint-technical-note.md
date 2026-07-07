# Fingerprint Technical Note

**Audience:** reader

**Question this doc answers:** **How** does a registered tool run become the on-chain `resultRoot` the cell settles on?

**Story:** [RealDeal ch. 7 — The fingerprint](../book/chapters/07-the-fingerprint.md)


| Doc                                                  | Role                                                     |
| ---------------------------------------------------- | -------------------------------------------------------- |
| This leaf                                            | Encoding standard (`AUDIT_RESULT_V1`) — formula + fields |
| `[guides/whitepaper.md](guides/whitepaper.md)`       | System overview · why the fingerprint matters            |
| `[7-contract/reference.md](7-contract/reference.md)` | On-chain getters that consume `resultRoot`               |


**Encoding standard `AUDIT_RESULT_V1`:** how a tool run becomes the `resultRoot` the contract settles on.

Same registered tool, same pinned artifact, same declared spec binding → same `resultRoot` under this standard. Pass or fail; nothing between. Every verdict and settlement path in the network consumes this commitment.

Canonical spec: `AUDIT_RESULT_V1` in the build repo (status: **LOCKED**). This document is the readable account.

On-chain encoding: `[../../cell/contracts/tools/AuditResultV1.sol](../../cell/contracts/tools/AuditResultV1.sol)`

*System context:* `[guides/whitepaper.md](guides/whitepaper.md)` *·* `[guides/whitepaper.md#at-a-glance](guides/whitepaper.md#at-a-glance)`

## Invariant

Two runs with identical `(toolId, artifactHash, specHash, contextRoot)` MUST produce identical `resultRoot`. Non-conforming tools are rejected from the toolkit.

---



## Formula

```
resultRoot = keccak256(abi.encode(
    keccak256("AUDIT_RESULT_V1"),
    toolId,
    artifactHash,
    specHash,
    contextRoot,
    verdict,        // uint8: 1 = PASS, 0 = FAIL
    findingsRoot    // bytes32(0) on PASS
))
```

- Encoding: `abi.encode` (fixed-width, length-prefixed). Field order is normative.
- Version tag is inside the hash; `V2` roots cannot collide with `V1`.

---



## Field definitions



### `toolId`

```
keccak256(abi.encode(
    keccak256("AUDIT_TOOL_V1"),
    toolName,
    toolVersion,
    toolArtifactHash,
    entrypoint
))
```

Tool MUST be reproducible from this manifest. `toolArtifactHash` **(L-02, normative):** `keccak256` of the compiled tool library's **runtime bytecode** under the pinned build in `contextRoot`, with the declared `TOOL_ARTIFACT_HASH` slot set to `bytes32(0)` at compile time. Recompute in Genesis:

```bash
forge script script/tools/ComputeToolArtifactHash.s.sol:ComputeToolArtifactHash
```

The published constant in source is that zero-slot hash (embedded metadata means live probe ≠ declared — manifest + `ComputeSpecHash` are authoritative). **v1.0.0** used a label hash (`keccak256("WithdrawCreditsV1Lib@1.0.0")`) — historical only; **v1.1.0+** use content-bound hashes. Supersede via new `toolVersion`, never in-place.

### `artifactHash`

Commitment to the artifact under audit, pinned at submission.

- **EVM path (**`submitAudit`**):** codehash of deployed bytecode at `deployedAddress`.
- **Domain-agnostic path (Pillar B,** `submitArtifactAudit`**):** caller-supplied bare `bytes32` — any content-addressable artifact (build hash, model, dataset) with no on-chain deployment required.

Both paths store the same field on the audit row; tools and dispute comparison use `(artifactHash, specHash, toolId)` regardless of how O was pinned.

### `specHash`

Commitment to the declared audit specification (invariants, scope, or open-discovery terms).

### `contextRoot`

```
keccak256(abi.encode(
    keccak256("AUDIT_CONTEXT_V1"),
    solcVersion,
    evmVersion,
    optimizerRuns,
    viaIR,
    toolConfigRoot,
    seed
))
```

Commits everything else that can affect output. Randomness only via `seed` in `contextRoot`.

### `findingsRoot`

**PASS:** `bytes32(0)`.

**FAIL:** leaves = `keccak256(abi.encode(invariantId, locationCommitment, witnessCommitment))`, sorted ascending by `(invariantId, locationCommitment)`; then:

```
keccak256(abi.encode(keccak256("AUDIT_FINDINGS_V1"), sortedLeaves))
```

Sort order makes the root independent of discovery order.

---



## Determinism rules

`resultRoot` MUST NOT depend on:


| Forbidden                           | Notes                       |
| ----------------------------------- | --------------------------- |
| Wall-clock time, dates, nonces      |                             |
| Runner / auditor / claimant address |                             |
| Machine, OS, locale, network state  |                             |
| Unpinned randomness                 | Use `seed` in `contextRoot` |
| Non-canonical collection order      | Maps/sets: canonical sort   |


Floating point: avoided or normalized. Violations → non-conforming tool.

---



## Reproduction procedure

Given published `resultRoot`:

1. Resolve `toolId` → build exact tool artifact.
2. Fetch bytecode for `artifactHash`.
3. Fetch spec for `specHash`.
4. Reconstruct environment from `contextRoot`.
5. Execute tool.
6. Encode per this standard.
7. Compare to published root.

Mismatch → non-reproducing verdict → reject or slash per cell rules.

**Operational binding (current):** dispute auditor performs steps 1–7; 14-day window allows any participant to repeat and file a claim. **Optional hardening:** ZK/TEE verifier proves the same statement without trusting the runner; same encoding, added as an organ.

---



## Versioning

- `AUDIT_RESULT_V1` is frozen; edits require a new standard (`V2`, …) alongside.
- First conforming tool may be narrow; the encoding standard is permanent.
- All toolkit tools share this socket.

---

*Companion:* `[guides/whitepaper.md](guides/whitepaper.md)`
