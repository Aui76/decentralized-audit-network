// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import "./InstanceAware.s.sol";
import "../contracts/satellites/AuditEthMembrane.sol";

/// @dev The deploy script needs approve() and balanceOf() on the AUDIT token. The membrane's own
///      IAuditToken is deliberately minimal (transfer/transferFrom/balanceOf only) and must stay that
///      way, so the script declares the surface IT needs rather than widening the membrane's.
interface IAuditTokenDeploy {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/*
 * DeployMembrane -- deploys the AUDIT<->ETH membrane satellite (FC-17 / DEC-38).
 *
 * The membrane is a SATELLITE (DR-11): the cell does not import it and it does not import the
 * cell. It is deployed AFTER an instance exists, seeded ONCE, and then touched by nobody --
 * DEC-38 removed the LP door, so there is no feed, no manager and no withdraw path.
 *
 * ---------------------------------------------------------------------------------------------
 * THE SILENT-DEFAULT GUARDRAIL, applied deliberately (2026-07-19 / 2026-07-29 ultrareviews).
 * Two of the four defects those passes caught were IN DEPLOY SCRIPTS, both the same family:
 *   - `vm.envOr(..., uint256(22979))` silently returned its default when the value was
 *     set-but-unparseable (a thousands comma), and a wrong size shipped with NO signal.
 *   - `vm.envOr(..., false)` parses only "true"/"false", so it silently dropped the `=1` the
 *     guard's own revert message instructed the operator to set.
 * So EVERY value here is read as a STRING first; if the string is non-empty it is parsed with the
 * LOUD variant (envUint/envAddress), which reverts on garbage. A default is only ever used when
 * the variable is genuinely ABSENT. Absence is a decision; unparseable is an error. Never confuse
 * them again.
 * ---------------------------------------------------------------------------------------------
 *
 * REQUIRED env:
 *   PRIVATE_KEY              deployer key (also the seed source -- must hold the AUDIT and the ETH)
 *   MEMBRANE_AUD_SEED        opening AUDIT reserve, wei
 *   MEMBRANE_ETH_SEED        opening ETH reserve, wei   (these two set the opening price)
 *   MEMBRANE_MIN_PRICE_E18   lower bound (inclusive) on the opening mid price ethSeed*1e18/audSeed
 *   MEMBRANE_MAX_PRICE_E18   upper bound (inclusive) -- the pair guards the one irreversible
 *                            parameter that had NO bound (M-2): a transposed seed or a dropped digit
 *                            still passes every OTHER guard here and opens a mispriced pool with no
 *                            owner, no pause and no withdraw to fix it. MUST satisfy
 *                            MAX <= 2*MIN (VD-23, 2026-08-22): a band wider than that is theatre --
 *                            the mistakes this guard exists for are off by orders of magnitude, not
 *                            by 40%. The computed opening mid is logged in wei AND decimal terms on
 *                            EVERY run, pass or refuse, so the operator sees the real number without
 *                            the approve-under-pressure problem a "confirm the computed mid" prompt
 *                            would have had.
 *   DEPLOY_INSTANCE_LABEL    routes BOTH the token lookup and the membrane record to
 *                            deployments/<chainid>-<label>.json  (InstanceAware -- one label, one
 *                            instance, everywhere; this is why the rung7 clobber incident cannot
 *                            repeat here). REQUIRED here, not optional (M-6): unset was
 *                            indistinguishable from an explicit "I mean the canonical live
 *                            instance", and this script runs in its own shell
 *                            (RUNG11-PLAN.md:83) where the label is re-exported by hand -- a
 *                            forgotten re-export must not silently resolve to the frozen live
 *                            cell's records. Set your rung/instance label, or literally
 *                            "canonical" if you explicitly mean the unlabeled live instance.
 * OPTIONAL env:
 *   MEMBRANE_FEE_BPS       symmetric per-side spread, bps (default 30 = 0.30%)
 *   CELL_TOKEN             AUDIT token; default = CellToken from the instance deployment record
 *   MEMBRANE_OVERWRITE     "1"/"true" -- allow replacing an existing record naming a DIFFERENT
 *                          membrane. Absent = refuse. Deliberate, never accidental.
 *
 * Writes: broadcast -> deployments/membrane-<chainid>[-<label>].json
 *         dry-run   -> deployments/membrane-<chainid>[-<label>].dryrun.json  (+ simulation:true
 *                      inside the file). A simulation can never overwrite the real record.
 */
contract DeployMembrane is InstanceAware {
    /// @dev String-first read of a REQUIRED uint. Absent -> revert with a named message.
    ///      Present-but-garbage -> envUint reverts loud. No silent default is possible.
    // `_requiredUint` MOVED TO `InstanceAware` alongside `_optionalUint` (PC-67, 2026-09-11).
    // Body unchanged; only its address did. Kept together because they are read as a pair.

    // `_optionalUint` MOVED TO `InstanceAware` (PC-67, 2026-09-11). It was defined here, and this
    // contract already inherits that base - so the helper this file's own header calls mandatory was
    // reachable by exactly one of the ten scripts that share the base, and `GenesisBootstrapProtocol`
    // sat on the canonical deploy path reading `GENESIS_BOUNTY` with the raw `vm.envOr` this comment
    // forbids. The body did not change; only its address did. See InstanceAware.s.sol.

    /// @dev VD-23: render an 1e18-scaled value as a decimal string (e.g. 1000000000000000 ->
    ///      "0.001000000000000000") so a wrong order of magnitude is visible at a glance instead of
    ///      requiring the reader to count zeros in a raw wei string.
    function _formatE18(uint256 x) internal pure returns (string memory) {
        uint256 whole = x / 1e18;
        uint256 frac = x % 1e18;
        string memory fracStr = vm.toString(frac);
        bytes memory fb = bytes(fracStr);
        string memory pad = "";
        for (uint256 i = fb.length; i < 18; i++) {
            pad = string.concat(pad, "0");
        }
        return string.concat(vm.toString(whole), ".", pad, fracStr);
    }

    /// @dev DRY-RUN SPLIT (2026-08-08, idea-radar catch). This script's own header orders "VERIFY BY
    ///      SIMULATION FIRST", and `run()` writes its record on EVERY execution -- so without this,
    ///      a simulation writes PREDICTED addresses and reserves to the path a broadcast writes, with
    ///      nothing in the file saying which one produced it. DEC-38 sharpens the cost: the membrane
    ///      is seeded ONCE and touched by nobody, so that record is the only account of the opening
    ///      reserves that will ever exist; a later re-simulation would silently replace it with a pool
    ///      that never existed. `DeployCell` has carried both defenses since 2026-07-19
    ///      (:196-202 path split, :285-289 in-file markers); this is its neighbour inheriting them --
    ///      the "one caller has it, its neighbour does not" shape, closed before first use.
    function _membraneRecordPath() internal view returns (string memory) {
        string memory base = string.concat("deployments/membrane-", vm.toString(block.chainid));
        string memory label = _instanceLabel();
        // M-6: "canonical" is the explicit sentinel for "I mean the unlabeled live instance" (see
        // _requireExplicitLabel below) -- it must resolve to the SAME unlabeled path an empty label
        // used to produce, not to a literal "-canonical" suffix that names a file that never exists.
        bool isCanonical = keccak256(bytes(label)) == keccak256(bytes("canonical"));
        if (bytes(label).length > 0 && !isCanonical) base = string.concat(base, "-", label);
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            return string.concat(base, ".json");
        }
        return string.concat(base, ".dryrun.json");
    }

