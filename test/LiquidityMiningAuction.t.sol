// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityMiningAuction, IERC20} from "../contracts/LiquidityMiningAuction.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {ReentrantToken, IAuction} from "../contracts/mocks/ReentrantToken.sol";

contract AuctionTest is Test {
    LiquidityMiningAuction internal auction;
    MockERC20 internal pndc;

    address internal warp = makeAddr("warp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant ONE_T = 1_000_000_000_000 ether; // 1e30
    uint256 internal constant DURATION = 7 days;

    event Deposited(uint256 indexed auctionId, address indexed participant, uint256 amount, uint256 total);
    event AuctionFinalized(uint256 indexed auctionId, address indexed winner, uint256 winningBid);
    event SentToWarp(uint256 indexed auctionId, uint256 amount, address warpDeposit);

    function setUp() public {
        pndc = new MockERC20("Pond Coin", "PNDC");
        auction = new LiquidityMiningAuction(address(pndc), warp);
        _fund(alice, 5 * ONE_T);
        _fund(bob, 5 * ONE_T);
        _fund(carol, 5 * ONE_T);
    }

    function _fund(address who, uint256 amount) internal {
        pndc.mint(who, amount);
        vm.prank(who);
        pndc.approve(address(auction), type(uint256).max);
    }

    /* ------------------------------------------------------------ unit */

    function test_startsWithSevenDayWindow() public view {
        assertEq(auction.currentAuctionId(), 1);
        LiquidityMiningAuction.Auction memory a = auction.getAuction(1);
        assertEq(a.expiresAt - a.startAt, DURATION);
        assertEq(auction.MIN_BID(), ONE_T);
    }

    function test_rejectsBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert("below 1T minimum");
        auction.deposit(ONE_T - 1);
    }

    function test_depositAtMinimum() public {
        vm.expectEmit(true, true, false, true, address(auction));
        emit Deposited(1, alice, ONE_T, ONE_T);
        vm.prank(alice);
        auction.deposit(ONE_T);
        assertEq(auction.getPosition(1, alice), ONE_T);
        assertEq(auction.participantCount(1), 1);
        assertEq(pndc.balanceOf(address(auction)), ONE_T);
    }

    function test_topUpKeepsSingleParticipant() public {
        vm.startPrank(alice);
        auction.deposit(ONE_T);
        auction.deposit(ONE_T / 2);
        vm.stopPrank();
        assertEq(auction.getPosition(1, alice), ONE_T + ONE_T / 2);
        assertEq(auction.participantCount(1), 1);
    }

    function test_highestWinsAtFinalize() public {
        _deposit(alice, ONE_T);
        _deposit(bob, 3 * ONE_T); // highest
        _deposit(carol, 2 * ONE_T);

        vm.warp(block.timestamp + DURATION + 1);
        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionFinalized(1, bob, 3 * ONE_T);
        auction.finalize();

        LiquidityMiningAuction.Auction memory a = auction.getAuction(1);
        assertTrue(a.finalized);
        assertEq(a.winner, bob);
        assertEq(a.winningBid, 3 * ONE_T);
        assertEq(auction.currentAuctionId(), 2); // next auction opened
    }

    function test_exitRefundsAndRemovesParticipant() public {
        _deposit(alice, ONE_T);
        _deposit(bob, 2 * ONE_T);
        uint256 before = pndc.balanceOf(alice);

        vm.prank(alice);
        auction.exit();
        assertEq(pndc.balanceOf(alice), before + ONE_T);
        assertEq(auction.getPosition(1, alice), 0);
        assertEq(auction.participantCount(1), 1); // swap-pop kept bob consistent

        // bob still exits cleanly (index integrity after swap-pop)
        vm.prank(bob);
        auction.exit();
        assertEq(auction.participantCount(1), 0);
    }

    function test_blocksDepositAfterExpiry() public {
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert("auction ended");
        auction.deposit(ONE_T);
    }

    function test_loserExitsWinnerLocked() public {
        _deposit(alice, ONE_T); // loser
        _deposit(bob, 3 * ONE_T); // winner
        vm.warp(block.timestamp + DURATION + 1);
        auction.finalize();

        uint256 before = pndc.balanceOf(alice);
        vm.prank(alice);
        auction.exitAuction(1);
        assertEq(pndc.balanceOf(alice), before + ONE_T);

        vm.prank(bob);
        vm.expectRevert("winner locked");
        auction.exitAuction(1);
    }

    function test_sendToWarpOnce() public {
        _deposit(alice, ONE_T);
        _deposit(bob, 3 * ONE_T);
        vm.warp(block.timestamp + DURATION + 1);
        auction.finalize();

        uint256 before = pndc.balanceOf(warp);
        vm.expectEmit(true, false, false, true, address(auction));
        emit SentToWarp(1, 3 * ONE_T, warp);
        auction.sendToWarp(1);
        assertEq(pndc.balanceOf(warp), before + 3 * ONE_T);

        vm.expectRevert("already sent");
        auction.sendToWarp(1);
    }

    function test_finalizeBeforeExpiryReverts() public {
        _deposit(alice, ONE_T);
        vm.expectRevert("not ended");
        auction.finalize();
    }

    /* --------------------------------------------------- access control */

    function test_onlyOwnerGuards() public {
        vm.startPrank(alice);
        vm.expectRevert("not owner");
        auction.setWarpDeposit(alice);
        vm.expectRevert("not owner");
        auction.togglePause();
        vm.expectRevert("not owner");
        auction.transferOwnership(alice);
        vm.expectRevert("not owner");
        auction.emergencyWithdraw(IERC20(address(pndc)));
        vm.stopPrank();
    }

    function test_pauseBlocksDeposits() public {
        auction.togglePause(); // test contract is owner
        vm.prank(alice);
        vm.expectRevert("paused");
        auction.deposit(ONE_T);
    }

    /* ----------------------------------------------------- reentrancy */

    function test_reentrancyGuardBlocksExitReenter() public {
        ReentrantToken evil = new ReentrantToken();
        LiquidityMiningAuction a2 = new LiquidityMiningAuction(address(evil), warp);
        evil.mint(alice, 3 * ONE_T);
        vm.prank(alice);
        evil.approve(address(a2), type(uint256).max);
        vm.prank(alice);
        a2.deposit(3 * ONE_T);

        // arm the token to re-enter exit() during the refund transfer
        evil.setAttack(IAuction(address(a2)), true, 0);
        vm.prank(alice);
        vm.expectRevert("reentrant");
        a2.exit();
    }

    /* ---------------------------------------------------------- fuzz */

    function testFuzz_depositMinimumBoundary(uint256 amt) public {
        amt = bound(amt, 1, 1e34);
        pndc.mint(alice, amt);
        vm.startPrank(alice);
        pndc.approve(address(auction), type(uint256).max);
        if (amt < ONE_T) {
            vm.expectRevert("below 1T minimum");
            auction.deposit(amt);
        } else {
            auction.deposit(amt);
            assertEq(auction.getPosition(1, alice), amt);
        }
        vm.stopPrank();
    }

    function testFuzz_exitRefundsExact(uint256 amt) public {
        amt = bound(amt, ONE_T, 5 * ONE_T);
        _deposit(alice, amt);
        uint256 before = pndc.balanceOf(alice);
        vm.prank(alice);
        auction.exit();
        assertEq(pndc.balanceOf(alice), before + amt);
        assertEq(auction.getPosition(1, alice), 0);
    }

    /* -------------------------------------------------------- helpers */

    function _deposit(address who, uint256 amt) internal {
        vm.prank(who);
        auction.deposit(amt);
    }
}
