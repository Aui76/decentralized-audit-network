// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {CellStorage, CellTypeDefs} from "./CellStorage.sol";
import "./CellParamIds.sol";

interface IIssuanceToolUse {
    function nextPositiveBlockReward() external view returns (uint256);
    function mintToolCanonization(address to) external returns (uint256);
    function isEstablishedProtocol(address p) external view returns (bool);
}

/// @title ToolUseLib — tool-use recording + canonization trigger (linked external library, delegatecall).
/// @notice G-19 fix, option B (2026-07-08, DEC-22 docket): extracted from `CellLogicLib._recordOneToolUse`
///         so the re-keyed trigger costs ZERO CellLogicLib bytes (475 B margin there — forbidden zone;
///         SubmitAuditLib precedent). Shares AuditCell storage via delegatecall (`CellStorage.layout()`).
///
///         THE RE-KEY: canonization no longer fires on RAW `successfulUses` (farmable: 7 wash audits ->
///         full block reward to the proposer). It fires when the tool has been used by `canonicalThreshold`
///         DISTINCT ESTABLISHED protocols — the §2.5 credibility signal reused strictly as a GATE
///         (punish/pay rule, lessons #10: it pays nothing new here). The prize stays one bounded one-shot;
///         the COST scales with the §2.5 quadratic mesh, so farm margin degrades with scale.
///
///         Preserved byte-for-byte from the original block: raw successfulUses/failedUses telemetry,
///         blockSize divisor, canonReward>0 guard, entropy fold into `latestBlockHash`, event order.
///         Establishment is read as-of the moment of recording — within a confirm it may lag that
///         confirm's own credibility update by one audit (monotone; lag only DELAYS counting).
library ToolUseLib {
    // Topic-identical re-declarations of the CellLogicLib events (delegatecall -> logs surface as
    // AuditCell logs, same topics as before the extraction).
    event ToolCanonized(bytes32 indexed toolId);
    event ToolCanonizationRewarded(
        bytes32 indexed toolId, address indexed proposer, uint256 reward, bytes32 blockHash
    );
    event ToolUseRecorded(bytes32 indexed toolId, uint256 indexed auditId, bool successful);

    error ToolNotRegistered();
    error SpecToolNotForVerdict();
    error ToolAlreadyCanonical();
    error ParamLockedErr();

    /// @notice Door 16's body, moved here 2026-08-23 (G-31, operator's proposal; VD-36).
    ///
    /// WHY IT MOVED, and it is not a contortion. `canonical` has TWO writers: the organic one directly
    /// below (`recordOneToolUseExt` — a tool earns canonization from distinct established protocols) and
    /// this admin one, which shadows it. They belonged in one place and were in two; the admin arm now
    /// sits beside the path it shadows. One concept, one home.
    ///
    /// WHAT IT BOUGHT, measured. AuditCell had EIGHT bytes of EIP-170 headroom, and door 16's full
    /// verdict (LOCK + BOUND) needed 23 more than that — the lock was measured OUT on 2026-08-23 at
    /// 24,591 B, margin -15, and only the monotone guard shipped. This library is a LINKED EXTERNAL
    /// library (delegatecall, its own budget: 1,764 B used, 22,812 free), so a body here costs AuditCell
    /// nothing and its forwarder REPAYS margin. The selector is unchanged, so G-b's surface conservation
    /// holds by construction rather than by re-baselining.
    ///
    /// THE THREE RULES, and each is exactly one of G-31's halves plus the bootstrap that must survive:
    ///
    ///   1. MONOTONE. `canonical` may be set, never cleared. Clearing it on an already-canonical tool
    ///      RE-ARMED the mint: the organic path gates on `if (!t.canonical)` plus a distinct-use counter
    ///      that is incremented only and never reset (:49 below), and `registerTool` cannot re-run
    ///      (`!exists`), so the next successful use minted to the proposer AGAIN — one mint per clear, at
    ///      will. This kills it BY CONSTRUCTION, unarmed and always.
    ///
    ///   2. LOCKABLE (param id 13). Once `lockParam(13)` is armed the canonical arm is dead forever, which
    ///      closes G-31's DENIAL half — admin setting `canonical` early to rob a proposer of a mint they
    ///      were organically earning. No new selector and no new setter: `lockParam(uint8)` already exists.
    ///      VD-26 A1 says locks ship UNARMED because arming forbids the measurements that tune a knob —
    ///      but `canonical` is NOT a knob, it is a BOOTSTRAP SEED with no legitimate admin use after
    ///      PhaseF seeds the gap-evaluator. Hence the doctrine this door earned:
    ///      **measurement knobs ship unarmed; bootstrap seeds arm the moment their bootstrap is done.**
    ///      The arm step therefore rides the deploy script, immediately after `PhaseFSetup`.
    ///
    ///   3. THE EVALUATOR ARM STAYS LIVE. The lock gates only the `canonical` TRANSITION, never the
    ///      function, so `isInvariantEvaluator` remains tunable for calibration after arming. A
    ///      whole-function lock would have been one line shorter and would have silently killed that.
    ///
    /// Idempotent by construction: a re-run of `PhaseFSetup.s.sol`:33 passes `canonical=true` on a tool
    /// that is already canonical, so `canonical != t.canonical` is false and NOTHING is checked. The
    /// deploy script can be re-run after arming. It bites only if PhaseF seeds a NEW tool post-arm —
    /// which is why the arm step goes after the LAST legitimate seeding, named in the script, not
    /// remembered.
    function setToolWitnessFlagsExt(bytes32 toolId, bool isEvaluator, bool canonical) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Tool storage t = L.tools[toolId];
        if (!t.exists) revert ToolNotRegistered();
        if (t.isSpecValidationTool) revert SpecToolNotForVerdict();
        if (canonical != t.canonical) {
            if (t.canonical) revert ToolAlreadyCanonical(); // (1) monotone — never cleared
            if ((L.paramLocked & (uint256(1) << CellParamIds.TOOL_WITNESS_FLAGS)) != 0) {
                revert ParamLockedErr(); // (2) once armed — never set either
            }
        }
        t.isInvariantEvaluator = isEvaluator; // (3) calibration arm, never locked
        t.canonical = canonical;
    }

    function recordOneToolUseExt(bytes32 toolId, uint256 auditId, bool successful) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Tool storage t = L.tools[toolId];
        if (!t.exists) return;
        if (successful) {
            t.successfulUses += 1; // raw telemetry unchanged (views/getter shape preserved)
            if (!t.canonical) {
                address p = L.audits[auditId].protocol;
                if (
                    p != address(0) && !L.toolProtocolCounted[toolId][p] && L.issuanceModule != address(0)
                        && IIssuanceToolUse(L.issuanceModule).isEstablishedProtocol(p)
                ) {
                    L.toolProtocolCounted[toolId][p] = true;
                    L.toolDistinctEstablishedUses[toolId] += 1;
                }
                if (L.toolDistinctEstablishedUses[toolId] >= L.canonicalThreshold) {
                    t.canonical = true;
                    uint256 blockSize = L.currentBlockSize > 0 ? L.currentBlockSize : 1;
                    uint256 canonReward = L.issuanceModule != address(0)
                        ? IIssuanceToolUse(L.issuanceModule).nextPositiveBlockReward() / blockSize
                        : 0;
                    if (canonReward > 0 && t.proposer != address(0) && L.issuanceModule != address(0)) {
                        uint256 mintedCanon = IIssuanceToolUse(L.issuanceModule).mintToolCanonization(t.proposer);
                        if (mintedCanon > 0) {
                            L.latestBlockHash = keccak256(
                                abi.encode(
                                    L.latestBlockHash, "CAN", toolId, t.proposer, mintedCanon, block.timestamp
                                )
                            );
                            emit ToolCanonizationRewarded(toolId, t.proposer, mintedCanon, L.latestBlockHash);
                        }
                    }
                    emit ToolCanonized(toolId);
                }
            }
        } else {
            t.failedUses += 1;
        }
        emit ToolUseRecorded(toolId, auditId, successful);
    }
}