    /// @dev True only when this execution is actually landing on chain.
    function _isBroadcast() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @dev M-6: DEPLOY_INSTANCE_LABEL fail-open guard. `_instanceLabel()` reads it as
    ///      `vm.envOr(..., string(""))`, so unset and "" are the same value, and "" is exactly what
    ///      routes the token lookup (:112-113, via the inherited `_deploymentRecordPath`) and the
    ///      membrane record (`_membraneRecordPath`, above) to the UNLABELED, canonical files -- on
    ///      84532 that is the frozen live cell. This script runs in its own shell separate from the
    ///      rung steps (RUNG11-PLAN.md:83) and the label is re-exported by hand there, so a forgotten
    ///      re-export is silent: it deploys for real, pulling real AUDIT and ETH from the deployer,
    ///      before the M-4 overwrite guard ever gets a chance to object to the record write. Require
    ///      the label to be SET. The one recognised way to mean the canonical instance ON PURPOSE is
    ///      the literal value "canonical" -- reported back here so callers can route to the TRUE
    ///      unlabeled paths themselves (InstanceAware's shared helpers would otherwise treat
    ///      "canonical" as an ordinary label suffix and look for a file, e.g.
    ///      deployments/84532-canonical.json, that does not exist).
    function _requireExplicitLabel() internal view returns (bool isCanonical) {
        string memory label = vm.envOr("DEPLOY_INSTANCE_LABEL", string(""));
        require(
            bytes(label).length > 0,
            "DEPLOY_INSTANCE_LABEL is required for DeployMembrane -- set a rung/instance label, or set it to \"canonical\" if you explicitly mean the live instance (M-6)"
        );
        isCanonical = keccak256(bytes(label)) == keccak256(bytes("canonical"));
    }

