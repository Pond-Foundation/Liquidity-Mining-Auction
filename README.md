# Liquidity Mining Auction

## Overview
The Liquidity Mining Auction implements a recurring Dutch auction system with integrated permissionless fee distribution. The module manages sequential 42-hour auctions where participants can propose tokens to be liquidity mined by making a bid using PNDC, resulting in winners having the ability to claim mining fees accumulated from mining activity. The token of winning bid is mined until next auction ends.

## Use Case
- Fee share from POW mining 
- Liquidity mining of any token (automatic market making)

## Core Mechanisms

### Auction Mechanics
- **Dutch Auction**: Implements a descending price auction where the price decreases linearly over time
- **Duration**: Each auction runs for exactly 42 hours
- **Recurring**: New auction starts automatically when the previous one concludes
- **Price Calculation**: `currentPrice = startingPrice - (discountRate * timeElapsed)`

### Token System
1. **Auction Token - PNDC**
   - Used for bidding
   - Transferred from winner to contract upon successful bid
   - Later, transferred to mining deposit address to be warpped and mined on Solana

2. **Fee Token**
   - Token used for fee distribution
   - Is deposited from Solana into auction-specific fee vaults
   - Claimable only by auction winners

## Data Structures

### BidderInfo
```solidity
struct BidderInfo {
    string name;        // Bidder's token identifier
    string network;     // Network information for token to mine
    address tokenAddress; // On-chain address of token to mine bytes32
    address bidderAddress;  // On-chain address of bidder
}
```

### Auction
```solidity
struct Auction {
    uint256 startAt;        // Auction start timestamp
    uint256 expiresAt;      // Auction end timestamp
    uint256 winningBid;     // Winning bid amount
    address winner;         // Winner's address
    BidderInfo winnerInfo;  // Winner's metadata
    bool fundsSentToMine;   // Mining transfer status
}
```

### FeeVault
```solidity
struct FeeVault {
    uint256 amount;     // Accumulated fees
    bool claimed;       // Claim status
}
```

## Key Functions

### Auction Operations
1. `bid(string name, string network, address tokenAddress, address bidderAddress)`
   - Accepts a bid at current price
   - Records winner information
   - Transfers auction tokens
   - Starts next auction

2. `getPrice()`
   - Calculates current auction price
   - Based on time elapsed and discount rate
   - Returns current valid price

### Fee Management
1. `depositFee(uint256 amount)`
   - Deposits fee tokens into last winning auction vault
   - Requires completed auction
   - Accumulates fees in vault

2. `claimFee(uint256 auctionId)`
   - Allows winner to claim accumulated fees in specific vault
   - One-time claim per auction
   - Transfers entire vault balance

### Mining Operations
1. `sendToMine(uint256 auctionId)`
   - Transfers winning bid to mining deposit
   - Permissionless execution
   - One-time operation per auction
