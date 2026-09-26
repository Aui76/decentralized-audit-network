// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/FmeaRegistry.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/IssuanceModule.sol";
import "../contracts/SpecArbiterModule.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/StructuralUpgradeModule.sol";

/// DR-6a regression: every deployed module can hand its admin to the Timelock.
///
/// The defect this guards against has already happened once and was caught only by rehearsal:
/// seven modules bound `admin` in their constructor with no setter, so Section 3 step 8 of the
/// mainnet sequence ("hand the modules to the Timelock") could not execute, and on an immutable
/// mainnet cell that would have been permanent (mainnet-deploy.md DR-6a, found 2026-08-01).
///
/// Four properties per module, and the LIST ITSELF is the fifth check: if an eighth module is
/// ever added with a constructor-bound admin, it belongs here the day it is written.
///   1. admin can transferAdmin to a new address, and the new address holds it (read back).
///   2. address(0) is rejected with ZeroAdmin -- a zero admin is bricked forever, exactly the
///      state this function exists to prevent.
///   3. a non-admin cannot call it (NotAdmin error; IssuanceModule predates the error style and
///      reverts with the require string "Not admin" instead -- asserted as it IS, not as the
///      other six are).
///   4. AdminTransferred(old, new) is emitted with both fields correct.
///   5. the OLD admin loses the power: its next call reverts.
contract TransferAdminTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant NEW_ADMIN = address(0xB0B);
    address internal constant STRANGER = address(0xBAD);

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    ClaimDisputeModule internal claim;
    FmeaRegistry internal fmea;
    IntegrityReviewModule internal integrity;
    IssuanceModule internal issuance;
    SpecArbiterModule internal arbiter;
    SpecGapModule internal gap;
    StructuralUpgradeModule internal structural;

    function setUp() public {
        claim = new ClaimDisputeModule(ADMIN);
        fmea = new FmeaRegistry(ADMIN);
        integrity = new IntegrityReviewModule(ADMIN);
        issuance = new IssuanceModule(ADMIN);
        arbiter = new SpecArbiterModule(ADMIN);
        gap = new SpecGapModule(ADMIN);
        structural = new StructuralUpgradeModule(ADMIN);
    }

    // ---- the shared exercise, run against one module ---------------------------------------------

    function _exercise(address module, string memory name, bytes memory notAdminErr) internal {
        // 1. happy path + 4. event, old and new both correct.
        vm.expectEmit(true, true, false, true);
        emit AdminTransferred(ADMIN, NEW_ADMIN);
        vm.prank(ADMIN);
        (bool ok, ) = module.call(abi.encodeWithSignature("transferAdmin(address)", NEW_ADMIN));
        assertTrue(ok, string.concat(name, ": transferAdmin by admin must succeed"));

        // read-back: the module's own storage answers, not our expectation.
        (, bytes memory got) = module.staticcall(abi.encodeWithSignature("admin()"));
        assertEq(abi.decode(got, (address)), NEW_ADMIN, string.concat(name, ": admin read-back"));

        // 5. the OLD admin lost the power.
        vm.prank(ADMIN);
        (bool oldStillWorks, ) = module.call(abi.encodeWithSignature("transferAdmin(address)", ADMIN));
        assertFalse(oldStillWorks, string.concat(name, ": the old admin must LOSE transferAdmin"));

        // 2. zero-address reject, from the CURRENT admin so only the zero check can be the cause.
        vm.prank(NEW_ADMIN);
        vm.expectRevert(abi.encodeWithSignature("ZeroAdmin()"));
        (ok, ) = module.call(abi.encodeWithSignature("transferAdmin(address)", address(0)));

        // 3. a stranger is refused with the module's own guard error.
        vm.prank(STRANGER);
        vm.expectRevert(notAdminErr);
        (ok, ) = module.call(abi.encodeWithSignature("transferAdmin(address)", STRANGER));
    }

    // Not a `constant`: abi.encodeWithSignature is not a compile-time constant expression.
    function NOT_ADMIN() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("NotAdmin()");
    }

    function test_claimDispute() public { _exercise(address(claim), "ClaimDisputeModule", NOT_ADMIN()); }
    function test_fmeaRegistry() public { _exercise(address(fmea), "FmeaRegistry", NOT_ADMIN()); }
    function test_integrityReview() public { _exercise(address(integrity), "IntegrityReviewModule", NOT_ADMIN()); }
    function test_specArbiter() public { _exercise(address(arbiter), "SpecArbiterModule", NOT_ADMIN()); }
    function test_specGap() public { _exercise(address(gap), "SpecGapModule", NOT_ADMIN()); }
    function test_structuralUpgrade() public { _exercise(address(structural), "StructuralUpgradeModule", NOT_ADMIN()); }
    function test_issuance() public {
        // IssuanceModule guards with `require(msg.sender == admin, "Not admin")` -- a string, not
        // the NotAdmin() error. Asserted as it IS rather than papered over to match the others.
        _exercise(address(issuance), "IssuanceModule", bytes("Not admin"));
    }
}