    function run() external {
        // M-6: fail fast on a missing label, before anything else resolves a path from it.
        bool targetsCanonical = _requireExplicitLabel();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 audSeed = _requiredUint("MEMBRANE_AUD_SEED");
        uint256 ethSeed = _requiredUint("MEMBRANE_ETH_SEED");
        uint256 feeBps = _optionalUint("MEMBRANE_FEE_BPS", 30);
        require(feeBps > 0 && feeBps < 1000, "MEMBRANE_FEE_BPS must be in (0,1000)");

        // M-2: the opening price (ratio of the two seeds) was compared to NOTHING -- the only
        // irreversible parameter with no bound. A transposed seed or a dropped digit passes every
        // OTHER guard (both non-empty, both parse, deployer affords both, constructor's != 0
        // satisfied, M-1's read-back satisfied by construction) and opens a mispriced pool with no
        // owner, no pause and no withdraw -- the only correction is a bot draining the wrong side.
        uint256 minPriceE18 = _requiredUint("MEMBRANE_MIN_PRICE_E18");
        uint256 maxPriceE18 = _requiredUint("MEMBRANE_MAX_PRICE_E18");
        require(minPriceE18 < maxPriceE18, "MEMBRANE_MIN_PRICE_E18 must be < MEMBRANE_MAX_PRICE_E18");

        // VD-23 (2026-08-22): the band's own sanity is checked BEFORE it is ever compared to a price,
        // so a malformed band is diagnosed as a malformed band and not as a bad price. A band set
        // carelessly wide is theatre -- it passes review as "a guard exists" while catching nothing.
        // Cap it at 2x: the mistakes M-2 exists for (a transposed seed, a dropped 1e3) are off by
        // orders of magnitude, not by 40%, so a factor-2 band loses no real coverage.
        require(
            minPriceE18 <= type(uint256).max / 2,
            "MEMBRANE_MIN_PRICE_E18 is too large to check the band-width bound without overflowing (M-2 VD-23)"
        );
        require(
            maxPriceE18 <= 2 * minPriceE18,
            "MEMBRANE_MIN_PRICE_E18/MEMBRANE_MAX_PRICE_E18 band is wider than 2x -- narrow it (M-2 VD-23): a band this wide refuses nothing real"
        );

        uint256 openingMidE18 = (ethSeed * 1e18) / audSeed;
        // VD-23: print the computed mid, in BOTH wei and human decimal terms, BEFORE the pass/fail
        // check below -- unconditionally, on every run, refusal or pass. This keeps the one virtue
        // the rejected "confirm the computed mid" form had (the operator actually sees the number)
        // without its vice (approving it at the exact moment of rubber-stamping a deploy).
        console2.log("opening mid ETH-per-AUDIT, e18 wei  ", openingMidE18);
        console2.log("opening mid ETH-per-AUDIT, decimal  ", _formatE18(openingMidE18));
        require(
            openingMidE18 >= minPriceE18 && openingMidE18 <= maxPriceE18,
            "opening price (ethSeed/audSeed) is outside [MEMBRANE_MIN_PRICE_E18, MEMBRANE_MAX_PRICE_E18] -- check for a transposed seed or a misplaced digit (M-2)"
        );

        // AUDIT token: explicit override wins, else read the instance record this label points at.
        address token;
        if (bytes(vm.envOr("CELL_TOKEN", string(""))).length > 0) {
            token = vm.envAddress("CELL_TOKEN");
        } else {
            // M-6: "canonical" means the TRUE unlabeled record, not InstanceAware's ordinary
            // "<chainid>-canonical.json" suffix -- resolve it locally rather than through the
            // inherited (unmodified) `_deploymentRecordPath()`.
            string memory recPath = targetsCanonical
                ? string.concat("deployments/", vm.toString(block.chainid), ".json")
                : _deploymentRecordPath();
            require(vm.exists(recPath), string.concat("no deployment record at ", recPath, " -- set CELL_TOKEN or DEPLOY_INSTANCE_LABEL"));
            // TWO RECORD SHAPES, both real -- READ which one this is, never assume (caught by the
            // mandated simulation, 2026-08-08, rung11). `DeployCell` writes a FLAT record; the rung
            // wrapper `deploy-dedicated-instance.ps1` step 8 then re-writes it NESTED as
            // { chainId, genesisAuditor, createdNote, freshBaseline, deployment: {...} }. The membrane
            // deploys AFTER that wrap by construction, so the flat path this script was written
            // against never exists when it actually runs -- and `parseJsonAddress` on a missing key
            // reverts with "must return exactly one JSON value", which names the cheatcode rather
            // than the cause. Nested first (the shape a completed rung HAS), flat as the fallback.
            string memory rec = vm.readFile(recPath);
            if (vm.keyExistsJson(rec, ".deployment.CellToken")) {
                token = vm.parseJsonAddress(rec, ".deployment.CellToken");
            } else {
                require(
                    vm.keyExistsJson(rec, ".CellToken"),
                    string.concat("neither .deployment.CellToken nor .CellToken found in ", recPath, " -- unrecognised deployment record shape")
                );
                token = vm.parseJsonAddress(rec, ".CellToken");
            }
        }
        require(token != address(0), "resolved CellToken is the zero address");
        require(token.code.length > 0, "resolved CellToken has NO CODE on this chain -- wrong instance or wrong chain");

        // Pre-flight the seeds against reality, so a failure names its cause instead of reverting
        // inside the constructor's transferFrom with a bare ERC20 error.
        uint256 audBal = IAuditTokenDeploy(token).balanceOf(deployer);
        require(audBal >= audSeed, "deployer AUDIT balance < MEMBRANE_AUD_SEED");
        require(deployer.balance >= ethSeed, "deployer ETH balance < MEMBRANE_ETH_SEED");

        // The constructor pulls AUD_SEED via transferFrom, so the approval must land BEFORE the CREATE,
        // which means predicting the CREATE address. The nonce is read INSIDE the broadcast, immediately
        // before the approve, so it reflects the state forge will actually broadcast from -- reading it
        // earlier would guess across a boundary. For an EOA the approve is its own transaction and
        // consumes `nApprove`, so the CREATE lands at `nApprove + 1`.
        //
        // FAILURE MODE, stated rather than assumed: if the prediction is ever wrong, the approval lands
        // on some other address and the constructor's transferFrom reverts for want of allowance -- so
        // the deploy HALTS instead of producing a live-but-unfunded pool. The stray approval is to a
        // computed CREATE address with no known controller. The assertion below is belt-and-braces for
        // the case where a revert somehow does not fire. VERIFY BY SIMULATION FIRST (forge script
        // WITHOUT --broadcast): the simulation executes this whole path, including the prediction.
        vm.startBroadcast(deployerKey);
        uint64 nApprove = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, uint256(nApprove) + 1);
        // M-7: log BEFORE the approve, not after. `predicted` is never logged anywhere else in this
        // script (the console2.log block below prints membrane/token/fees/reserves/record path, all
        // AFTER a successful CREATE) -- so if the deploy aborts between the approve landing and the
        // CREATE (the runbook uses --slow, RUNG11-PLAN.md:89, and D7.6 records the two txs a block
        // apart on the real chain, so this window is real), nothing tells the operator which address
        // is still sitting on a standing audSeed allowance and needs revoking.
        console2.log("predicted membrane (revoke AUDIT allowance here if the deploy aborts before CREATE)", predicted);
        require(IAuditTokenDeploy(token).approve(predicted, audSeed), "AUDIT approve failed");
        AuditEthMembrane membrane = new AuditEthMembrane{value: ethSeed}(token, uint16(feeBps), audSeed);
        vm.stopBroadcast();

