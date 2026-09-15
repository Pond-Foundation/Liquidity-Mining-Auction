// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script} from "forge-std/Script.sol";
import {LiquidityMiningAuction} from "../contracts/LiquidityMiningAuction.sol";

/// Deployment starts paused. Register the receipt/bytecode in Pond before owner launch.
/// Use a hardware wallet or Foundry keystore; this script never reads a raw private key.
contract DeployEnglishV2 is Script {
    function run() external returns (LiquidityMiningAuction deployed) {
        require(block.chainid == 1, "Ethereum mainnet only");
        address pndc = 0x423f4e6138E475D85CF7Ea071AC92097Ed631eea;
        address feeToken = vm.envAddress("AUCTION_FEE_TOKEN");
        uint256 share = vm.envUint("AUCTION_WINNER_SHARE_BPS");
        require(share <= 10000, "invalid share");
        LiquidityMiningAuction.Terms memory terms = LiquidityMiningAuction.Terms(
            vm.envAddress("AUCTION_WARP_CUSTODIAN"),
            vm.envAddress("AUCTION_PROTOCOL_FEE_RECIPIENT"),
            uint16(share), vm.envBytes32("AUCTION_POLICY_HASH")
        );
        vm.startBroadcast();
        deployed = new LiquidityMiningAuction(pndc, feeToken, terms);
        vm.stopBroadcast();
        require(deployed.isPaused() && !deployed.hasLaunched(), "unsafe deployment");
    }
}
