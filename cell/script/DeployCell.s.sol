// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./EnvReads.s.sol";
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
contract DeployCell is EnvReads {
    bytes32 internal constant SPEC_TOOL_ID = keccak256("genesis.spec.tool");
    bytes32 internal constant VERDICT_TOOL_ID = keccak256("genesis.verdict.tool");
    /// @dev G-24/G-27 (row 7): founder vesting fully releases after this many DISTINCT (auditor,protocol) pairs.
    ///      Owner-calibrated at deploy; set before setNetwork (raise-only afterwards). 500 = owner's call
    ///      (2026-07-07): the founder fully vests only once the network is a serious, busy one.
    uint256 internal constant FOUNDER_RELEASE_TARGET_PAIRS = 500;
    /// @dev VD-107 layer (1): the spec-challenge fee is the PRICE of a spec challenge that nobody rules
    ///      on. It shipped as an uninitialized `uint256` - zero - while its six siblings in
    ///      `SpecArbiterModule` all carry defaults, and NO deploy path ever set it, so on every cell these
    ///      scripts produced, challenging cost nothing. Set here and read back below; an unset fee FAILS
    ///      the deploy. Overridable with SPEC_CHALLENGE_FEE. Pricing note: this is necessary and NOT
    ///      sufficient - a flat fee small beside a bounty still makes dodging cheap, which is why the
    ///      structural close lives in `finalizeSpecChallenge`, not in this number.
    /// @dev VD-117: the fee has TWO PAYERS that VD-107 never separated. On a void it is the PROTOCOL's
    ///      cancel price, drawn from the bounty. On an unruled expiry it is the CHALLENGER's, drawn from
    ///      their stake - and `finalizeSpecChallenge` clamps it to the stake, so a fee AT PARITY with the
    ///      100 ether `specChallengeStake` refunded ZERO and inverted the incentive: a challenger disproven
    ///      by a defend forfeits nothing on the first defend, while a challenger nobody adjudicated forfeited
    ///      everything. The person punished hardest was an honest challenger who hit a no-arbiter failure of
    ///      the system. 10 ether, and `fee < stake` is ASSERTED below rather than left to whoever picks the
    ///      next value. Two parameters for the two payers is booked to the next window.
    uint256 internal constant SPEC_CHALLENGE_FEE_DEFAULT = 10 ether;

    /// @dev PC-106 (G6, VD-202(3)(a)): THE TESTNET PROFILE MUST BE ABLE TO RUN ITS OWN MILESTONES. Every stake floor they
    ///      need was 100 AUDIT or more, while a fresh cell's only liquid AUDIT after genesis is the genesis auditor's reward -
    ///      78.125, measured by `DeployCellStakeProfile.t.sol` running a real genesis rather than typed here. 10 AUDIT per
    ///      floor fits it with room for a bounty beside it. The mainnet profile keeps the contract defaults; its floors are a
    ///      separate decision.
    uint256 public constant TESTNET_STAKE_FLOOR = 10 ether;
    /// @dev VD-117 survives the lower floor: the fee stays strictly below the spec-challenge stake it is drawn from.
    uint256 public constant SPEC_CHALLENGE_FEE_TESTNET = 1 ether;

    // `_optionalUint` MOVED TO `EnvReads.s.sol` (PC-67 closed, 2026-09-11). `bug_002` put it here
    // as a local copy because this contract could not inherit `InstanceAware` - that base also
    // builds record paths, and this file's own `_deploymentJsonPath` has the dry-run split the two
    // must not disagree about. A base carrying ONLY the env helpers removes that objection, so the
    // copy is gone rather than explained. Body unchanged; only its address did.

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
        uint256 genesisMint = _optionalUint("GENESIS_MINT", 0);
        string memory timeProfile = vm.envOr("TIME_PROFILE", block.chainid == 84532 ? "testnet" : "mainnet");
        uint256 claimStake = _optionalUint("CLAIM_FILING_STAKE", _isTestnetProfile(timeProfile) ? TESTNET_STAKE_FLOOR : 100 ether);

        // PC-85 (G6, I6) - THE DEPLOY NAMES ITS GENESIS AUDITOR. Auditor position 1 holds nothing at any increment and is the
        // queue head the genesis audit is drawn from, so between this deploy and the auditor's own registration a stranger
        // could take it. The cell now refuses any other first registrant once a genesis auditor is named, and the name is
        // set in THIS broadcast, the transaction right after the cell's own creation. REQUIRED, never a silent default
        // (bug_002 / PC-55's class): leaving the seat open is a choice, spelled GENESIS_AUDITOR_OPEN=1. Both are read through
        // the checked EnvReads helpers (R27): a set-but-unparseable value refuses instead of silently becoming the default.
        // What remains is the block between the cell's creation and that naming - named to the vault, not hidden.
        address genesisAuditor = _optionalAddress("GENESIS_AUDITOR", address(0));
        require(
            genesisAuditor != address(0) || _optionalUint("GENESIS_AUDITOR_OPEN", 0) == 1,
            "GENESIS_AUDITOR required (PC-85): the address that must take auditor position 1. Set GENESIS_AUDITOR_OPEN=1 to leave the seat open deliberately."
        );
        require(genesisAuditor != deployer, "GENESIS_AUDITOR must not be the deployer (PC-86)");

        // TIME_PROFILE MUST BE ONE OF THE TWO KNOWN VALUES (bug_404, 2026-09-04). Selection below is an
        // EXACT keccak match against "testnet", so anything unrecognised - "Testnet", a trailing space in
        // .env, "test", or a stale exported "mainnet" - silently selects _applyMainnetProfile, which runs
        // setIncrement(1 ether) THEN lockIncrement(). `incrementLocked` has no unlock (AuditCell:736
        // reverts AlreadyLocked), so that typo is PERMANENT and SetIncrement.s.sol names the only remedy:
        // "redeploy with TIME_PROFILE=testnet". The mechanical assert for this already existed on the RUNG
        // wrapper (deploy-dedicated-instance.ps1) and never on the canonical path - the same asymmetry
        // export-stamp.sh's own header documents for the git head and closed there. Closed here now.
        // Deliberately BEFORE startBroadcast: a refusal must cost nothing, not a reverted broadcast.
        require(
            _isTestnetProfile(timeProfile) || keccak256(bytes(timeProfile)) == keccak256("mainnet"),
            "TIME_PROFILE unrecognised: must be exactly 'testnet' or 'mainnet'"
        );

        vm.startBroadcast(deployerKey);

        Deployed memory d;

        // --- deploy (admin = deployer) ---
        d.token = new CellToken();
        d.cell = new AuditCell(address(d.token));
        // PC-85 (VD-233(1)): the seat closes at THIS transaction, not at the deploy block - `new AuditCell` above is a
        // separate transaction of the same broadcast, and position 1 is open by default until an auditor is named.
        // A registration that lands between the two makes this call REVERT (AuditCell refuses to name after anyone
        // registered), so a lost race stops the broadcast loudly and costs a redeploy of a cell holding no value.
        if (genesisAuditor != address(0)) d.cell.setGenesisBootstrap(address(0), genesisAuditor);
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
        if (claimStake != d.cell.claimFilingStake()) {
            d.cell.setParam(CellParamIds.CLAIM_FILING_STAKE, claimStake);
        }
        require(d.cell.claimFilingStake() == claimStake, "claimFilingStake read-back mismatch");
        require(d.cell.genesisAuditor() == genesisAuditor, "genesisAuditor read-back mismatch (PC-85)");
        _requireClaimWindowCoversAuditorPath(d.cell);

        // --- VD-107 (1): price the spec challenge, then PROVE it took ---
        uint256 specChallengeFee = _optionalUint(
            "SPEC_CHALLENGE_FEE", _isTestnetProfile(timeProfile) ? SPEC_CHALLENGE_FEE_TESTNET : SPEC_CHALLENGE_FEE_DEFAULT
        );
        require(specChallengeFee > 0, "SPEC_CHALLENGE_FEE must be > 0 (VD-107: a zero fee makes the escape free)");
        d.specArbiterModule.setSpecChallengeFee(specChallengeFee);
        // Read-back assert in VD-91's form: assert what the CHAIN says, never what the call returned.
        // This is the shape the admin-rotation miss taught - `VerifyWiring` asserted an invariant nobody
        // had re-read for a month. A setter that silently no-ops must fail the deploy, not the audit.
        require(
            d.specArbiterModule.specChallengeFee() == specChallengeFee,
            "specChallengeFee read-back mismatch"
        );
        // VD-117: fee < stake, asserted against the CHAIN's two values rather than the constants above,
        // for the same reason the read-back exists - a bound checked against what was intended cannot see
        // a setter that did something else. At parity the unruled-expiry refund is zero.
        require(
            d.specArbiterModule.specChallengeFee() < d.specArbiterModule.specChallengeStake(),
            "specChallengeFee must be < specChallengeStake (VD-117: at parity an unruled expiry refunds 0)"
        );

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

    /// @dev PC-88(a) / VD-182 (2026-09-15). A dispute's life runs from its spawn (`windowStart`), while its drawn auditor's
    ///      clock runs from pickup - decision, in-audit, then the minimum audit window before confirm. A claim-resolution
    ///      window shorter than that path lets anyone expire every dispute before it can settle. The canonical cell shipped
    ///      exactly that from the testnet profile (600 s against 300 + 600 + 600) and was cured on chain by setParam(0, 1800).
    ///      Asserted on the CHAIN's values after the profile runs, for both profiles.
    function _requireClaimWindowCoversAuditorPath(AuditCell cell) internal view {
        uint256 path = cell.decisionWindow() + cell.inAuditWindow() + cell.minAuditWindow();
        require(
            cell.claimResolutionWindow() >= path,
            "claimResolutionWindow < decisionWindow + inAuditWindow + minAuditWindow: every dispute would be expirable before it could settle (PC-88(a))"
        );
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
        // 30 minutes, not 10 (2026-09-15, PC-88(a)): >= DECISION + IN_AUDIT + MIN_AUDIT (25 minutes) plus margin, the value the
        // canonical cell was corrected to on chain. `_requireClaimWindowCoversAuditorPath` refuses anything shorter.
        d.cell.setParam(CellParamIds.CLAIM_RESOLUTION, 30 minutes);
        d.claimModule.setProtocolClaimDecisionWindow(2 minutes);
        // PC-106 (G6): the stake floors every milestone needs, inside the post-genesis liquid supply (see TESTNET_STAKE_FLOOR).
        d.cell.setParam(CellParamIds.CLAIM_FILING_STAKE, TESTNET_STAKE_FLOOR);
        d.specArbiterModule.setSpecChallengeStake(TESTNET_STAKE_FLOOR);
        d.integrityReviewModule.setIntegrityFilingStake(TESTNET_STAKE_FLOOR);
        d.integrityReviewModule.setIntegrityContestStake(TESTNET_STAKE_FLOOR);
        d.structuralUpgradeModule.setGapFilingStake(TESTNET_STAKE_FLOOR);
    }

    /// @dev Mainnet posture (G7): position-scaled hold restored; reverses G1 testnet increment=0 default.
    function _applyMainnetProfile(Deployed memory d) internal {
        d.cell.setIncrement(1 ether);
        d.cell.lockIncrement();
    }

    /// @dev Canonical deployments/{chainId}.json is written only on --broadcast/--resume.
    /// Simulations write deployments/{chainId}.dryrun.json so live records are never clobbered.
    function _deploymentJsonPath() internal view returns (string memory) {
        // 2026-07-19: the writer was keyed ONLY on chainid, so a rung/disposable deploy to 84532
        // OVERWROTE the live cell's deployments/84532.json (incident: rung-1 clobbered the live
        // record, restored from HEAD; ffd6571 addendum b). Defense 1 of 2: DEPLOY_INSTANCE_LABEL
        // routes a labeled deploy to deployments/<chainid>-<label>.json, so it CANNOT touch the
        // canonical file by construction. Defense 2 (the overwrite guard) lives in _writeDeployment.
        string memory base = string.concat("deployments/", vm.toString(block.chainid));
        string memory instanceLabel = vm.envOr("DEPLOY_INSTANCE_LABEL", string(""));
        if (bytes(instanceLabel).length > 0) {
            base = string.concat(base, "-", instanceLabel);
        }
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            return string.concat(base, ".json");
        }
        return string.concat(base, ".dryrun.json");
    }

    /// @dev PC-55 — A GATE THAT PROVES PROVENANCE MUST NOT DELETE IT.
    ///      `deployments/<chainid>[-label].dryrun.json` is TRACKED (`78592d7`, 2026-09-03), and the
    ///      overwrite guard below is conditioned on `ScriptBroadcast || ScriptResume`, so it never
    ///      evaluates on the dry-run leg — `vm.writeJson` just runs. The §0 command as printed carried
    ///      no `SOURCE_GIT_HEAD`, so a real head was replaced by the string "unknown" with nothing
    ///      raising a voice. MEASURED 2026-09-08: R10 went `60 pinned / 5 declared-unknown` to `59 / 6`
    ///      over `78c7282d…`, and was restored only because somebody happened to be watching R10.
    ///
    ///      This refuses exactly that and nothing else. Writing a REAL head over any value is fine;
    ///      writing "unknown" onto a file that has no head yet is fine; writing "unknown" over a head
    ///      the repo already recorded is a silent deletion of provenance and stops here. It runs on
    ///      EVERY leg, dry-run included, because the dry-run leg is the one with the hole.
    function _requireProvenanceNotDowngraded(string memory path, string memory gitHead) internal view {
        // Writing a REAL head is always fine - that is the whole point of the stamp.
        if (keccak256(bytes(gitHead)) != keccak256(bytes("unknown"))) return;
        // A first deploy has nothing to lose. This guard is about DELETION, not about
        // requiring a stamp: making the stamp mandatory would block a legitimate first run.
        if (!vm.exists(path)) return;
        string memory existing = vm.readFile(path);
        if (!vm.keyExists(existing, ".sourceGitHead")) return;   // no prior claim to delete
        string memory prior = vm.parseJsonString(existing, ".sourceGitHead");
        require(
            bytes(prior).length == 0 || keccak256(bytes(prior)) == keccak256(bytes("unknown")),
            "DeployCell: refusing to overwrite a RECORDED sourceGitHead with \"unknown\""
            " (PC-55). Export SOURCE_GIT_HEAD=\"$(cat .build-stamp/git-head.txt)\" as this"
            " file's header line 39 prescribes. A gate whose subject is provenance must not delete it."
        );
    }

    /// @dev PC-55's second half (2026-09-15, re-raised as the first second-family record's bug_008): the guard above
    ///      refuses only DELETING a recorded head, so a FIRST broadcast still wrote `sourceGitHead = "unknown"` - a
    ///      live record with no provenance at all. The reason the guard stayed narrow ("making the stamp mandatory
    ///      would block a legitimate first run") holds for the DRY-RUN leg and for a local chain, and for nothing
    ///      else: a broadcast to a real chain is the one leg whose record is the provenance. So: broadcast or resume,
    ///      chain not the local 31337 (the sim's anvil, `body/sim/lib/paths.mjs` DEFAULT_CHAIN_ID) -> a real head.
    ///      Value-in so a test drives every leg without a broadcast context.
    function _requireRealHeadOnBroadcast(string memory gitHead, bool broadcasting, uint256 chainId) internal pure {
        if (!broadcasting || chainId == 31337) return;
        require(
            bytes(gitHead).length > 0 && keccak256(bytes(gitHead)) != keccak256(bytes("unknown")),
            "DeployCell: a broadcast to a real chain needs SOURCE_GIT_HEAD (PC-55) - source script/export-stamp.sh first"
        );
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
        // ADMIN, added 2026-09-05 (`update network folder`). `deployer` is who SENT the deploy and
        // is not necessarily who administers the cell afterwards - the live cell's admin was
        // rotated off the deployer key on 2026-08-03 and no cell-side record named the new one for
        // a month. READ BACK from the contract rather than assuming `deployer`, so the record is a
        // measurement and stays correct through any future rotation at deploy time.
        json = vm.serializeAddress(obj, "admin", d.cell.admin());
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
        json = vm.serializeUint(obj, "claimFilingStake", d.cell.claimFilingStake());
        json = vm.serializeAddress(obj, "genesisAuditor", d.cell.genesisAuditor());
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
        // Guardrail (2026-07-19): envOr SILENTLY returns its default when the value is set but
        // unparseable, so a thousands-comma from forge build --sizes ("24,522") recorded a stale
        // magic 22979 with no signal. Split the two cases: UNSET -> 0 (an honest "unstamped", so
        // local/dry runs still work), SET-BUT-UNPARSEABLE -> envUint reverts loud.
        uint256 auditRuntimeBytes = 0;
        if (bytes(vm.envOr("AUDIT_CELL_RUNTIME_BYTES", string(""))).length > 0) {
            auditRuntimeBytes = vm.envUint("AUDIT_CELL_RUNTIME_BYTES");
        }
        // Guard (deploy-size-stamp-vs-bytecode, operator-approved; built 2026-08-03): a well-formed
        // stamp is still an UNVERIFIED claim. Compare it to the bytecode ACTUALLY deployed. Behind
        // != 0 so an honestly-unstamped local/dry run stays silent; a stamp that CLAIMS a size and
        // lies reverts here, at broadcast, instead of landing a false size in the record. d.cell IS
        // the AuditCell instance (d.cell = new AuditCell(...)), so its own code.length is the size.
        if (auditRuntimeBytes != 0) {
            require(
                auditRuntimeBytes == address(d.cell).code.length,
                "AUDIT_CELL_RUNTIME_BYTES stamp does not match deployed AuditCell bytecode"
            );
        }
        json = vm.serializeUint(obj, "auditCellRuntimeBytes", auditRuntimeBytes);
        string memory gitHead = vm.envOr("SOURCE_GIT_HEAD", string("unknown"));
        json = vm.serializeString(obj, "sourceGitHead", gitHead);
        json = vm.serializeAddress(obj, "claimVerifier", d.cell.claimVerifier());
        json = vm.serializeBool(obj, "claimVerifierLocked", d.cell.claimVerifierLocked());

        string memory path = _deploymentJsonPath();
        // PC-55: BEFORE anything is written, and on every leg - the dry-run leg is the hole.
        _requireProvenanceNotDowngraded(path, gitHead);
        // PC-55's second half: a BROADCAST to a real chain records a real head. Forge simulates the whole script before
        // it sends anything, so this refusal lands before the first transaction.
        _requireRealHeadOnBroadcast(
            gitHead,
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume),
            block.chainid
        );
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

        // Defense 2 of 2 -- the teeth (2026-07-19): refuse to overwrite an EXISTING canonical
        // record whose AuditCell differs from the cell being deployed, unless DEPLOY_OVERWRITE=1.
        // The label above relies on the operator remembering it; this catches a FORGOTTEN label
        // before it clobbers a different cell. A genuine re-broadcast/resume of the SAME cell has
        // the same deterministic address -> guard passes. Only a DIFFERENT cell to the same file
        // trips it. (This is the guard that would have PREVENTED the rung-1 clobber.)
        // DEPLOY_OVERWRITE (2026-07-19, ultrareview bug_005): accept "1" OR "true". Foundry's bool
        // envOr parses ONLY "true"/"false", so envOr(...,false) SILENTLY drops the =1 that the comment
        // above and the revert below both instruct -> guard never lifts -> operator loops on a revert
        // telling them to do the thing that doesn't parse. SAME silent-default family as the
        // AUDIT_CELL_RUNTIME_BYTES trap. Read as string, compare explicitly; anything unrecognized ->
        // false -> guard STAYS ACTIVE (the safe side: it blocks loudly, with instructions).
        string memory overwriteRaw = vm.envOr("DEPLOY_OVERWRITE", string(""));
        bool overwriteForced = keccak256(bytes(overwriteRaw)) == keccak256(bytes("1"))
            || keccak256(bytes(overwriteRaw)) == keccak256(bytes("true"));
        if (
            (
                vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                    || vm.isContext(VmSafe.ForgeContext.ScriptResume)
            ) && vm.exists(path) && !overwriteForced
        ) {
            address existingCell = vm.parseJsonAddress(vm.readFile(path), ".AuditCell");
            // 2026-07-29 (anvil smoke, fresh-rung prep): forge script --broadcast EXECUTES THE
            // SCRIPT TWICE (local + on-chain simulation). On a chain where the linked libraries
            // are not yet deployed, the two phases route library creation differently, the
            // deployed addresses differ between phases, and phase 2 tripped this guard against
            // the file phase 1 had just written -- same invocation, no operator error, zero txs
            // sent. Refine: a record only BLOCKS if its cell actually has code on this chain
            // (a real, live instance -- e.g. the canonical 84532.json's frozen live cell). A
            // same-invocation phase-1 artifact (or a stale record of an aborted deploy) has no
            // code at its address and must not block. The forgotten-label clobber the guard
            // exists for stays blocked: the live cell always has code.
            require(
                existingCell == address(d.cell) || existingCell.code.length == 0,
                "DeployCell: refusing to overwrite deployments/<chainid>.json for a DIFFERENT LIVE AuditCell -- set DEPLOY_INSTANCE_LABEL for a rung, or DEPLOY_OVERWRITE=1 to force"
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
