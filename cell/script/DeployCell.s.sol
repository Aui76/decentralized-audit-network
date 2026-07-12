// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/IssuanceModule.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecArbiterModule.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/StructuralUpgradeModule.sol";
import "../contracts/FmeaRegistry.sol";
import "../contracts/AssignmentModule.sol";
import "../contracts/IAssignmentModule.sol";
import "../contracts/BlockhashEntropy.sol";

/*
 * Deploy the WHOLE reconstructed system (cell + L1 satellites) from puzzle/ to Base Sepolia (84532).
 *
 * The deploy + wiring sequence is the authoritative production order from
 * test/helpers/CellTestDeploy.sol (CUTOVER-RUNBOOK.md Appendix A). 11 contracts; dispute modules 0-4.
 * Linked external libraries (CellLogicLib, DiscovererPayoutLib, SubmitAuditLib, AssignmentEntropyLib,
 * ToolUseLib — G-19 re-key, 2026-07-08) are auto-deployed + linked by forge script in the broadcast.
 * Pin their addresses from the broadcast log into deployments/{chainId}.json before verify.sh
 * (see REDEPLOY-OPERATOR-RUNBOOK.md).
 *
 *   G-01 mutual bind order: escrow.setNetwork(cell); cell.setTreasuryEscrow(escrow).
 *   G-02 (NO-PREMINE, G7): genesisMint SKIPPED by default; only setMinter runs. The first tokens are earned
 *        by submitGenesisAudit (declared-unfunded B_g). lockMinter() is a SEPARATE post-smoke step (Phase 5).
 *   Testnet: BlockhashEntropy wired via setEntropyProvider; emaToMintBps=2500, mintLpCapBps=500;
 *        claimStakeBps=2000 (constructor default); increment=0.
 *
 * Build integrity (mandatory before broadcast — tested == deployed):
 *   bash script/pre-deploy.sh
 *   export SOURCE_GIT_HEAD="$(cat .build-stamp/git-head.txt)"
 *   export AUDIT_CELL_RUNTIME_BYTES="$(cat .build-stamp/auditCellRuntimeBytes.txt)"
 *
 * Dry run (sim only, after pre-deploy.sh; writes deployments/{chainId}.dryrun.json only):
 *   forge script script/DeployCell.s.sol:DeployCell --rpc-url base_sepolia
 *
 * Broadcast + verify (immediately after pre-deploy; no source edits in between; writes deployments/{chainId}.json):
 *   forge script script/DeployCell.s.sol:DeployCell --rpc-url base_sepolia --broadcast --verify --slow
 *
 * Requires .env (never commit): PRIVATE_KEY, BASE_SEPOLIA_RPC_URL; optional BASESCAN_API_KEY.
 */