        require(address(membrane) == predicted, "CREATE address != predicted -- the approval targeted the wrong address; INVESTIGATE before reusing this deployer");

        // Read the opening state back FROM THE CONTRACT, never from our own inputs: the record must
        // report what the chain holds, not what we asked for (the echo family, DEPLOY-FINDINGS F7).
        (uint256 audR, uint256 ethR) = membrane.getReserves();
        require(audR == audSeed && ethR == ethSeed, "opening reserves do not match the seeds");

        string memory obj = "membrane";
        string memory json = vm.serializeUint(obj, "chainId", block.chainid);
        json = vm.serializeString(obj, "instanceLabel", _instanceLabel());
        json = vm.serializeAddress(obj, "AuditEthMembrane", address(membrane));
        json = vm.serializeAddress(obj, "CellToken", token);
        json = vm.serializeAddress(obj, "deployer", deployer);
        json = vm.serializeUint(obj, "feeBps", feeBps);
        json = vm.serializeUint(obj, "openingAudReserve", audR);
        json = vm.serializeUint(obj, "openingEthReserve", ethR);
        json = vm.serializeUint(obj, "openingMidPriceEthPerAudE18", membrane.midPriceEthPerAudE18());
        json = vm.serializeString(obj, "sourceGitHead", vm.envOr("SOURCE_GIT_HEAD", string("unknown")));
        json = vm.serializeString(
            obj,
            "note",
            "FC-17 membrane (DEC-38): doorless AUDIT<->ETH window. No owner, no withdraw, no feed. Seeded ONCE here; nobody touches it after. The cell neither imports nor reads this contract."
        );
        // MARKER (defense 2): the path already separates the two, but a file that travels -- pasted
        // into a findings entry, copied to another machine -- loses its path. Say it INSIDE.
        if (!_isBroadcast()) {
            json = vm.serializeBool(obj, "simulation", true);
            json = vm.serializeString(
                obj,
                "simulationNote",
                "forge script dry-run only - this membrane was NEVER deployed; the address is a CREATE prediction and the reserves are simulated. The real record, if one exists, is deployments/membrane-{chainId}[-{label}].json"
            );
        }

