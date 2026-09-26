// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./EnvCell.sol";
import "forge-std/Script.sol";
import "./InstanceAware.s.sol";
import {CellParamIds} from "../contracts/CellParamIds.sol";

// Minimal interfaces rather than importing the contracts: the script needs five selectors, and importing
// IssuanceModule.sol / AuditCell.sol pulls their whole via-IR compilation into every edit of this file.
interface ILockWiringIssuance {
    function wiringLocked() external view returns (bool);
    function cell() external view returns (address);
    function token() external view returns (address);
    function founderShareBps() external view returns (uint256);
    function lockWiring() external;
}

interface ILockWiringCell {
    function paramLocked(uint8 id) external view returns (bool);
    function lockParam(uint8 id) external;
}

interface ILockWiringModule {
    function cell() external view returns (address);
}

/// The six satellites whose `wire()` stayed open after §2b (bug_004 of the 2026-09-15 second-family review;
/// the review named four, and a chain read found SpecArbiter and StructuralUpgrade unlocked as well).
interface ILockWiringSatellite {
    function wiringLocked() external view returns (bool);
    function lockWiring() external;
}

interface ILockWiringPeers {
    function fmeaRegistry() external view returns (address);      // ClaimDisputeModule
    function claimModule() external view returns (address);       // FmeaRegistry
    function specArbiterModule() external view returns (address); // IntegrityReviewModule
    function issuanceModule() external view returns (address);    // StructuralUpgradeModule
}

