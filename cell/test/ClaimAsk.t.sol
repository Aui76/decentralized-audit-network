// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/ClaimAskFixture.sol";

/// @notice DEC-48: the market prices a hole found after the window closed; the network pays a boost, not the finding.
///
///         A claim on a CONFIRMED row used to be paid out of the pool at the posted bounty, boosted by the auditor's
///         record, with the pool writing an IOU when it ran short. The bounty had already left the cell for the auditor,
///         so the pool was pricing a finding it never priced before, and any ring that could farm the boost could farm the
///         pool. Now the finder names a price before filing; whoever funds the re-run puts that price beside the re-run
///         bounty; a FAIL that reproduces hands the price to the finder, every other exit hands it back. The pool adds the
///         reputation boost alone (the part above 1x), keyed to the posted bounty, capped at half the re-run bounty and at
///         what the pool holds, best-effort, no debt. A pre-confirm claim is untouched: the pot is still in the cell and
///         prices the finding as before (`nameClaimAsk` refuses an escrowed row).
///
///         Teeth: `BONUS_RERUN_CAP_BPS` gone from `_payoutDiscoverer` fails the farmed-boost tests; `_returnAsk` gone from
///         any exit fails that exit's custody test; the pool clamp gone fails the short-pool test with a shortfall event.
contract ClaimAskTest is ClaimAskFixture {
    // ---- naming and binding ----------------------------------------------------------------------------------------

    function test_a_price_named_before_filing_binds_at_filing() public {
        uint256 id = _confirmedOriginal();
        vm.prank(claimant);
        claimModule.nameClaimAsk(id, ASK);
        assertEq(claimModule.pendingAsk(id, claimant), ASK, "pending until the filing");

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskNamed(id, claimant, ASK);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");

        (uint256 ask,,,) = claimModule.claimAskStatus(id);
        assertEq(ask, ASK, "bound to the claim");
        assertEq(claimModule.pendingAsk(id, claimant), 0, "the pending slot is spent");
    }

    function test_naming_zero_clears_and_a_price_named_after_filing_is_refused() public {
        uint256 id = _confirmedOriginal();
        vm.startPrank(claimant);
        claimModule.nameClaimAsk(id, ASK);
        claimModule.nameClaimAsk(id, 0);
        vm.stopPrank();
        _file(id, claimant);
        (uint256 ask,,,) = claimModule.claimAskStatus(id);
        assertEq(ask, 0, "cleared before filing: an unpriced claim");

        // a claim in flight makes the row ineligible, so a price named now is refused at the naming, not ignored
        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskNotAllowedHere.selector);
        claimModule.nameClaimAsk(id, ASK);
        (ask,,,) = claimModule.claimAskStatus(id);
        assertEq(ask, 0, "the claim stays unpriced");
        // and the funding lane treats it as unpriced
        _lapseWindow();
        vm.startPrank(funder);
        token.approve(address(cell), MIN_B + ASK);
        vm.expectRevert(ClaimDisputeModule.AskNotOpen.selector);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
    }

    function test_naming_is_refused_while_the_bounty_is_still_escrowed() public {
        uint256 id = _awaitingOriginal();
        assertTrue(cell.auditBountyEscrowed(id), "AwaitingWindow: the pot is in the cell");
        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskNotAllowedHere.selector);
        claimModule.nameClaimAsk(id, ASK);

        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.InvalidOriginalId.selector);
        claimModule.nameClaimAsk(999_999, ASK);
    }

    // ---- the protocol funds inside its window -----------------------------------------------------------------------

    function test_protocol_funds_the_price_beside_the_rerun_and_a_FAIL_pays_the_finder() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 cellBefore = token.balanceOf(address(cell));
        uint256 poolBefore = escrow.escrowBalance();

        uint256 disputeId = _protocolFunds(id);
        assertEq(token.balanceOf(protocol), protocolBefore - MIN_B - ASK, "the re-run bounty and the price, together");
        assertEq(token.balanceOf(address(cell)), cellBefore + MIN_B + ASK, "both held by the cell");
        (uint256 ask, address f, uint256 funded, uint256 paid) = claimModule.claimAskStatus(id);
        assertEq(ask, ASK);
        assertEq(f, protocol, "the protocol is the funder of record");
        assertEq(funded, ASK);
        assertEq(paid, 0);

        address drawn = _fail(disputeId, claimRoot);
        uint256 drawnBefore = token.balanceOf(drawn);
        vm.expectEmit(true, true, true, true, address(claimModule));
        emit ClaimAskPaid(id, claimant, protocol, ASK);
        vm.recordLogs();
        _confirm(disputeId);
        _assertNoShortfall();

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake, "the finder is paid the price, and the stake comes home");
        assertEq(token.balanceOf(drawn), drawnBefore + MIN_B, "the drawn re-auditor is paid the re-run bounty");
        assertEq(token.balanceOf(protocol), protocolBefore - MIN_B - ASK, "the protocol paid what it put up, nothing more");
        assertEq(escrow.escrowBalance(), poolBefore, "a fresh auditor's record is 1x: the pool pays no bonus");
        _assertNoDebt();
        (ask, f, funded, paid) = claimModule.claimAskStatus(id);
        assertEq(funded, 0);
        assertEq(f, address(0));
        assertEq(paid, ASK, "the row remembers what the last FAIL paid");
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 1, "the original auditor's record takes the exploit as before");
    }

    function test_protocol_funded_PASS_returns_the_price_and_slashes_the_stake() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 claimantBefore = token.balanceOf(claimant);

        uint256 disputeId = _protocolFunds(id);
        _pass(disputeId);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, protocol, ASK, 1);
        _confirm(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "the PASS stands");
        assertEq(token.balanceOf(protocol), protocolBefore - MIN_B, "the price came back; the re-run bounty paid the re-auditor");
        assertGt(stake, 0, "the row carried a stake");
        assertEq(token.balanceOf(claimant), claimantBefore, "the stake, already in the cell, is slashed as before: nothing comes home");
        (uint256 ask, address f, uint256 funded, uint256 paid) = claimModule.claimAskStatus(id);
        assertEq(ask, ASK, "the named price stays readable on the resolved claim");
        assertEq(f, address(0));
        assertEq(funded, 0);
        assertEq(paid, 0);
        _assertNoDebt();
    }

    // ---- the window lapses and a third party funds ------------------------------------------------------------------

    function test_after_the_window_anyone_funds_and_a_FAIL_pays_the_finder_the_price() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 funderBefore = token.balanceOf(funder);
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 poolBefore = escrow.escrowBalance();

        _lapseWindow();
        vm.startPrank(funder);
        token.approve(address(cell), MIN_B + ASK);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskFunded(id, funder, ASK, cell.nextAuditId());
        uint256 disputeId = claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
        (, address f, uint256 funded,) = claimModule.claimAskStatus(id);
        assertEq(f, funder);
        assertEq(funded, ASK);

        _fail(disputeId, claimRoot);
        vm.expectEmit(true, true, true, true, address(claimModule));
        emit ClaimAskPaid(id, claimant, funder, ASK);
        _confirm(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake, "paid by the market");
        assertEq(token.balanceOf(funder), funderBefore - MIN_B - ASK, "the funder bought the re-run and the finding");
        assertEq(token.balanceOf(protocol), protocolBefore, "the protocol that let the window lapse pays nothing");
        assertEq(escrow.escrowBalance(), poolBefore, "no bonus at 1x");
        _assertNoDebt();
    }

    function test_third_party_funded_PASS_returns_the_price_to_the_funder() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 funderBefore = token.balanceOf(funder);
        _lapseWindow();
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _pass(disputeId);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, funder, ASK, 1);
        _confirm(disputeId);
        assertEq(token.balanceOf(funder), funderBefore - MIN_B, "the price came home; the re-run bounty paid the re-auditor");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    // ---- the finder's own lane ----------------------------------------------------------------------------------------

    function test_declined_then_the_finders_own_lane_kills_the_price_and_the_pool_pays_only_the_boost() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        // A farmed record on the original auditor: 3x. The boost survives the price being killed: it is the network's.
        vm.mockCall(
            address(cell), abi.encodeWithSelector(cell.auditorReputationBoostBps.selector, auditorA), abi.encode(uint256(30_000))
        );

        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 poolBefore = escrow.escrowBalance();
        vm.startPrank(claimant);
        token.approve(address(cell), MIN_B);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskUnfunded(id, claimant, ASK);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, MIN_B);
        vm.stopPrank();
        (uint256 ask,, uint256 funded,) = claimModule.claimAskStatus(id);
        assertEq(ask, 0, "nobody bought the finding at that price; the row says so");
        assertEq(funded, 0);
        assertEq(token.balanceOf(claimant), claimantBefore - MIN_B, "the finder funds the re-run alone, no price on top");

        _fail(disputeId, claimRoot);
        vm.recordLogs();
        _confirm(disputeId);
        _assertNoShortfall();
        vm.clearMockedCalls();

        uint256 bonus = (MIN_B * 5000) / 10_000; // 40 * (3x - 1x) = 80 asked, capped at half the re-run bounty
        assertEq(bonus, 10 ether);
        assertEq(token.balanceOf(claimant), claimantBefore - MIN_B + stake + bonus, "stake home, plus the capped boost");
        assertEq(escrow.escrowBalance(), poolBefore - bonus, "the pool paid the boost and nothing else");
        _assertNoDebt();
        (,,, uint256 paid) = claimModule.claimAskStatus(id);
        assertEq(paid, 0, "no price was paid");
    }

    // ---- the boost: capped at half the re-run bounty, clamped to the pool, never owed -------------------------------

    function test_farmed_boost_bonus_is_capped_at_half_the_rerun_bounty() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        vm.mockCall(
            address(cell), abi.encodeWithSelector(cell.auditorReputationBoostBps.selector, auditorA), abi.encode(uint256(30_000))
        );
        _lapseWindow();
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 poolBefore = escrow.escrowBalance();
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _fail(disputeId, claimRoot);
        vm.recordLogs();
        _confirm(disputeId);
        _assertNoShortfall();
        vm.clearMockedCalls();

        uint256 uncapped = (ORIG_BOUNTY * (30_000 - 10_000)) / 10_000; // 80: what the old rule would have asked
        uint256 bonus = (MIN_B * 5000) / 10_000; // 10
        assertLt(bonus, uncapped);
        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake + bonus, "price from the market, boost from the pool");
        assertEq(escrow.escrowBalance(), poolBefore - bonus, "the pool never pays more than half of what the re-run cost");
        _assertNoDebt();
    }

    function test_the_cap_follows_the_rerun_bounty_the_funder_chose() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        vm.mockCall(
            address(cell), abi.encodeWithSelector(cell.auditorReputationBoostBps.selector, auditorA), abi.encode(uint256(30_000))
        );
        _lapseWindow();
        uint256 bigRerun = 30 ether;
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 poolBefore = escrow.escrowBalance();
        vm.startPrank(funder);
        token.approve(address(cell), bigRerun + ASK);
        uint256 disputeId = claimModule.fundClaimAsk(id, bigRerun);
        vm.stopPrank();
        _fail(disputeId, claimRoot);
        _confirm(disputeId);
        vm.clearMockedCalls();

        uint256 bonus = bigRerun / 2; // 15: a dearer re-run earns a larger boost, still at most half of it
        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake + bonus);
        assertEq(escrow.escrowBalance(), poolBefore - bonus);
        _assertNoDebt();
    }

    function test_a_short_pool_pays_what_it_holds_and_owes_nothing() public {
        _fundEscrow(8 ether);
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        vm.mockCall(
            address(cell), abi.encodeWithSelector(cell.auditorReputationBoostBps.selector, auditorA), abi.encode(uint256(30_000))
        );
        _lapseWindow();
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _fail(disputeId, claimRoot);
        // measured here: the original row's confirm fee also lands in the pool, so the figure is read after the row exists
        uint256 held = escrow.escrowBalance();
        assertGt(held, 0);
        assertLt(held, (MIN_B * 5000) / 10_000, "the pool holds less than the cap");
        vm.recordLogs();
        _confirm(disputeId);
        _assertNoShortfall();
        vm.clearMockedCalls();

        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake + held, "the price in full, the boost as far as the pool goes");
        assertEq(escrow.escrowBalance(), 0, "the pool is emptied, not overdrawn");
        _assertNoDebt();
    }

    function test_an_empty_pool_pays_no_boost_and_the_price_still_arrives() public {
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        vm.mockCall(
            address(cell), abi.encodeWithSelector(cell.auditorReputationBoostBps.selector, auditorA), abi.encode(uint256(30_000))
        );
        _lapseWindow();
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _fail(disputeId, claimRoot);
        // the original row's confirm fee seeds the pool, so an empty pool is read through a mock: the module clamps to
        // what `escrowBalance()` says it holds, and that is 0 here
        uint256 realPool = escrow.escrowBalance();
        vm.mockCall(address(escrow), abi.encodeWithSelector(escrow.escrowBalance.selector), abi.encode(uint256(0)));
        vm.recordLogs();
        _confirm(disputeId);
        _assertNoShortfall();
        vm.clearMockedCalls();
        assertEq(token.balanceOf(claimant), claimantBefore + ASK + stake, "the market paid; the network had nothing to add");
        assertEq(escrow.escrowBalance(), realPool, "nothing left the pool");
        _assertNoDebt();
    }

    // ---- the exits that hand the price back ----------------------------------------------------------------------------

    function test_a_verdict_that_reproduces_neither_root_returns_the_price() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 funderBefore = token.balanceOf(funder);
        uint256 claimantBefore = token.balanceOf(claimant);
        _lapseWindow();
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _fail(disputeId, otherRoot);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, funder, ASK, 2);
        _confirm(disputeId);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "resolved unadjudicated");
        assertEq(token.balanceOf(funder), funderBefore - MIN_B, "the verdict stands and its auditor was paid; the price came home");
        assertEq(token.balanceOf(claimant), claimantBefore + stake, "the stake came home too; nobody adjudicated (PC-115)");
    }

    function test_a_silent_rerun_returns_the_price_with_the_rerun_bounty() public {
        _seedPool();
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 funderBefore = token.balanceOf(funder);
        uint256 claimantBefore = token.balanceOf(claimant);
        _lapseWindow();
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _accept(disputeId);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskReturned(id, funder, ASK, 3);
        claimModule.expireDispute(id);
        assertEq(token.balanceOf(funder), funderBefore, "both halves came home");
        assertEq(token.balanceOf(claimant), claimantBefore + stake, "the claim resolved unadjudicated, the stake came home (PC-115)");
        assertTrue(claimModule.disputeSpent(id, funder), "PC-116 marks the funder, as it marks any funder");
    }

    // ---- lowering ------------------------------------------------------------------------------------------------------

    function test_the_price_can_come_down_and_never_go_up() public {
        uint256 id = _pricedClaim();
        vm.prank(claimant);
        vm.expectEmit(true, true, false, true, address(claimModule));
        emit ClaimAskNamed(id, claimant, 20 ether);
        claimModule.lowerClaimAsk(id, 20 ether);
        (uint256 ask,,,) = claimModule.claimAskStatus(id);
        assertEq(ask, 20 ether);

        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskNotLower.selector);
        claimModule.lowerClaimAsk(id, 20 ether);
        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskNotLower.selector);
        claimModule.lowerClaimAsk(id, 30 ether);
        vm.prank(funder);
        vm.expectRevert(ClaimDisputeModule.OnlyClaimant.selector);
        claimModule.lowerClaimAsk(id, 1 ether);

        // funded: the price is a contract now
        _lapseWindow();
        vm.startPrank(funder);
        token.approve(address(cell), MIN_B + 20 ether);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskAlreadyFunded.selector);
        claimModule.lowerClaimAsk(id, 1 ether);
    }

    function test_lowering_to_zero_withdraws_the_price_and_an_unpriced_claim_has_nothing_to_lower() public {
        uint256 id = _pricedClaim();
        vm.prank(claimant);
        claimModule.lowerClaimAsk(id, 0);
        _lapseWindow();
        vm.startPrank(funder);
        token.approve(address(cell), MIN_B);
        vm.expectRevert(ClaimDisputeModule.AskNotOpen.selector);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
        vm.prank(claimant);
        vm.expectRevert(ClaimDisputeModule.AskNotOpen.selector);
        claimModule.lowerClaimAsk(id, 0);
    }

    // ---- funding guards -------------------------------------------------------------------------------------------------

    function test_funding_waits_for_the_protocols_window_and_refuses_a_second_rerun() public {
        uint256 id = _pricedClaim();
        vm.startPrank(funder);
        token.approve(address(cell), 2 * (MIN_B + ASK));
        vm.expectRevert(ClaimDisputeModule.AskNotOpen.selector);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();

        _lapseWindow();
        vm.startPrank(funder);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.expectRevert(ClaimDisputeModule.DisputeOpen.selector);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();

        vm.prank(protocol);
        vm.expectRevert(ClaimDisputeModule.DisputeOpen.selector);
        claimModule.openDisputeReaudit(id, MIN_B);
    }

    function test_a_funder_whose_rerun_went_silent_may_not_fund_the_row_again_but_another_may() public {
        _seedPool();
        uint256 id = _pricedClaim();
        _lapseWindow();
        uint256 disputeId = _thirdPartyFunds(id, funder);
        _accept(disputeId);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);

        // the finder files again with a fresh price; the same funder is spent on this row, a second funder is not
        vm.prank(claimant);
        claimModule.nameClaimAsk(id, ASK);
        _file(id, claimant);
        _lapseWindow();
        vm.startPrank(funder);
        token.approve(address(cell), MIN_B + ASK);
        vm.expectRevert(ClaimDisputeModule.DisputeAlreadySpent.selector);
        claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
        uint256 second = _thirdPartyFunds(id, funder2);
        assertGt(second, disputeId);
        (, address f, uint256 funded,) = claimModule.claimAskStatus(id);
        assertEq(f, funder2);
        assertEq(funded, ASK);
    }

    // ---- the lapse is untouched -------------------------------------------------------------------------------------------

    function test_a_lapsed_priced_claim_slashes_as_before_and_the_next_claim_prices_itself() public {
        uint256 id = _pricedClaim();
        uint256 stake = _stakeOf(id);
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 cellBefore = token.balanceOf(address(cell));
        vm.warp(block.timestamp + 1 days + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        assertEq(token.balanceOf(claimant), claimantBefore, "the stake was already in the cell; it does not come back");
        assertEq(token.balanceOf(address(cell)), cellBefore - stake, "slashed to the pool as before; no price moved");

        // another registrant claims the same row at their own price
        vm.prank(auditorC);
        claimModule.nameClaimAsk(id, 7 ether);
        _file(id, auditorC);
        (uint256 ask, address f, uint256 funded, uint256 paid) = claimModule.claimAskStatus(id);
        assertEq(ask, 7 ether, "the old claim's price is gone with the old claim");
        assertEq(f, address(0));
        assertEq(funded, 0);
        assertEq(paid, 0);
    }

    // ---- reclaim guards ----------------------------------------------------------------------------------------------------

    function test_reclaim_refuses_an_unfunded_row_and_a_running_rerun() public {
        uint256 id = _pricedClaim();
        vm.expectRevert(ClaimDisputeModule.NothingToReclaim.selector);
        claimModule.reclaimClaimAsk(id);
        _lapseWindow();
        _thirdPartyFunds(id, funder);
        vm.expectRevert(ClaimDisputeModule.DisputeOpen.selector);
        claimModule.reclaimClaimAsk(id);
    }
}