        string memory recordPath = _membraneRecordPath();

        // M-5, CORRECTED 2026-09-05 (bug_407). The diagnosis below was right and the guard under it
        // could not fire.
        //
        // THE DIAGNOSIS, which still stands: `forge script --broadcast` executes the script TWICE. The
        // read-backs above ran against SIMULATED state and this record is written during that same
        // execution. If the SEND leg fails afterwards, nothing here notices -- the record exists, names
        // an address with no code, reports reserves for a pool that was never created, and carries no
        // simulation marker, because `_isBroadcast()` is true for the whole invocation and cannot tell
        // "broadcast requested" from "broadcast landed".
        //
        // WHY THE OLD GUARD WAS INERT: it tested `address(membrane).code.length > 0` in the frame where
        // `new Membrane(...)` had just run. The constructor executes in the script's LOCAL EVM in both
        // legs, so that address always has code by the time this line is reached, whether or not any
        // transaction is ever mined. The guard asserted that the constructor ran -- which the next line
        // of the script already proves -- and read as if it asserted that the deploy landed. An inert
        // check under a correct diagnosis is worse than no check: it closes the question.
        //
        // WHAT REPLACES IT: nothing inside a forge script can observe whether the send landed -- that
        // fact does not exist yet at this point in the process, which is precisely why the old guard
        // could not be written correctly. So the record now says so ITSELF, and says it in the file
        // rather than in a runbook step someone has to remember. `broadcastVerified: false` ships on
        // every broadcast record and is flipped only by an out-of-process read against the RPC.
        // A record that admits what it has not proven is honest; a guard that cannot fire is not.
        if (_isBroadcast()) {
            json = vm.serializeBool(obj, "broadcastVerified", false);
            json = vm.serializeString(
                obj,
                "broadcastVerifiedNote",
                "WRITTEN DURING THE BROADCAST INVOCATION, BEFORE THE SEND IS KNOWN TO HAVE LANDED. The address here is what the local EVM constructed; nothing in this process can see whether the transaction was mined. Verify out-of-process before trusting it: cast code <AuditEthMembrane> --rpc-url <rpc> must return non-empty, and the reserves must be re-read from chain. Then set broadcastVerified true by hand, naming the block."
            );
        }

