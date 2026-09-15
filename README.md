# Warped: English V2 liquidity auction

A recurring seven-day English auction escrows PNDC. The highest standing bid at expiry wins a round-pinned fee entitlement. The winning PNDC is released to the disclosed warp custodian for protocol liquidity. Losing bidders recover their PNDC. This is a new deployment; the legacy Dutch address is not compatible with this ABI.

The contract deploys paused. The owner's first launch starts a full seven-day window. First bids require one trillion PNDC; top-ups are whole billions. Ties favor the bidder who first reached that total. Exits are blocked after expiry until settlement, and a finalized winner cannot refund the winning stake.

| Function | Access and effect |
| --- | --- |
| `deposit(id, amount, deadline)` | Bidder; binds the intended round and expiry |
| `exit()` / `exitAuction(id)` | Bidder refund before expiry or after losing settlement |
| `finalize(expectedId)` | Permissionless settlement of a launched expired round |
| `sendToWarp(id)` | Permissionless exact PNDC transfer to that round's pinned custodian |
| `depositFee(id, grossAmount)` | Splits deposited payout tokens between winner and protocol liabilities |
| `claimFee(id)` / `claimFor(id)` | Winner claim or sponsored claim, always to the recorded winner |
| `claimProtocolFees()` | Claims only the caller's reserved protocol share |
| `scheduleTerms(terms)` | Owner; applies custody, share and disclosure hash to future rounds |
| `setPaused(bool)` | Owner; pauses new bidding and release, preserving refunds and claims |
| `recoverSurplus(token, recipient, amount)` | Owner; excludes escrow and both fee liabilities |
| `transferOwnership` / `acceptOwnership` | Two-step owner transfer with a two-day acceptance delay |

Fee funding is cumulative, so winners can claim again when new funding arrives. The AVS integration currently supports gross, verified protocol funding received during the auction window. Automatic POW/user-mining, swap and LP fee attribution is not implemented; the contract does not manufacture that income. Fee terms and recipients cannot be changed retroactively.

## Warping and liquidity

1. Settle the round and release winning PNDC to its pinned Ethereum custodian.
2. A reviewed authorized solver wraps PNDC using `0x4E810aD33733BEF360B12eB59C98c1D5D3A225F8`.
3. AVS creates a deBridge order for Solana wPOND with the fixed Gigaswap receiver `1orFCnFfgwPzSgUaoK6Wr3MjgXZ7mtk8NGz9Hh4iWWL`.
4. Only a finalized positive destination token credit becomes a spendable LP lot. A source bridge receipt alone is insufficient.
5. The lot may enter a dedicated protocol PoolVault position. The winner receives fee rights, not the wPOND or position ownership.

PNDC `0x423f4e6138E475D85CF7Ea071AC92097Ed631eea` has 18 decimals; the Ethereum wPOND wrapper has **3 decimals**. Raw PNDC amounts divide exactly by `10^15` when wrapped. Solana wPOND is `3JgFwoYV74f6LwWjQWnr3YDPFnmBdwQfNyubv99jqUoq`. Wrapper source, backing, solver permissions and executable cross-chain routes require review before activation. `sendToWarp` itself only transfers PNDC; it does not wrap or bridge.

## Deployment and validation

See [INTEGRATION.md](INTEGRATION.md) for paused deployment and custody cutover, and Pond's `docs/auction-warp-integration.md` for the full admin/API/worker runbook. The UI is `/mining/bid`; admin controls are under `/ez/deepliquidity`.

Run `forge test` for unit, fuzz and invariant tests and `forge build` to compile the deployment script. The suite covers escrow/fee solvency, tie ordering, expiry locks, repeated claims, exact token movement, reentrancy, delayed ownership, immutable round rights and launch timing. Current validation: 50 passing tests. Independent review and explorer source verification remain deployment requirements.

Earlier drafts under `LiquidVault-alpha.sol`, `tests/` and `simulators/` are reference material outside the configured Foundry build.
