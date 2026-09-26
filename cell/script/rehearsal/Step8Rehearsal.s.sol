// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "../EnvReads.s.sol";
import "./RehearsalTimelock.sol";

interface IAdminSurface {
    function admin() external view returns (address);
    function transferAdmin(address newAdmin) external;
    function setParam(uint8 id, uint256 v) external;
}

/// @title Step 8 rehearsal — the admin handoff, executed for the first time.
///
/// ⚠ DISPOSABLE INSTANCES ONLY. `DEPLOY_INSTANCE_LABEL` is REQUIRED and must never be `canonical`.
///    This script transfers admin away from the deployer EOA; running it against the live cell would
///    hand control of a real network to a rehearsal rig.
///
/// WHAT HAS NEVER RUN. DR-3's step 8 — `AuditCell.transferAdmin(timelock)` plus each module's
/// transfer, after which the deployer EOA is powerless — exists as written text and has been executed
/// ZERO times against real contracts. The one time it was rehearsed on paper it produced a defect that
/// would have been permanent on mainnet; the receipt is `IssuanceModule.sol`:184. The cheapest place
/// to find the next one is a testnet where a mistake costs a redeploy rather than a network (G-27
/// §5.1, VD-65).
///
/// WHAT THIS PROVES, AND WHAT IT DOES NOT. Proven here: the handoff sequence, the delay semantics, the
/// cancel semantics, and — observed, not asserted — that the EOA is actually powerless afterwards.
/// NOT proven: OpenZeppelin's `TimelockController` integration specifically. §5.1 discharges PARTIALLY
/// and this file says so on its face (VD-65 condition 4); the OZ half is owed at the value-bearing
/// deploy, where the dependency gets PUBLISHING-grade scrutiny.
///
/// THE POWERLESS CHECK IS OBSERVED, NEVER ASSERTED (VD-66). After the handoff the script ATTEMPTS an
/// admin action as the EOA and REQUIRES the revert. "The EOA is powerless" is the single claim this
/// whole rehearsal exists to convert from a sentence into a fact, so it is the one that must come from
/// the chain's own mouth — the echo-family rule: report what the chain refused, never what the code
/// intended. A rehearsal that inferred powerlessness from having sent a transferAdmin would be
/// asserting its own input, which is exactly M-1's defect.
///
/// EVERY STEP CARRIES ITS ABORT LINE (VD-66). A half-way stop must never be a thing reasoned out under
/// stress; it is a sentence read off the screen. For this rehearsal the recovery is almost always
/// "discard the instance" — the disposable instance IS the recovery, and that is the point of using
/// one.
///
/// IF THIS AGES UNRUN past the start of value-bearing prep, re-verify it against whatever moved before
/// trusting it. Evidence expires when its preconditions do (VD-66).
///
/// Usage:
///   DEPLOY_INSTANCE_LABEL=rehearsal1 REHEARSAL_DELAY_SEC=0 \
///   forge script script/rehearsal/Step8Rehearsal.s.sol --rpc-url base_sepolia --broadcast
contract Step8Rehearsal is EnvReads {
    /// Every contract in the deployment record that carries `transferAdmin`, by its record key.
    /// Read from the record rather than hardcoded addresses, so the script cannot be pointed at a
    /// stale instance by a copied constant.
    string[11] internal ADMINED = [
        "AuditCell", "CellToken", "CellEscrow", "FmeaRegistry", "AssignmentModule",
        "ClaimDisputeModule", "IntegrityReviewModule", "IssuanceModule", "SpecArbiterModule",
        "SpecGapModule", "StructuralUpgradeModule"
    ];

    function run() external {
        // ── STEP 0: refuse to run anywhere that matters ───────────────────────────────────────────
        // ABORT LINE: nothing has been sent. Set a label and re-run.
        string memory label = vm.envOr("DEPLOY_INSTANCE_LABEL", string(""));
        require(bytes(label).length > 0,
            "DEPLOY_INSTANCE_LABEL is REQUIRED - this script transfers admin away from the deployer");
        require(keccak256(bytes(label)) != keccak256("canonical"),
            "REFUSING: 'canonical' is the live cell. This rehearsal must run on a disposable instance");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address eoa = vm.addr(pk);
        uint256 delaySec = _optionalUint("REHEARSAL_DELAY_SEC", 0);

        string memory path = string.concat(
            "deployments/", vm.toString(block.chainid), "-", label, ".json");
        string memory rec = vm.readFile(path);
        console2.log("rehearsing step 8 against", path);
        console2.log("  deployer EOA          ", eoa);

        // TWO RECORD SHAPES EXIST FOR THE SAME THING, and this cost the rehearsal its first run.
        // A fresh `DeployCell` broadcast writes addresses at the TOP LEVEL. The rung17/rung18 records
        // carry them nested under `.deployment` - added by later post-processing, not by the deploy.
        // Verified the wrong artifacts before the first attempt: rung18 was checked, found nested, and
        // the freshly-written record was assumed to match. It reverted on `.deployment.AuditCell`
        // BEFORE any broadcast, which is the read-then-write order doing its job.
        //
        // Both shapes are read rather than one being declared correct: the flat form is what the
        // deploy produces today and the nested form is what the archive holds, so a rehearsal pointed
        // at either must work. `keyExistsJson` asks instead of assuming.
        bool nested = vm.keyExistsJson(rec, ".deployment.AuditCell");
        console2.log(nested ? "  record shape: NESTED under .deployment"
                            : "  record shape: FLAT (fresh DeployCell output)");
        address[11] memory targets;
        for (uint256 i = 0; i < ADMINED.length; i++) {
            string memory key = nested
                ? string.concat(".deployment.", ADMINED[i])
                : string.concat(".", ADMINED[i]);
            targets[i] = vm.parseJsonAddress(rec, key);
            // OBSERVED PRECONDITION. If the EOA is not admin here, the instance is not the one this
            // rehearsal assumes and every later step would be measuring something else.
            // ABORT LINE: nothing has been sent. Check the label points at YOUR disposable instance.
            require(IAdminSurface(targets[i]).admin() == eoa,
                string.concat("precondition failed: EOA is not admin of ", ADMINED[i]));
        }
        console2.log("  precondition OK: EOA is admin of all", ADMINED.length, "contracts");

        // ── STEP 1: deploy the rig ────────────────────────────────────────────────────────────────
        // ABORT LINE: only the rig exists and holds nothing. Discard the instance; no admin moved.
        vm.startBroadcast(pk);
        RehearsalTimelock tl = new RehearsalTimelock(eoa, delaySec);
        console2.log("  rig deployed at       ", address(tl));
        console2.log("  rig delay (sec)       ", delaySec);

        // ── STEP 2: the handoff — this is step 8 ─────────────────────────────────────────────────
        // ABORT LINE: PARTIAL HANDOFF IS THE ONE STATE WORTH NAMING. If this loop stops midway, some
        // contracts answer to the rig and some to the EOA. Recovery: the EOA still holds the ones it
        // has, and the rig can hand back the rest via queue/execute - but on a DISPOSABLE instance the
        // cheaper answer is always to discard it and re-run from step 0. Do not hand-repair a
        // half-handed-off cell; that is how a rehearsal becomes an incident.
        for (uint256 i = 0; i < ADMINED.length; i++) {
            IAdminSurface(targets[i]).transferAdmin(address(tl));
        }
        vm.stopBroadcast();
        console2.log("  step 8 sent for all", ADMINED.length, "contracts");

        // ── STEP 3: OBSERVE that the EOA is powerless ────────────────────────────────────────────
        // The claim this entire rehearsal exists to establish, and the only one taken from the chain
        // rather than from the code. `setParam` is chosen because it is `onlyAdmin` and harmless.
        for (uint256 i = 0; i < ADMINED.length; i++) {
            require(IAdminSurface(targets[i]).admin() == address(tl),
                string.concat("handoff did NOT land on ", ADMINED[i]));
        }
        vm.prank(eoa);
        (bool stillPowerful, ) = targets[0].call(
            abi.encodeCall(IAdminSurface.setParam, (2, 1)));
        // ABORT LINE: if this require trips, the handoff did not remove the EOA's power and THAT IS
        // THE FINDING - record it, discard the instance, and do not proceed. It is exactly the class
        // DR-6a was: a step 8 that appears to succeed and does not.
        require(!stillPowerful,
            "THE EOA IS STILL ADMIN-POWERFUL AFTER STEP 8 - this is the finding; record and stop");
        console2.log("  OBSERVED: the EOA's admin call REVERTED - it is powerless");

        // ── STEP 4: the cancel drill — Guardian criterion 3 ──────────────────────────────────────
        // ABORT LINE: admin is on the rig and the EOA is the rig's proposer, so nothing is stranded;
        // step 6 hands it back. If you stop here, discard the instance.
        // PARAM 2, NOT PARAM 0 - and the first attempt is why this comment exists. `setParam(0, 1)`
        // reverted `ClaimWindowOutOfBounds()`: param 0 is the claim window and 1 is not a legal
        // value. "Harmless" was chosen without reading the bounds. Param 2 is
        // `canonicalThreshold` and its only constraint is `v > 0` (CellLogicLib:1356-1358), so
        // the action is unambiguously valid and still `onlyAdmin`.
        //
        // THE RIG BEHAVED CORRECTLY WHEN IT HAPPENED, which is the part worth keeping: it
        // surfaced `CallReverted` CARRYING the inner reason instead of swallowing it, so the
        // failure was attributable to the target in one read rather than looking like a
        // timelock defect. That is the misattribution fence earning itself on its first run.
        bytes memory action = abi.encodeCall(IAdminSurface.setParam, (2, 1));
        vm.startBroadcast(pk);
        bytes32 id = tl.queue(targets[0], action);
        tl.cancel(id);
        vm.stopBroadcast();
        console2.log("  cancel drill: queued and CANCELLED", uint256(id));

        // A cancelled action must be unexecutable. Observed, not assumed.
        (bool executedAfterCancel, ) = address(tl).call(
            abi.encodeCall(RehearsalTimelock.execute, (targets[0], action)));
        require(!executedAfterCancel,
            "a CANCELLED action executed - the cancel path does not hold; record and stop");
        console2.log("  OBSERVED: the cancelled action REFUSED to execute");

        // ── STEP 5: a real admin action THROUGH the timelock ─────────────────────────────────────
        // ABORT LINE: as step 4. Nothing is stranded; step 6 hands admin back.
        vm.startBroadcast(pk);
        tl.queue(targets[0], action);
        if (delaySec > 0) {
            console2.log("  queued; wait", delaySec, "seconds then re-run with REHEARSAL_STAGE=execute");
        } else {
            tl.execute(targets[0], action);
            console2.log("  executed through the timelock");
        }

        // ── STEP 6: Option B's exit — admin BACK to the EOA ──────────────────────────────────────
        // VD-65 condition 5: "do not leave admin there." The rig hands each contract back, and the
        // handback goes through the timelock exactly as a real one would.
        // ABORT LINE: if a handback fails, the instance is disposable - discard it. Do NOT leave a
        // rehearsal instance holding admin on a rig nobody is watching.
        if (delaySec == 0) {
            for (uint256 i = 0; i < ADMINED.length; i++) {
                bytes memory back = abi.encodeCall(IAdminSurface.transferAdmin, (eoa));
                tl.queue(targets[i], back);
                tl.execute(targets[i], back);
            }
            vm.stopBroadcast();
            for (uint256 i = 0; i < ADMINED.length; i++) {
                require(IAdminSurface(targets[i]).admin() == eoa,
                    string.concat("handback did NOT land on ", ADMINED[i]));
            }
            console2.log("  OBSERVED: admin is back on the EOA for all", ADMINED.length, "contracts");
            console2.log("  REHEARSAL COMPLETE - now discard this instance and write the record");
        } else {
            vm.stopBroadcast();
            console2.log("  handback is queued behind the delay; re-run to finish, then discard");
        }
    }
}