        // OVERWRITE GUARD (defense 3, mirroring DeployCell's): refuse to replace an existing record
        // that names a DIFFERENT membrane. The membrane is seeded once and never touched, so its
        // record is irreplaceable evidence -- a second deploy against the same label is far more
        // likely to be a mistake than an intention. MEMBRANE_OVERWRITE accepts "1" or "true"
        // (envOr(bool) parses ONLY "true", which is the bug_005 family this repo already paid for).
        //
        // M-6b: this used to be gated on `_isBroadcast()`, so a dry-run could silently clobber a
        // PRIOR dry-run's own record -- exactly the evidence loss the dry-run path split (defense 2,
        // `_membraneRecordPath` above) exists to prevent, and the same "gated on broadcast only"
        // shape that left DeployCell's dry-run leg toothless. `recordPath` already resolves per-mode
        // (.json vs .dryrun.json), so dropping the `_isBroadcast()` gate here makes the guard protect
        // EACH mode's own record, never the other mode's.
        //
        // M-4 adds the `existing.code.length == 0` escape below, and it is kept SCOPED TO BROADCAST
        // ONLY -- deliberately, and this is the conclusion, not an assumption: in dry-run, `existing`
        // is always some earlier simulation's CREATE *prediction*. It was never really deployed
        // anywhere, so it reads code.length == 0 on a fresh fork/state REGARDLESS of whether that
        // prior dry-run was a genuine, still-good simulation or a mistake -- extending the escape to
        // dry-run would make the M-6b fix toothless again, immediately after landing it. In broadcast
        // mode `existing` names a REAL prior deployment attempt, so code.length == 0 there really
        // does mean "that address never got deployed to" -- the aborted-record case M-4 targets
        // (DeployCell.s.sol:325-328's own escape, minus its two-phase-library clause, which does not
        // apply here: the membrane links no libraries).
        string memory overwriteRaw = vm.envOr("MEMBRANE_OVERWRITE", string(""));
        bool overwriteForced = keccak256(bytes(overwriteRaw)) == keccak256(bytes("1"))
            || keccak256(bytes(overwriteRaw)) == keccak256(bytes("true"));
        if (vm.exists(recordPath) && !overwriteForced) {
            address existing = vm.parseJsonAddress(vm.readFile(recordPath), ".AuditEthMembrane");
            bool staleAbortedRecord = _isBroadcast() && existing.code.length == 0;
            require(
                existing == address(membrane) || staleAbortedRecord,
                "DeployMembrane: refusing to overwrite an existing membrane record for a DIFFERENT address -- use a new DEPLOY_INSTANCE_LABEL, or set MEMBRANE_OVERWRITE=1 if you mean it"
            );
        }
        vm.writeJson(json, recordPath);

        console2.log("membrane      ", address(membrane));
        console2.log("token         ", token);
        console2.log("feeBps        ", feeBps);
        console2.log("aud reserve   ", audR);
        console2.log("eth reserve   ", ethR);
        // Print the path we ACTUALLY wrote, not a recomputation of it (F7's echo family: report the
        // measurement, never a second guess at it).
        console2.log("record        ", recordPath);
        if (_isBroadcast()) {
            // bug_407: the record is written before the send is known to have landed, so the run does
            // not end at the write -- it ends when someone reads the chain. Printed here rather than
            // left to the runbook, because the guard that used to stand in for this could not fire.
            console2.log("!! broadcastVerified=false -- this record is NOT yet evidence of a deploy.");
            console2.log("!! verify: cast code <membrane above> --rpc-url <rpc>   (must be non-empty)");
        }
    }
}
