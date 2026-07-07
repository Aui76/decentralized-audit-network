// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./CellStorage.sol";
import "./CellLogicLib.sol";

/// @dev Audit creation paths extracted from AuditCell for EIP-170 headroom (pre-freeze).
/// @notice Stateless delegatecall library — reads/writes via `CellStorage.layout()` only.
library SubmitAuditLib {
    error ArtifactHashMismatch();
    error ArtifactHashRequired();
    error BountyExceedsCap();
    error BountyRequired();
    error DeployedAddressRequired();
    error FixAuditAlreadyOpen();
    error GenesisAuditOpen();
    error GenesisNotPending();
    error InvalidLinkedAuditId();
    error LinkedClaimResolved();
    error LinkedNotClaimed();
    error NoAudit();
    error NoClaimOnLinked();
    error NoContractAtAddress();
    error NotSpecValidationTool();
    error SpecToolNotRegistered();
    error SpecToolRequired();
    error ZeroSpecHash();

    function _specRunDigest(bytes32 specHash, bytes32 specToolId, bool pass, bytes32 errorsRoot)
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "AUDIT_SPEC_RUN_V1",
                specHash,
                specToolId,
                pass ? bytes1(0x01) : bytes1(0x00),
                errorsRoot
            )
        );
    }

    function _requireValidSpecAtSubmit(
        CellStorage.Layout storage L,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot
    ) private view returns (bytes32 specPassDigest) {
        if (!(specHash != bytes32(0))) revert ZeroSpecHash();
        if (!(specToolId != bytes32(0))) revert SpecToolRequired();
        CellTypeDefs.Tool storage specTool = L.tools[specToolId];
        if (!(specTool.exists)) revert SpecToolNotRegistered();
        if (!(specTool.isSpecValidationTool)) revert NotSpecValidationTool();
        return _specRunDigest(specHash, specToolId, true, specErrorsRoot);
    }

    function _clampSubmitAuditWindow(CellStorage.Layout storage L, uint256 requested)
        private
        view
        returns (uint256)
    {
        uint256 floor = L.minAuditWindow;
        if (requested <= floor) return floor;
        return requested;
    }

    function _submitAuditCommon(
        CellStorage.Layout storage L,
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) private view returns (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) {
        supersedesAuditId;
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(deployedAddress != address(0))) revert DeployedAddressRequired();
        if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();

        codehash = deployedAddress.codehash;
        if (!(codehash == expectedCodehash)) revert ArtifactHashMismatch();

        specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        tools = declaredVerdictTools;
        window = _clampSubmitAuditWindow(L, auditWindow);
    }

    function submitGenesisAuditExt(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!L.genesisPending) revert GenesisNotPending();
        if (L.genesisAuditOpen) revert GenesisAuditOpen();
        if (!(bounty > 0)) revert BountyRequired();

        (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) =
            _submitAuditCommon(
                L,
                deployedAddress,
                expectedCodehash,
                specHash,
                specToolId,
                specErrorsRoot,
                bounty,
                declaredVerdictTools,
                supersedesAuditId,
                auditWindow
            );

        id = CellLogicLib.createGenesisAuditExt(
            deployedAddress,
            codehash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            tools,
            supersedesAuditId
        );
        L.genesisAuditId = id;
        L.genesisAuditOpen = true;
    }

    function submitAuditExt(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();

        (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) =
            _submitAuditCommon(
                L,
                deployedAddress,
                expectedCodehash,
                specHash,
                specToolId,
                specErrorsRoot,
                bounty,
                declaredVerdictTools,
                supersedesAuditId,
                auditWindow
            );

        id = CellLogicLib.createAuditExt(
            deployedAddress,
            codehash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            false,
            false,
            0,
            tools,
            supersedesAuditId
        );
    }

    /// @notice Domain-agnostic intake (Pillar B). Pins a BARE `artifactHash` as O — any content-addressable
    ///         artifact, not just an EVM contract. `deployedAddress` is OPTIONAL: pass `address(0)` for a pure
    ///         off-chain artifact; pass a live address to also anchor it on-chain (then its codehash must equal
    ///         `artifactHash`). Everything downstream (caseRoot, dedupe, settlement) is already O-keyed on
    ///         `artifactHash`, so this only widens WHAT can be submitted — no settlement change.
    function submitArtifactAuditExt(
        bytes32 artifactHash,
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(artifactHash != bytes32(0))) revert ArtifactHashRequired();
        // Optional EVM anchor: if an address is supplied it must actually hold the pinned artifact.
        if (deployedAddress != address(0)) {
            if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();
            if (!(deployedAddress.codehash == artifactHash)) revert ArtifactHashMismatch();
        }

        bytes32 specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        uint256 window = _clampSubmitAuditWindow(L, auditWindow);

        id = CellLogicLib.createAuditExt(
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            false,
            false,
            0,
            declaredVerdictTools,
            supersedesAuditId
        );
    }

    function submitFixAuditExt(
        address deployedFix,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        uint256 linkedAuditId
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(deployedFix != address(0))) revert DeployedAddressRequired();
        if (!(deployedFix.code.length > 0)) revert NoContractAtAddress();
        if (!(linkedAuditId < L.nextAuditId)) revert InvalidLinkedAuditId();

        CellTypeDefs.Audit storage linked = L.audits[linkedAuditId];
        if (!(linked.state == CellTypeDefs.AuditState.Claimed)) revert LinkedNotClaimed();
        CellTypeDefs.VulnerabilityClaim storage linkedClaim = L.vulnerabilityClaims[linkedAuditId];
        if (!(linkedClaim.exists)) revert NoClaimOnLinked();
        if (!(!linkedClaim.resolved)) revert LinkedClaimResolved();
        if (!(L.activeFixAuditId[linkedAuditId] == 0)) revert FixAuditAlreadyOpen();

        bytes32 specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        bytes32 artifactHash = deployedFix.codehash;

        bytes32[] memory emptyDeclared;
        id = CellLogicLib.createAuditExt(
            deployedFix,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            linked.auditWindow,
            true,
            false,
            linkedAuditId,
            emptyDeclared,
            0
        );
        L.activeFixAuditId[linkedAuditId] = id;
    }

    // ---------------------------------------------------------------- read-only views (re-landed 2026-07-05)
    // These were present in the Genesis cell-v2 and dropped in the satellite decomposition (backfill diff,
    // 2026-07-05). Re-landed here (library headroom) so the case-root formula stays SINGLE-SOURCE via
    // CellLogicLib._caseRootFromInputs — an integrator computing the case id off-chain gets the exact root the
    // submit path pins, with no risk of a re-implemented formula drifting.

    /// @notice Off-chain case-root preview — EVM-anchored form (deployedAddress must hold the artifact).
    function previewCaseRootExt(
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external view returns (bytes32) {
        if (!(deployedAddress != address(0))) revert DeployedAddressRequired();
        if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();
        bytes32 specPassDigest = _specRunDigest(specHash, specToolId, true, specErrorsRoot);
        return CellLogicLib._caseRootFromInputs(
            deployedAddress.codehash,
            specHash,
            specToolId,
            specPassDigest,
            CellLogicLib._sortToolIds(declaredVerdictTools)
        );
    }

    /// @notice Off-chain case-root preview from a BARE artifactHash (domain-agnostic form — no EVM contract).
    function previewCaseRootFromHashExt(
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external pure returns (bytes32) {
        bytes32 specPassDigest = _specRunDigest(specHash, specToolId, true, specErrorsRoot);
        return CellLogicLib._caseRootFromInputs(
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            CellLogicLib._sortToolIds(declaredVerdictTools)
        );
    }

    /// @notice Full declared-verdict-tool set for an audit (single-call enumerator; len + membership already
    ///         exist as separate getters). Reverts NoAudit for an unknown id.
    function declaredVerdictToolsOfExt(uint256 id)
        external
        view
        returns (bytes32[4] memory toolSlots, uint8 n)
    {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(id < L.nextAuditId)) revert NoAudit();
        n = L.declaredVerdictToolLen[id];
        bytes32[4] storage slots = L.declaredVerdictTools[id];
        for (uint256 i = 0; i < n; i++) {
            toolSlots[i] = slots[i];
        }
    }
}