/// @dev Post-wiring cutover step §2b (G-27 row 7; VD-170(c)). Arms TWO locks, and runs a GATE first.
///
///      1. `IssuanceModule.lockWiring()` - freezes wire() / setStructuralModule and arms the founder-share
///         lower-only lock (setFounderShareBps may only DECREASE after this). This is all §2b used to arm,
///         while the runbook said it "freezes module wiring".
///      2. `AuditCell.lockParam(DISPUTE_MODULES)` - freezes `setDisputeModule` (AuditCell.sol:686), whose
///         five pointers stayed re-pointable by the admin after §2b until VD-170(c). Nothing in the deploy
///         path called it; only ParamLockCell.t.sol did.
///
///      THE GATE, and why it exists. Locking a mis-wire is permanent, and §2's read-backs CANNOT confirm the
///      five dispute modules: AuditCell exposes no getter for them (VerifyWiring.s.sol:33). So before any
///      lock, this script reads the chain itself: every `DisputeModuleSet(uint8 indexed, address indexed)`
///      the cell ever emitted, from its deploy block to head, and requires the LAST one per slot 0-4 to
///      equal the deployment record, non-zero, with code, and pointing back at this cell via its own
///      `cell()`. Any failure - a missing slot, a zero, a mismatch, an RPC error on any window - REFUSES.
///      A partial read never locks.
///
///      Two entry points, split so the gate can be proven on the live cell without a key (VD-170(c)):
///        forge script script/LockWiring.s.sol:LockWiring --sig "check()" --rpc-url <url>   read-only, no key
///        forge script script/LockWiring.s.sol:LockWiring --rpc-url <url> --broadcast --slow gate + both locks
///      Both locks are idempotent, so a run interrupted between them can simply be re-run.
///
///      3. (2026-09-15, bug_004 of the second-family review) the SIX satellites' own `lockWiring()` -
///         ClaimDispute, SpecGap, IntegrityReview, FmeaRegistry, SpecArbiter, StructuralUpgrade. Read on the
///         canonical cell that day: all six `wiringLocked() == false`, so after §2b the admin could still re-point
///         each satellite's `cell` and peers. A SECOND GATE runs first (`_verifySatellites`): every pointer those
///         locks freeze - each `cell()`, ClaimDispute<->Fmea, Integrity->SpecArbiter, Structural->Issuance - must
///         equal the record, because several `lockWiring()` preconditions check `cell` alone. Each lock idempotent,
///         each read back. On a cell where §2b already ran, re-running this arms only the six.
///
///      Env: PRIVATE_KEY (deployer/admin; run() only). Optional: AUDIT_CELL, ISSUANCE_MODULE,
///      DEPLOY_INSTANCE_LABEL. Run AFTER the §2 read-backs pass.
contract LockWiring is InstanceAware {
    /// eth_getLogs block-range cap on the public Base Sepolia endpoint, measured 2026-09-12:
    /// "eth_getLogs is limited to a 10,000 range" (HTTP 413, -32614). Windows never exceed it.
    uint256 internal constant LOG_WINDOW = 10_000;
    bytes32 internal constant DISPUTE_MODULE_SET = keccak256("DisputeModuleSet(uint8,address)");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address cell = _cellAddress();
        ILockWiringIssuance issuance = ILockWiringIssuance(_issuanceAddress());

        require(issuance.cell() != address(0) && issuance.token() != address(0), "wiring incomplete");
        require(issuance.cell() == cell, "issuance.cell() is not the recorded AuditCell - wrong instance");

        _verifyDisputeModules(cell); // THE GATE: reverts before anything is broadcast
        Satellites memory sats = _recordedSatellites();
        require(sats.issuance == address(issuance), "the record's IssuanceModule is not the issuance module being locked");
        _verifySatellites(cell, sats); // THE SATELLITE GATE: also before anything is broadcast

        vm.startBroadcast(pk);
        if (!issuance.wiringLocked()) {
            issuance.lockWiring();
        }
        if (!ILockWiringCell(cell).paramLocked(CellParamIds.DISPUTE_MODULES)) {
            ILockWiringCell(cell).lockParam(CellParamIds.DISPUTE_MODULES);
        }
        _lockSatellites(sats);
        vm.stopBroadcast();

        require(issuance.wiringLocked(), "read-back: issuance.wiringLocked() is still false");
        require(ILockWiringCell(cell).paramLocked(CellParamIds.DISPUTE_MODULES),
                "read-back: cell.paramLocked(DISPUTE_MODULES) is still false");
        _requireSatellitesLocked(sats);

        console2.log("=== lockWiring done - issuance, DISPUTE_MODULES and six satellite wiring locks armed ===");
        console2.log("issuance.wiringLocked", issuance.wiringLocked());
        console2.log("cell.paramLocked(6) DISPUTE_MODULES", ILockWiringCell(cell).paramLocked(CellParamIds.DISPUTE_MODULES));
        console2.log("founderShareBps (now lower-only)", issuance.founderShareBps());
    }

    /// Read-only: runs the gate and nothing else. No key, no broadcast.
    function check() external {
        address cell = _cellAddress();
        _verifyDisputeModules(cell);
        _verifySatellites(cell, _recordedSatellites());
        console2.log("=== GATES PASSED - the five dispute modules and every satellite pointer match the record; nothing was locked ===");
    }

    function _verifyDisputeModules(address cell) internal {
        require(cell.code.length > 0, "GATE REFUSED: no code at the AuditCell address");
        string memory json = vm.readFile(_deploymentRecordPath());
        string[5] memory keys = [".ClaimDisputeModule", ".SpecGapModule", ".SpecArbiterModule",
                                 ".IntegrityReviewModule", ".StructuralUpgradeModule"];
        address[5] memory recorded;
        for (uint256 w = 0; w < 5; w++) {
            recorded[w] = vm.parseJsonAddress(json, keys[w]);
        }

        uint256 head = block.number;
        uint256 start = _deployBlock(cell, head);
        address[5] memory lastSet;
        bool[5] memory seen;
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = DISPUTE_MODULE_SET;
        uint256 windows = 0;
        uint256 events = 0;
        for (uint256 from = start; from <= head; from += LOG_WINDOW) {
            uint256 to = from + LOG_WINDOW - 1;
            if (to > head) to = head;
            try vm.eth_getLogs(from, to, cell, topics) returns (VmSafe.EthGetLogs[] memory logs) {
                for (uint256 i = 0; i < logs.length; i++) {
                    require(logs[i].emitter == cell && logs[i].topics.length == 3
                            && logs[i].topics[0] == DISPUTE_MODULE_SET,
                            "GATE REFUSED: a malformed DisputeModuleSet log");
                    uint256 slot = uint256(logs[i].topics[1]);
                    require(slot < 5, "GATE REFUSED: DisputeModuleSet for a slot outside 0-4");
                    lastSet[slot] = address(uint160(uint256(logs[i].topics[2])));
                    seen[slot] = true;
                    events++;
                }
            } catch {
                revert(string.concat("GATE REFUSED: eth_getLogs failed for blocks ", vm.toString(from), "..",
                                     vm.toString(to), " - a partial read never locks"));
            }
            windows++;
        }
        console2.log("deploy block (derived from eth_getCode, never typed)", start);
        console2.log("head block", head);
        console2.log("log windows scanned (<=10,000 blocks each)", windows);
        console2.log("DisputeModuleSet events read", events);

        // Print all five pairs BEFORE refusing, so the operator sees every slot at once, not the first failure.
        bool ok = true;
        for (uint256 w = 0; w < 5; w++) {
            bool slotOk = seen[w] && lastSet[w] != address(0) && lastSet[w] == recorded[w];
            if (slotOk) {
                slotOk = recorded[w].code.length > 0 && _moduleCell(recorded[w]) == cell;
            }
            console2.log(string.concat("slot ", vm.toString(w), " ", keys[w], slotOk ? "  OK" : "  MISMATCH"));
            console2.log("   record        ", recorded[w]);
            console2.log("   last event    ", lastSet[w]);
            if (!slotOk) ok = false;
        }
        require(ok, "GATE REFUSED: a dispute-module pointer does not match the record (see the five pairs above)");
    }

    /// `module.cell()` via staticcall, so a module without the getter reads as address(0) and FAILS the
    /// slot instead of reverting with an unhelpful message. All five modules expose `address public cell`.
    function _moduleCell(address module) internal view returns (address) {
        (bool success, bytes memory data) = module.staticcall(abi.encodeCall(ILockWiringModule.cell, ()));
        if (!success || data.length != 32) return address(0);
        return abi.decode(data, (address));
    }

    /// The block the cell's code first appears in, by binary search on eth_getCode. Derived from the chain
    /// rather than typed or read from a receipt: vm.rpc returns a receipt as a chain-shaped ABI tuple, and
    /// Base adds L1 fields that move its layout. Code presence is monotonic here - the cell cannot self-destruct.
    function _deployBlock(address target, uint256 head) internal returns (uint256) {
        require(_hasCodeAt(target, head), "GATE REFUSED: eth_getCode sees no code at the cell at head");
        if (_hasCodeAt(target, 0)) return 0;
        uint256 lo = 0;
        uint256 hi = head;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_hasCodeAt(target, mid)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _hasCodeAt(address target, uint256 blockNo) internal returns (bool) {
        string memory params = string.concat("[\"", vm.toString(target), "\",\"", _hexQuantity(blockNo), "\"]");
        try vm.rpc("eth_getCode", params) returns (bytes memory code) {
            return code.length > 0;
        } catch {
            revert(string.concat("GATE REFUSED: eth_getCode failed at block ", vm.toString(blockNo)));
        }
    }

    function _hexQuantity(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        bytes memory digits = "0123456789abcdef";
        uint256 len = 0;
        for (uint256 t = v; t != 0; t >>= 4) len++;
        bytes memory out = new bytes(len + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < len; i++) {
            out[len + 1 - i] = digits[v & 0xf];
            v >>= 4;
        }
        return string(out);
    }

    struct Satellites {
        address claimDispute;
        address specGap;
        address integrityReview;
        address fmeaRegistry;
        address specArbiter;
        address structuralUpgrade;
        address issuance; // a PEER only - issuance is locked above, never here
    }

    function _recordedSatellites() internal view returns (Satellites memory s) {
        string memory json = vm.readFile(_deploymentRecordPath());
        s.claimDispute = vm.parseJsonAddress(json, ".ClaimDisputeModule");
        s.specGap = vm.parseJsonAddress(json, ".SpecGapModule");
        s.integrityReview = vm.parseJsonAddress(json, ".IntegrityReviewModule");
        s.fmeaRegistry = vm.parseJsonAddress(json, ".FmeaRegistry");
        s.specArbiter = vm.parseJsonAddress(json, ".SpecArbiterModule");
        s.structuralUpgrade = vm.parseJsonAddress(json, ".StructuralUpgradeModule");
        s.issuance = vm.parseJsonAddress(json, ".IssuanceModule");
    }

    /// THE SATELLITE GATE. Several `lockWiring()` preconditions check `cell` alone while `wire()` also sets a peer,
    /// and a lock is permanent - so every pointer each lock freezes is read and compared BEFORE anything is locked.
    /// Every pair is printed first; any mismatch, zero or missing code REFUSES.
    function _verifySatellites(address cell, Satellites memory s) internal view {
        bool ok = true;
        ok = _pair("ClaimDisputeModule.cell", ILockWiringModule(s.claimDispute).cell(), cell) && ok;
        ok = _pair("ClaimDisputeModule.fmeaRegistry", ILockWiringPeers(s.claimDispute).fmeaRegistry(), s.fmeaRegistry) && ok;
        ok = _pair("FmeaRegistry.claimModule", ILockWiringPeers(s.fmeaRegistry).claimModule(), s.claimDispute) && ok;
        ok = _pair("SpecGapModule.cell", ILockWiringModule(s.specGap).cell(), cell) && ok;
        ok = _pair("SpecArbiterModule.cell", ILockWiringModule(s.specArbiter).cell(), cell) && ok;
        ok = _pair("IntegrityReviewModule.cell", ILockWiringModule(s.integrityReview).cell(), cell) && ok;
        ok = _pair("IntegrityReviewModule.specArbiterModule", ILockWiringPeers(s.integrityReview).specArbiterModule(), s.specArbiter) && ok;
        ok = _pair("StructuralUpgradeModule.cell", ILockWiringModule(s.structuralUpgrade).cell(), cell) && ok;
        ok = _pair("StructuralUpgradeModule.issuanceModule", ILockWiringPeers(s.structuralUpgrade).issuanceModule(), s.issuance) && ok;
        require(ok, "GATE REFUSED: a satellite wiring pointer does not match the record (see the pairs above)");
    }

    function _pair(string memory what, address onChain, address expected) internal view returns (bool good) {
        good = onChain != address(0) && onChain == expected && expected.code.length > 0;
        console2.log(string.concat(what, good ? "  OK" : "  MISMATCH"));
        if (!good) {
            console2.log("   on chain      ", onChain);
            console2.log("   expected      ", expected);
        }
    }

    /// Arms each satellite's wiring lock, each skipped if already armed, so an interrupted run re-runs cleanly.
    function _lockSatellites(Satellites memory s) internal {
        address[6] memory sats =
            [s.claimDispute, s.specGap, s.integrityReview, s.fmeaRegistry, s.specArbiter, s.structuralUpgrade];
        for (uint256 i = 0; i < 6; i++) {
            if (!ILockWiringSatellite(sats[i]).wiringLocked()) {
                ILockWiringSatellite(sats[i]).lockWiring();
            }
        }
    }

    function _requireSatellitesLocked(Satellites memory s) internal view {
        require(ILockWiringSatellite(s.claimDispute).wiringLocked(), "read-back: ClaimDisputeModule.wiringLocked() is false");
        require(ILockWiringSatellite(s.specGap).wiringLocked(), "read-back: SpecGapModule.wiringLocked() is false");
        require(ILockWiringSatellite(s.integrityReview).wiringLocked(), "read-back: IntegrityReviewModule.wiringLocked() is false");
        require(ILockWiringSatellite(s.fmeaRegistry).wiringLocked(), "read-back: FmeaRegistry.wiringLocked() is false");
        require(ILockWiringSatellite(s.specArbiter).wiringLocked(), "read-back: SpecArbiterModule.wiringLocked() is false");
        require(ILockWiringSatellite(s.structuralUpgrade).wiringLocked(), "read-back: StructuralUpgradeModule.wiringLocked() is false");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return EnvCell.agreeing(vm.envAddress("AUDIT_CELL"), _deploymentRecordPath());
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
    }

    function _issuanceAddress() internal view returns (address) {
        if (vm.envExists("ISSUANCE_MODULE")) {
            return EnvCell.agreeingAt(vm.envAddress("ISSUANCE_MODULE"), _deploymentRecordPath(), ".IssuanceModule", "ISSUANCE_MODULE");
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".IssuanceModule");
    }
}