contract DeployCell is Script {
    bytes32 internal constant SPEC_TOOL_ID = keccak256("genesis.spec.tool");
    bytes32 internal constant VERDICT_TOOL_ID = keccak256("genesis.verdict.tool");
    /// @dev G-24/G-27 (row 7): founder vesting fully releases after this many DISTINCT (auditor,protocol) pairs.
    ///      Owner-calibrated at deploy; set before setNetwork (raise-only afterwards). 500 = owner's call
    ///      (2026-07-07): the founder fully vests only once the network is a serious, busy one.
    uint256 internal constant FOUNDER_RELEASE_TARGET_PAIRS = 500;

    struct Deployed {
        CellToken token;
        AuditCell cell;
        CellEscrow escrow;
        IssuanceModule issuance;
        ClaimDisputeModule claimModule;
        SpecGapModule specGapModule;
        SpecArbiterModule specArbiterModule;
        IntegrityReviewModule integrityReviewModule;
        StructuralUpgradeModule structuralUpgradeModule;
        FmeaRegistry fmeaRegistry;
        AssignmentModule assignmentModule;
        BlockhashEntropy blockhashEntropy;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // NO-PREMINE (G7): default 0 — the first tokens are EARNED by submitGenesisAudit, not pre-allocated.
        uint256 genesisMint = vm.envOr("GENESIS_MINT", uint256(0));
        string memory timeProfile = vm.envOr("TIME_PROFILE", block.chainid == 84532 ? "testnet" : "mainnet");
        uint256 claimStake = vm.envOr("CLAIM_FILING_STAKE", uint256(100 ether));

        vm.startBroadcast(deployerKey);

        Deployed memory d;

        // --- deploy (admin = deployer) ---
        d.token = new CellToken();
        d.cell = new AuditCell(address(d.token));
        d.escrow = new CellEscrow(address(d.token));
        d.issuance = new IssuanceModule(deployer);
        d.claimModule = new ClaimDisputeModule(deployer);
        d.specGapModule = new SpecGapModule(deployer);
        d.specArbiterModule = new SpecArbiterModule(deployer);
        d.integrityReviewModule = new IntegrityReviewModule(deployer);
        d.structuralUpgradeModule = new StructuralUpgradeModule(deployer);
        d.fmeaRegistry = new FmeaRegistry(deployer);
        d.assignmentModule = new AssignmentModule(deployer);
        d.blockhashEntropy = new BlockhashEntropy();

        // --- wire (exact order; wires precede setDisputeModule) ---
        d.issuance.wire(address(d.cell), address(d.token), address(d.escrow));
        d.issuance.setEmaToMintBps(2500);
        d.issuance.setMintLpCapBps(500);
        d.claimModule.wire(address(d.cell));
        d.fmeaRegistry.wireClaimModule(address(d.claimModule));
        d.claimModule.wireFmeaRegistry(address(d.fmeaRegistry));
        d.assignmentModule.wire(address(d.cell));
        d.specGapModule.wire(address(d.cell));
        d.specArbiterModule.wire(address(d.cell));
        d.integrityReviewModule.wire(address(d.cell), address(d.specArbiterModule));
        d.structuralUpgradeModule.wire(address(d.cell), address(d.issuance));
        d.issuance.setStructuralModule(address(d.structuralUpgradeModule));
        // G-24/G-27 (row 7): founderReleaseTarget is now denominated in DISTINCT (auditor,protocol) PAIRS, not
        // raw audits. It MUST be set here — before setNetwork arms the raise-only lock, and because the contract
        // default (1000) is unreachably high in pair units. Owner-calibrated 500 (2026-07-07): the founder fully
        // vests only once the network is a serious, busy one. Raise-only after this line.
        d.escrow.setFounderReleaseTarget(FOUNDER_RELEASE_TARGET_PAIRS);
        d.escrow.setNetwork(address(d.cell));
        d.escrow.setIssuanceModule(address(d.issuance));
        d.escrow.setStructuralUpgradeModule(address(d.structuralUpgradeModule));
        d.escrow.setIntegrityReviewModule(address(d.integrityReviewModule));
        d.cell.setTreasuryEscrow(address(d.escrow));
        d.cell.setIssuanceModule(address(d.issuance));
        d.cell.setDisputeModule(0, address(d.claimModule));
        d.cell.setDisputeModule(1, address(d.specGapModule));
        d.cell.setDisputeModule(2, address(d.specArbiterModule));
        d.cell.setDisputeModule(3, address(d.integrityReviewModule));
        d.cell.setDisputeModule(4, address(d.structuralUpgradeModule));
        d.cell.setAssignmentModule(address(d.assignmentModule));

        // Entropy provider: testnet wires BlockhashEntropy; mainnet uses commit-reveal (mainnet-gates.md).
        if (_isTestnetProfile(timeProfile)) {
            d.cell.setEntropyProvider(address(d.blockhashEntropy));
        }

        // --- time profile (G5): same code, params only — testnet fast / mainnet production ---
        if (_isTestnetProfile(timeProfile)) {
            _applyTestnetTimeProfile(d);
        } else {
            _applyMainnetProfile(d);
        }
        if (claimStake != 100 ether) {
            d.cell.setParam(CellParamIds.CLAIM_FILING_STAKE, claimStake);
        }

        // --- tools + token ---
        d.cell.registerTool(SPEC_TOOL_ID, true);
        d.cell.registerTool(VERDICT_TOOL_ID, false);
        // NO-PREMINE (G7): genesisMint is SKIPPED by default (genesisMint == 0). totalSupply stays 0 at
        // deploy; the first tokens mint when submitGenesisAudit confirms (Phase 5). Only an explicit
        // GENESIS_MINT > 0 opt-in pre-mints (not used on mainnet).
        if (genesisMint > 0) {
            d.token.genesisMint(deployer, genesisMint);
        }
        d.token.setMinter(address(d.issuance));
        // NOTE: d.token.lockMinter() is a SEPARATE post-smoke step (Phase 5), NOT run here.

        vm.stopBroadcast();

        _writeDeployment(d, deployer, genesisMint, timeProfile, claimStake);
    }

    function _isTestnetProfile(string memory profile) internal pure returns (bool) {
        return keccak256(bytes(profile)) == keccak256("testnet");
    }

    /// @dev Ordering-preserving fast profile (R11b: claimResolution > protocolClaimDecision).
    function _applyTestnetTimeProfile(Deployed memory d) internal {
        d.cell.setParam(CellParamIds.DECISION, 5 minutes);
        d.cell.setParam(CellParamIds.PROTOCOL_DECISION, 5 minutes);
        d.cell.setParam(CellParamIds.IN_AUDIT, 10 minutes);
        d.cell.setParam(CellParamIds.MIN_AUDIT, 10 minutes);
        d.cell.setParam(CellParamIds.CLAIM_RESOLUTION, 10 minutes);
        d.claimModule.setProtocolClaimDecisionWindow(2 minutes);
    }

    /// @dev Mainnet posture (G7): position-scaled hold restored; reverses G1 testnet increment=0 default.
    function _applyMainnetProfile(Deployed memory d) internal {
        d.cell.setIncrement(1 ether);
        d.cell.lockIncrement();
    }

    /// @dev Canonical deployments/{chainId}.json is written only on --broadcast/--resume.
    /// Simulations write deployments/{chainId}.dryrun.json so live records are never clobbered.
    function _deploymentJsonPath() internal view returns (string memory) {
        string memory base = string.concat("deployments/", vm.toString(block.chainid));
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            return string.concat(base, ".json");
        }
        return string.concat(base, ".dryrun.json");
    }

    function _writeDeployment(
        Deployed memory d,
        address deployer,
        uint256 genesisMint,
        string memory timeProfile,
        uint256 claimStake
    ) internal {
        string memory obj = "deployment";
        string memory json = vm.serializeUint(obj, "chainId", block.chainid);
        json = vm.serializeAddress(obj, "deployer", deployer);
        json = vm.serializeAddress(obj, "CellToken", address(d.token));
        json = vm.serializeAddress(obj, "AuditCell", address(d.cell));
        json = vm.serializeAddress(obj, "CellEscrow", address(d.escrow));
        json = vm.serializeAddress(obj, "IssuanceModule", address(d.issuance));
        json = vm.serializeAddress(obj, "ClaimDisputeModule", address(d.claimModule));
        json = vm.serializeAddress(obj, "SpecGapModule", address(d.specGapModule));
        json = vm.serializeAddress(obj, "SpecArbiterModule", address(d.specArbiterModule));
        json = vm.serializeAddress(obj, "IntegrityReviewModule", address(d.integrityReviewModule));
        json = vm.serializeAddress(obj, "StructuralUpgradeModule", address(d.structuralUpgradeModule));
        json = vm.serializeAddress(obj, "FmeaRegistry", address(d.fmeaRegistry));
        json = vm.serializeAddress(obj, "AssignmentModule", address(d.assignmentModule));
        json = vm.serializeAddress(obj, "BlockhashEntropy", address(d.blockhashEntropy));
        json = vm.serializeAddress(obj, "entropyProvider", d.cell.entropyProvider());
        json = vm.serializeBytes32(obj, "specToolId", SPEC_TOOL_ID);
        json = vm.serializeBytes32(obj, "verdictToolId", VERDICT_TOOL_ID);
        json = vm.serializeUint(obj, "genesisMint", genesisMint);
        json = vm.serializeString(obj, "timeProfile", timeProfile);
        json = vm.serializeUint(obj, "decisionWindowSec", d.cell.decisionWindow());
        json = vm.serializeUint(obj, "protocolDecisionWindowSec", d.cell.protocolDecisionWindow());
        json = vm.serializeUint(obj, "inAuditWindowSec", d.cell.inAuditWindow());
        json = vm.serializeUint(obj, "minAuditWindowSec", d.cell.minAuditWindow());
        json = vm.serializeUint(obj, "claimResolutionSec", d.cell.claimResolutionWindow());
        json = vm.serializeUint(
            obj, "protocolClaimDecisionSec", d.claimModule.protocolClaimDecisionWindow()
        );
        json = vm.serializeUint(obj, "claimFilingStake", claimStake);
        json = vm.serializeUint(obj, "claimStakeBps", d.cell.claimStakeBps());
        json = vm.serializeUint(obj, "emaToMintBps", 2500);
        json = vm.serializeUint(obj, "mintLpCapBps", 500);

        string memory cellVersion = "p1-cell-v2";
        if (block.chainid == 84532) {
            cellVersion = "p1-base-sepolia";
            json = vm.serializeString(
                obj,
                "status",
                "demo / testnet-grade - no real-value bounties; claimVerifier=0 declare-only; witness settlement via ClaimDisputeModule"
            );
        }
        json = vm.serializeString(obj, "cellVersion", cellVersion);
        uint256 auditRuntimeBytes = vm.envOr("AUDIT_CELL_RUNTIME_BYTES", uint256(22979));
        json = vm.serializeUint(obj, "auditCellRuntimeBytes", auditRuntimeBytes);
        string memory gitHead = vm.envOr("SOURCE_GIT_HEAD", string("unknown"));
        json = vm.serializeString(obj, "sourceGitHead", gitHead);
        json = vm.serializeAddress(obj, "claimVerifier", d.cell.claimVerifier());
        json = vm.serializeBool(obj, "claimVerifierLocked", d.cell.claimVerifierLocked());

        string memory path = _deploymentJsonPath();
        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            json = vm.serializeBool(obj, "simulation", true);
            json = vm.serializeString(
                obj,
                "simulationNote",
                "forge script dry-run only - not on chain; canonical live addresses in deployments/{chainId}.json"
            );
        }

        vm.writeJson(json, path);

        console2.log("=== puzzle system deployed (cell + 4 satellites + registry) ===");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("CellToken", address(d.token));
        console2.log("AuditCell", address(d.cell));
        console2.log("CellEscrow", address(d.escrow));
        console2.log("IssuanceModule", address(d.issuance));
        console2.log("ClaimDisputeModule", address(d.claimModule));
        console2.log("SpecGapModule", address(d.specGapModule));
        console2.log("SpecArbiterModule", address(d.specArbiterModule));
        console2.log("IntegrityReviewModule", address(d.integrityReviewModule));
        console2.log("StructuralUpgradeModule", address(d.structuralUpgradeModule));
        console2.log("FmeaRegistry", address(d.fmeaRegistry));
        console2.log("AssignmentModule", address(d.assignmentModule));
        console2.log("BlockhashEntropy", address(d.blockhashEntropy));
        console2.log("entropyProvider", d.cell.entropyProvider());
        console2.log("written", path);
        console2.log("Pin CellLogicLib/DiscovererPayoutLib/SubmitAuditLib/AssignmentEntropyLib/ToolUseLib from broadcast log before verify.sh");
        console2.log("Post-deploy: verify pointer read-backs (Appendix B), run one smoke confirm, THEN token.lockMinter()");
    }
}
