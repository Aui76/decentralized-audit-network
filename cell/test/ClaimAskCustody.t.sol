// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/ClaimAskFixture.sol";

/// @notice DEC-48 custody: the price a funder puts beside the re-run never stays in the cell.
///
///         Every exit a post-confirm claim can take is walked from the same priced, funded row, and after each the
///         cell holds exactly what it held before the filing: the price went to the finder (FAIL) or back to the
///         funder (PASS, neither root, silence, a voided row), the stake went home or to the pool, the re-run bounty
///         went to the re-auditor or home. The stranded case (a funded price with no dispute row active) is reachable
///         by the permissionless `reclaimClaimAsk`; here the cell is mocked into that state to prove the exit exists.
///
///         Teeth: drop any one `_returnAsk` call in ClaimDisputeModule and the matching test here fails on the cell's
///         balance, before any funder notices.
contract ClaimAskCustodyTest is ClaimAskFixture {
    uint256 cellBeforeFiling;

    function _fundedRow() internal returns (uint256 id, uint256 disputeId) {
        _seedPool();
        id = _confirmedOriginal();
        vm.prank(claimant);
        claimModule.nameClaimAsk(id, ASK);
        cellBeforeFiling = token.balanceOf(address(cell));
        _file(id, claimant);
        _lapseWindow();
        disputeId = _thirdPartyFunds(id, funder);
        assertEq(token.balanceOf(address(cell)), cellBeforeFiling + _stakeOf(id) + MIN_B + ASK, "everything is in the cell");
    }

    function _assertCellRestored(string memory exit) internal view {
        assertEq(token.balanceOf(address(cell)), cellBeforeFiling, string.concat("the cell keeps nothing after: ", exit));
        (, address f, uint256 funded,) = claimModule.claimAskStatus(id_);
        assertEq(f, address(0), "no funder of record remains");
        assertEq(funded, 0, "no funded price remains");
    }

    uint256 id_;

    function test_FAIL_leaves_the_cell_holding_nothing_of_the_row() public {
        (uint256 id, uint256 disputeId) = _fundedRow();
        id_ = id;
        _fail(disputeId, claimRoot);
        _confirm(disputeId);
        _assertCellRestored("a FAIL that pays the finder");
    }

    function test_PASS_leaves_the_cell_holding_nothing_of_the_row() public {
        (uint256 id, uint256 disputeId) = _fundedRow();
        id_ = id;
        _pass(disputeId);
        _confirm(disputeId);
        _assertCellRestored("a PASS that slashes the stake to the pool");
    }

    function test_neither_root_leaves_the_cell_holding_nothing_of_the_row() public {
        (uint256 id, uint256 disputeId) = _fundedRow();
        id_ = id;
        _fail(disputeId, otherRoot);
        _confirm(disputeId);
        _assertCellRestored("a verdict that reproduces neither root");
    }

    function test_silence_leaves_the_cell_holding_nothing_of_the_row() public {
        (uint256 id, uint256 disputeId) = _fundedRow();
        id_ = id;
        _accept(disputeId);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);
        _assertCellRestored("a re-run that went silent");
    }

    function test_a_voided_rerun_returns_the_price_when_the_lane_unwinds() public {
        (uint256 id, uint256 disputeId) = _fundedRow();
        id_ = id;
        uint256 funderBefore = token.balanceOf(funder);
        uint256 claimantBefore = token.balanceOf(claimant);
        _pass(disputeId);

        // registered AFTER the draw, so neither can be the dispute row's auditor
        vm.prank(opener);
        cell.register();
        vm.prank(reviewer);
        cell.register();
        uint256 reviewBounty = 10 ether;
        vm.startPrank(opener);
        token.approve(address(cell), integrity.integrityFilingStake() + reviewBounty);
        integrity.openIntegrityReview(disputeId, integrityToolId, reviewBounty);
        vm.stopPrank();
        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(disputeId, false, keccak256("integrity-fail"));
        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
        integrity.finalizeIntegrityReview(disputeId);
        assertEq(token.balanceOf(funder), funderBefore + MIN_B, "the void refunds the re-run bounty, as it did before");

        // the price waits for the lane to unwind: the row is voided but the lane still names it
        vm.expectRevert(ClaimDisputeModule.DisputeOpen.selector);
        claimModule.reclaimClaimAsk(id);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, funder, ASK, 3);
        claimModule.expireDispute(id);
        assertEq(token.balanceOf(funder), funderBefore + MIN_B + ASK, "the price comes home with the unwind; nothing twice");
        assertEq(token.balanceOf(claimant), claimantBefore + _stakeOf(id), "the claim resolves unadjudicated: the stake comes home");
        _assertCellRestored("a voided re-run and its unwind");
    }

    function test_a_stranded_price_is_reclaimable_by_anyone_and_only_once() public {
        (uint256 id,) = _fundedRow();
        id_ = id;
        uint256 funderBefore = token.balanceOf(funder);
        // No dispute row active while a funded price sits on the row: not reachable through the module's own
        // paths today (every exit returns the price), mocked here to prove the permissionless door.
        vm.mockCall(address(cell), abi.encodeWithSelector(cell.activeDisputeAuditId.selector, id), abi.encode(uint256(0)));
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, funder, ASK, 4);
        vm.prank(auditorC);
        claimModule.reclaimClaimAsk(id);
        assertEq(token.balanceOf(funder), funderBefore + ASK, "the funder, not the caller, is paid");
        vm.expectRevert(ClaimDisputeModule.NothingToReclaim.selector);
        claimModule.reclaimClaimAsk(id);
        vm.clearMockedCalls();
        (uint256 ask, address f, uint256 funded,) = claimModule.claimAskStatus(id);
        assertEq(ask, ASK, "the named price stays: the claim is still open");
        assertEq(f, address(0));
        assertEq(funded, 0);
    }
}
