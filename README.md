# Liquidity Mining Auction

A recurring **7-day English auction**: participants deposit PNDC to enter; the
highest standing deposit at settlement wins. The winning PNDC is released into
the cross-chain pipeline — **WARP → deBridge → Solana single-side wPOND pool** —
driven by keepers in `solana-vrf-avs`. The `/mining` liquid-cooling panel is the
live indicator and the deposit / exit UI.

## Auction rules
- **Minimum to participate:** 1 trillion PNDC (`MIN_BID = 1e12 × 10¹⁸`).
- **Winner:** highest total deposit (English, not Dutch).
- **Duration:** 7 days per auction, recurring — `finalize()` settles the current
  one and opens the next.
- **Deposit / exit:** top up (`deposit`) or withdraw (`exit`) any time the
  auction is open. After settlement, losers reclaim via `exit`/`exitAuction`;
  the winner's stake is locked and released with `sendToWarp`.

## Contract — `contracts/LiquidityMiningAuction.sol`
| Function | Who | Notes |
|---|---|---|
| `deposit(amount)` | anyone | escrows PNDC into the current auction (total must reach 1T) |
| `exit()` / `exitAuction(id)` | participant | withdraw full position (winner locked after finalize) |
| `finalize()` | anyone | after expiry: highest deposit wins, next auction opens |
| `sendToWarp(id)` | anyone | releases the winning PNDC to the WARP sink |
| `getParticipants(id)` / `getAuction(id)` / `getPosition(id,addr)` / `timeRemaining()` | view | UI reads |
| `setWarpDeposit` / `togglePause` / `transferOwnership` / `emergencyWithdraw` | owner | admin |

Security: checks-effects-interactions on every transfer, a `nonReentrant` guard,
pull-style loser refunds, and a permissionless `sendToWarp` that can only pay the
configured sink.

## Pipeline (off-chain, keepers in `solana-vrf-avs`)
1. `finalize()` settles the auction (permissionless).
2. `sendToWarp` releases winning PNDC → WARP wrapper `0x4e81…225f8` → **wPOND**.
3. wPOND → deBridge DLN `0xeF4f…EB66` → Solana receiver `AYg4…53opT`.
4. Forward `AYg4…53opT` → functionwallet `1orF…iWWL` → single-side wPOND pool.

Verified on-chain: PNDC `0x423f4e6138E475D85CF7Ea071AC92097Ed631eea` (18 dec) ·
wPOND "POND COIN - WARPED" `0x4e810ad33733bef360b12eb59c98c1d5d3a225f8` (18 dec).

## Testing — Foundry
```bash
forge install foundry-rs/forge-std   # first time
forge test                            # unit + fuzz + invariants
forge test -vvv                       # verbose
```
- `test/LiquidityMiningAuction.t.sol` — unit + fuzz (min-bid boundary, exact
  refunds), access control, and a reentrant-token attack against the guard.
- `test/AuctionInvariant.t.sol` — invariants under fuzzed deposit/exit/finalize/warp:
  **solvency** (contract balance == escrowed) and the **1T floor** for active bidders.

> `LiquidVault-alpha.sol` and `tests/`, `simulators/` are earlier drafts, kept for
> reference and not part of the Foundry build.
