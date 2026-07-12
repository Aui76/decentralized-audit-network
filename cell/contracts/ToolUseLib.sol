// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {CellStorage, CellTypeDefs} from "./CellStorage.sol";

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
