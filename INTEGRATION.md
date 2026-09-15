# English auction V2 deployment

This source is a new deployment. Never point its ABI at the original Dutch auction `0x38B10ADde802701aE96384E2de74011F2642d288`.

The contract starts paused. The owner's first `setPaused(false)` starts a full seven-day first round. Later pause/resume calls preserve deadlines. Anyone may settle a launched expired round, withdraw their losing bid after settlement, or sponsor a winner's fixed-recipient fee claim. Only the winning PNDC bid is released to the round's immutable warp custodian. Releasing PNDC does not itself wrap or bridge it.

Before deploying, save disabled custody and fee settings in Pond `/ez/deepliquidity`. Copy the resulting policy hash and exact recipients into the deployment environment. `AUCTION_FEE_TOKEN` must match the admin configuration. `AUCTION_WINNER_SHARE_BPS` splits gross eligible funding; the remaining share belongs to the pinned protocol recipient. No owner recovery function can withdraw escrow or either fee liability.

Use `script/DeployEnglishV2.s.sol` with a hardware wallet or Foundry keystore. Run its simulation first. Supplying `--broadcast` is the separate live deployment step. Do not place raw keys in command arguments or tracked files. Record the creation receipt and block. Register the address and creation block in Pond; AVS compares the compiled runtime, immutable token identities and version. Complete source/backing review and custody cutover before launching. Source verification on the explorer and an independent contract audit remain release requirements.

Build and test with `forge test`. The reviewed toolchain is Solidity 0.8.26, optimizer enabled, 200 runs. ABI and runtime verification artifacts must be regenerated for Pond and AVS whenever contract source changes. The artifact can be read from `out/LiquidityMiningAuction.sol/LiquidityMiningAuction.json`; copy `abi` into each application's `api/auction/abi.json` or `src/lib/auction/abi.json`, and `bytecode` plus `deployedBytecode` into AVS `api/auction/artifact.json`.

Ownership transfer requires acceptance after two days. Prefer the protocol's controlled ownership account. Before launch, verify its ability to pause, schedule future terms and accept ownership. Already-open rounds retain their original fee share, custodian and policy hash when future settings change.
