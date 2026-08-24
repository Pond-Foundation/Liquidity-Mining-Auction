// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityMiningAuction} from "../contracts/LiquidityMiningAuction.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

uint256 constant ONE_T = 1_000_000_000_000 ether;
uint256 constant ONE_BILLION = 1_000_000_000 ether;

/// Bounded actor that drives the auction through random deposit/exit/finalize/warp
/// sequences while tracking the total PNDC it believes is escrowed.
contract Handler is Test {
    LiquidityMiningAuction public auction;
    MockERC20 public pndc;
    address[] public actors;
    uint256 public ghostEscrowed;   // what we think the contract holds
    uint256 public lastFinalizedId;

    constructor(LiquidityMiningAuction _a, MockERC20 _p) {
        auction = _a;
        pndc = _p;
        for (uint256 i = 0; i < 4; i++) actors.push(makeAddr(string(abi.encodePacked("actor", i))));
    }

    function deposit(uint256 actorSeed, uint256 amtSeed) external {
        address who = actors[actorSeed % actors.length];
        uint256 id = auction.currentAuctionId();
        LiquidityMiningAuction.Auction memory a = auction.getAuction(id);
        if (block.timestamp >= a.expiresAt) return; // window closed

        uint256 cur = auction.getPosition(id, who);
        uint256 lo = cur >= ONE_T ? 1 : (ONE_T - cur);
        uint256 amt = bound(amtSeed, lo, 3 * ONE_T);
        amt = amt - (amt % ONE_BILLION); // mirror the contract's whole-billion rounding
        if (amt == 0) return;

        pndc.mint(who, amt);
        vm.startPrank(who);
        pndc.approve(address(auction), type(uint256).max);
        try auction.deposit(amt) { ghostEscrowed += amt; } catch {}
        vm.stopPrank();
    }

    function exit(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        uint256 id = auction.currentAuctionId();
        uint256 pos = auction.getPosition(id, who);
        if (pos == 0) return;
        vm.prank(who);
        try auction.exit() { ghostEscrowed -= pos; } catch {}
    }

    function roll() external {
        uint256 id = auction.currentAuctionId();
        LiquidityMiningAuction.Auction memory a = auction.getAuction(id);
        vm.warp(a.expiresAt + 1);
        try auction.finalize() { lastFinalizedId = id; } catch {}
    }

    function warpOut() external {
        if (lastFinalizedId == 0) return;
        LiquidityMiningAuction.Auction memory a = auction.getAuction(lastFinalizedId);
        if (a.winner == address(0) || a.sentToWarp) return;
        uint256 amt = auction.getPosition(lastFinalizedId, a.winner);
        try auction.sendToWarp(lastFinalizedId) { ghostEscrowed -= amt; } catch {}
    }
}

contract AuctionInvariantTest is Test {
    LiquidityMiningAuction internal auction;
    MockERC20 internal pndc;
    Handler internal handler;

    function setUp() public {
        pndc = new MockERC20("Pond Coin", "PNDC");
        MockERC20 feeTok = new MockERC20("Fee Reward", "FEE");
        auction = new LiquidityMiningAuction(address(pndc), address(feeTok), makeAddr("warp"));
        handler = new Handler(auction, pndc);
        targetContract(address(handler));
    }

    /// The contract's PNDC balance always equals what we escrowed (never more,
    /// never less) — no funds get stuck or double-spent.
    function invariant_solvency() public view {
        assertEq(pndc.balanceOf(address(auction)), handler.ghostEscrowed());
    }

    /// Every active participant of the live auction is at or above the 1T floor.
    function invariant_minBidFloor() public view {
        (, uint256[] memory amounts) = auction.getParticipants(auction.currentAuctionId());
        for (uint256 i = 0; i < amounts.length; i++) {
            assertGe(amounts[i], ONE_T);
        }
    }
}
