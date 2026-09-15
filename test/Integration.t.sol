// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {AuctionTest} from "./LiquidityMiningAuction.t.sol";
import {LiquidityMiningAuction, IERC20} from "../contracts/LiquidityMiningAuction.sol";

contract IntegrationTest is AuctionTest {
    function test_deploymentIsPausedAndFirstLaunchGetsFullSevenDays() public {
        LiquidityMiningAuction fresh = new LiquidityMiningAuction(address(pndc), address(fee), _terms(warp));
        assertTrue(fresh.isPaused()); assertFalse(fresh.hasLaunched());
        vm.warp(block.timestamp + 14 days);
        vm.expectRevert("not launched"); fresh.finalize(1);
        fresh.setPaused(false);
        assertEq(fresh.getAuction(1).startAt, block.timestamp);
        assertEq(fresh.getAuction(1).expiresAt, block.timestamp + 7 days);
        uint256 expiry = fresh.getAuction(1).expiresAt;
        fresh.setPaused(true); vm.warp(block.timestamp + 1 days); fresh.setPaused(false);
        assertEq(fresh.getAuction(1).expiresAt, expiry);
    }
    function test_sameTokenProtectsEscrowAndFeeLiabilityTogether() public {
        LiquidityMiningAuction same = new LiquidityMiningAuction(address(pndc), address(pndc), _terms(warp));
        same.setPaused(false);
        vm.startPrank(alice); pndc.approve(address(same), ONE_T); same.deposit(1, ONE_T, block.timestamp + 300); vm.stopPrank();
        vm.warp(same.getAuction(1).expiresAt); same.finalize(1);
        pndc.mint(address(this), 123); pndc.approve(address(same), 123); same.depositFee(1, 123);
        vm.expectRevert("reserved funds"); same.recoverSurplus(IERC20(address(pndc)), bob, 1);
        same.claimFor(1);
        assertEq(pndc.balanceOf(address(same)), ONE_T);
        vm.expectRevert("reserved funds"); same.recoverSurplus(IERC20(address(pndc)), bob, 1);
        same.sendToWarp(1);
        assertEq(pndc.balanceOf(address(same)), 0);
        assertEq(same.totalEscrowed(), 0); assertEq(same.totalFeeLiability(), 0);
    }
    function testFuzz_grossFeeSplitAndPartialClaimsConserveLiability(uint96 first, uint96 second, uint16 share) public {
        first = uint96(bound(first, 1, 1e25)); second = uint96(bound(second, 1, 1e25)); share = uint16(bound(share, 0, 10000));
        LiquidityMiningAuction.Terms memory terms = _terms(warp); terms.winnerShareBps = share; terms.protocolFeeRecipient = carol;
        LiquidityMiningAuction split = new LiquidityMiningAuction(address(pndc), address(fee), terms);
        split.setPaused(false);
        vm.startPrank(alice); pndc.approve(address(split), ONE_T); split.deposit(1, ONE_T, block.timestamp + 300); vm.stopPrank();
        vm.warp(split.getAuction(1).expiresAt); split.finalize(1);
        uint256 total = uint256(first) + second; fee.mint(address(this), total); fee.approve(address(split), total);
        split.depositFee(1, first); if (uint256(first) * share / 10000 > 0) split.claimFor(1);
        split.depositFee(1, second); if (uint256(second) * share / 10000 > 0) split.claimFor(1);
        uint256 winnerAmount = uint256(first) * share / 10000 + uint256(second) * share / 10000;
        if (total > winnerAmount) { vm.prank(carol); split.claimProtocolFees(); }
        assertEq(fee.balanceOf(alice), winnerAmount); assertEq(fee.balanceOf(carol), total - winnerAmount);
        assertEq(split.totalFeeLiability(), 0); assertEq(fee.balanceOf(address(split)), 0);
    }
    function test_cutoffFreezesLeaderAndLosersCanRefundAfterSettlement() public {
        _deposit(alice, ONE_T); _deposit(bob, 3 * ONE_T);
        vm.warp(auction.getAuction(1).expiresAt);
        vm.prank(bob); vm.expectRevert("await settlement"); auction.exit();
        auction.finalize(1);
        assertEq(auction.getAuction(1).winner, bob);
        vm.prank(alice); auction.exitAuction(1);
        assertEq(auction.totalEscrowed(), 3 * ONE_T);
    }
    function test_tiesRemainStableAfterUnrelatedExit() public {
        _deposit(carol, ONE_T); _deposit(alice, 2 * ONE_T); _deposit(bob, 2 * ONE_T);
        vm.prank(carol); auction.exit();
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        assertEq(auction.getAuction(1).winner, alice);
    }
    function test_newTermsNeverRedirectExistingWinner() public {
        _deposit(alice, ONE_T);
        auction.scheduleTerms(_terms(bob));
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        auction.sendToWarp(1);
        assertEq(pndc.balanceOf(warp), ONE_T);
        (address nextSink,,,) = auction.auctionTerms(2);
        assertEq(nextSink, bob);
    }
    function test_pauseStopsReleaseButAllowsSettlementAndRefunds() public {
        _deposit(alice, ONE_T); _deposit(bob, 2 * ONE_T);
        auction.setPaused(true);
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        vm.prank(alice); auction.exitAuction(1);
        vm.expectRevert("paused"); auction.sendToWarp(1);
    }
    function test_roundBoundDepositAndFinalizeRejectStaleIdentity() public {
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        vm.prank(alice); vm.expectRevert("wrong auction"); auction.deposit(1, ONE_T, block.timestamp + 300);
        vm.expectRevert("wrong auction"); auction.finalize(1);
    }
    function test_ownerCannotRecoverBidOrFeeLiabilities() public {
        _deposit(alice, ONE_T);
        vm.expectRevert("reserved funds"); auction.recoverSurplus(IERC20(address(pndc)), bob, 1);
        pndc.mint(address(auction), 7);
        auction.recoverSurplus(IERC20(address(pndc)), bob, 7);
        assertEq(pndc.balanceOf(address(auction)), ONE_T);
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        fee.mint(address(this), 1 ether); fee.approve(address(auction), 1 ether);
        auction.depositFee(1, 1 ether);
        vm.expectRevert("reserved funds"); auction.recoverSurplus(IERC20(address(fee)), bob, 1);
    }
    function test_claimsRemainRepeatableAndSponsorCannotRedirect() public {
        _deposit(alice, ONE_T);
        vm.warp(auction.getAuction(1).expiresAt); auction.finalize(1);
        fee.mint(address(this), 3 ether); fee.approve(address(auction), 3 ether);
        auction.depositFee(1, 1 ether);
        vm.prank(bob); auction.claimFor(1);
        auction.depositFee(1, 2 ether);
        vm.prank(alice); auction.claimFee(1);
        assertEq(fee.balanceOf(alice), 3 ether);
        assertEq(fee.balanceOf(bob), 0);
        assertEq(auction.totalFeeLiability(), 0);
        assertEq(auction.getFeeVault(1).funded, 3 ether);
        assertEq(auction.getFeeVault(1).claimed, 3 ether);
    }
    function test_shareSplitConservesFeesAndPinsProtocolRecipient() public {
        LiquidityMiningAuction.Terms memory terms = _terms(warp);
        terms.winnerShareBps = 5000; terms.protocolFeeRecipient = carol;
        LiquidityMiningAuction split = new LiquidityMiningAuction(address(pndc), address(fee), terms);
        split.setPaused(false);
        vm.startPrank(alice); pndc.approve(address(split), ONE_T); split.deposit(1, ONE_T, block.timestamp + 300); vm.stopPrank();
        vm.warp(split.getAuction(1).expiresAt); split.finalize(1);
        fee.mint(address(this), 101); fee.approve(address(split), 101); split.depositFee(1, 101);
        assertEq(split.getFeeVault(1).funded, 50);
        assertEq(split.protocolFees(carol), 51);
        split.claimFor(1);
        vm.prank(carol); split.claimProtocolFees();
        assertEq(fee.balanceOf(alice), 50); assertEq(fee.balanceOf(carol), 51);
        assertEq(split.totalFeeLiability(), 0);
    }
    function test_ownerTransferRequiresAcceptanceAndDelay() public {
        auction.transferOwnership(alice);
        vm.prank(alice); vm.expectRevert("ownership not ready"); auction.acceptOwnership();
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice); auction.acceptOwnership();
        assertEq(auction.owner(), alice);
    }
    function test_maximumParticipantSettlementFitsBlockBudget() public {
        for (uint256 i; i < auction.MAX_PARTICIPANTS(); ++i) {
            address bidder = address(uint160(10_000 + i));
            pndc.mint(bidder, ONE_T);
            vm.startPrank(bidder); pndc.approve(address(auction), ONE_T); auction.deposit(1, ONE_T, block.timestamp + 300); vm.stopPrank();
        }
        vm.prank(alice); vm.expectRevert("participant limit"); auction.deposit(1, ONE_T, block.timestamp + 300);
        vm.warp(auction.getAuction(1).expiresAt);
        uint256 beforeGas = gasleft(); auction.finalize(1);
        assertLt(beforeGas - gasleft(), 5_000_000);
        assertEq(auction.getAuction(1).winner, address(10_000));
    }
}
