// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Round-bound English auction. Winning PNDC goes to a pinned executor;
/// that transfer is not evidence of wrapper minting or cross-chain delivery.
contract LiquidityMiningAuction {
    uint256 public constant VERSION = 2;
    uint256 public constant AUCTION_DURATION = 7 days;
    uint256 public constant MIN_BID = 1_000_000_000_000 ether;
    uint256 public constant ONE_BILLION = 1_000_000_000 ether;
    uint256 public constant MAX_PARTICIPANTS = 256;
    uint256 public constant OWNERSHIP_DELAY = 2 days;
    struct Terms {
        address warpDeposit;
        address protocolFeeRecipient;
        uint16 winnerShareBps;
        bytes32 policyHash;
    }
    struct Auction {
        uint256 startAt;
        uint256 expiresAt;
        bool finalized;
        address winner;
        uint256 winningBid;
        bool sentToWarp;
    }
    struct Position { uint256 amount; uint256 index; bool active; uint256 sequence; }
    struct FeeVault { uint256 funded; uint256 claimed; }
    IERC20 public immutable auctionToken;
    IERC20 public immutable feeToken;
    address public owner;
    address public pendingOwner;
    uint256 public ownershipReadyAt;
    Terms public nextTerms;
    mapping(uint256 => Terms) public auctionTerms;
    uint256 public currentAuctionId;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => Position)) public positions;
    mapping(uint256 => address[]) private participants;
    mapping(uint256 => FeeVault) public feeVaults;
    mapping(address => uint256) public protocolFees;
    uint256 public totalEscrowed;
    uint256 public totalFeeLiability;
    uint256 private sequence;
    uint256 private entered;
    bool public isPaused;
    bool public hasLaunched;

    event AuctionStarted(uint256 indexed auctionId, uint256 startAt, uint256 expiresAt);
    event TermsScheduled(address warpDeposit, address protocolFeeRecipient, uint16 winnerShareBps, bytes32 policyHash);
    event TermsActivated(uint256 indexed auctionId, address warpDeposit, address protocolFeeRecipient, uint16 winnerShareBps, bytes32 policyHash);
    event Deposited(uint256 indexed auctionId, address indexed participant, uint256 amount, uint256 total);
    event Exited(uint256 indexed auctionId, address indexed participant, uint256 amount);
    event AuctionFinalized(uint256 indexed auctionId, address indexed winner, uint256 winningBid);
    event SentToWarp(uint256 indexed auctionId, uint256 amount, address warpDeposit);
    event FeeDeposited(uint256 indexed auctionId, uint256 grossAmount, uint256 winnerAmount, uint256 protocolAmount);
    event FeeClaimed(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed nextOwner, uint256 readyAt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ContractPaused(bool isPaused);
    event SurplusRecovered(address indexed token, address indexed recipient, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier nonReentrant() { require(entered == 0, "reentrant"); entered = 1; _; entered = 0; }
    modifier notPaused() { require(!isPaused, "paused"); _; }

    constructor(address pndc, address rewardToken, Terms memory terms) {
        require(pndc.code.length > 0 && rewardToken.code.length > 0, "invalid token");
        _validateTerms(terms);
        auctionToken = IERC20(pndc);
        feeToken = IERC20(rewardToken);
        owner = msg.sender;
        nextTerms = terms;
        isPaused = true;
        _startNewAuction();
    }
    function _validateTerms(Terms memory terms) internal view {
        require(terms.warpDeposit != address(0) && terms.warpDeposit != address(this), "invalid warp deposit");
        require(terms.protocolFeeRecipient != address(0) && terms.protocolFeeRecipient != address(this), "invalid fee recipient");
        require(terms.winnerShareBps <= 10_000 && terms.policyHash != bytes32(0), "invalid policy");
    }
    function _startNewAuction() internal {
        uint256 id = ++currentAuctionId;
        auctions[id] = Auction(block.timestamp, block.timestamp + AUCTION_DURATION, false, address(0), 0, false);
        auctionTerms[id] = nextTerms;
        emit AuctionStarted(id, block.timestamp, block.timestamp + AUCTION_DURATION);
        emit TermsActivated(id, nextTerms.warpDeposit, nextTerms.protocolFeeRecipient, nextTerms.winnerShareBps, nextTerms.policyHash);
    }
    /// @notice Never accept a delayed transaction into a different round.
    function deposit(uint256 auctionId, uint256 amount, uint256 deadline) external notPaused nonReentrant {
        require(auctionId == currentAuctionId, "wrong auction");
        require(block.timestamp <= deadline && block.timestamp < auctions[auctionId].expiresAt, "auction ended");
        amount -= amount % ONE_BILLION;
        require(amount > 0, "amount zero");
        Position storage p = positions[auctionId][msg.sender];
        require(p.amount + amount >= MIN_BID, "below 1T minimum");
        if (!p.active) {
            require(participants[auctionId].length < MAX_PARTICIPANTS, "participant limit");
            p.index = participants[auctionId].length;
            p.active = true;
            participants[auctionId].push(msg.sender);
        }
        p.amount += amount;
        p.sequence = ++sequence;
        totalEscrowed += amount;
        _receiveExact(auctionToken, amount);
        emit Deposited(auctionId, msg.sender, amount, p.amount);
    }
    function exit() external nonReentrant { _exit(currentAuctionId); }
    function exitAuction(uint256 id) external nonReentrant { _exit(id); }
    function _exit(uint256 id) internal {
        Position storage p = positions[id][msg.sender];
        require(p.active && p.amount > 0, "no position");
        Auction storage a = auctions[id];
        if (a.finalized) require(msg.sender != a.winner, "winner locked");
        else require(block.timestamp < a.expiresAt, "await settlement");
        uint256 amount = p.amount;
        p.amount = 0;
        p.active = false;
        totalEscrowed -= amount;
        address[] storage arr = participants[id];
        uint256 last = arr.length - 1;
        if (p.index != last) {
            address moved = arr[last];
            arr[p.index] = moved;
            positions[id][moved].index = p.index;
        }
        arr.pop();
        require(auctionToken.transfer(msg.sender, amount), "refund failed");
        emit Exited(id, msg.sender, amount);
    }
    /// @notice At most MAX_PARTICIPANTS entries. Safe settlement remains available while paused.
    function finalize(uint256 expectedAuctionId) external nonReentrant {
        require(hasLaunched, "not launched");
        require(expectedAuctionId == currentAuctionId, "wrong auction");
        Auction storage a = auctions[expectedAuctionId];
        require(block.timestamp >= a.expiresAt, "not ended");
        require(!a.finalized, "already finalized");
        address[] storage arr = participants[expectedAuctionId];
        uint256 first = type(uint256).max;
        for (uint256 i; i < arr.length; ++i) {
            Position storage p = positions[expectedAuctionId][arr[i]];
            if (p.amount > a.winningBid || (p.amount == a.winningBid && p.sequence < first)) {
                a.winner = arr[i]; a.winningBid = p.amount; first = p.sequence;
            }
        }
        a.finalized = true;
        emit AuctionFinalized(expectedAuctionId, a.winner, a.winningBid);
        _startNewAuction();
    }
    function sendToWarp(uint256 id) external notPaused nonReentrant {
        Auction storage a = auctions[id];
        require(a.finalized, "not finalized");
        require(a.winner != address(0), "no winner");
        require(!a.sentToWarp, "already sent");
        uint256 amount = positions[id][a.winner].amount;
        require(amount > 0, "nothing to send");
        positions[id][a.winner].amount = 0;
        totalEscrowed -= amount;
        a.sentToWarp = true;
        address recipient = auctionTerms[id].warpDeposit;
        uint256 beforeBalance = auctionToken.balanceOf(recipient);
        require(auctionToken.transfer(recipient, amount), "warp transfer failed");
        require(auctionToken.balanceOf(recipient) == beforeBalance + amount, "inexact warp transfer");
        emit SentToWarp(id, amount, recipient);
    }
    /// @notice Fund gross eligible fees; split is enforced by immutable round terms.
    function depositFee(uint256 id, uint256 amount) external nonReentrant {
        require(amount > 0, "amount zero");
        require(auctions[id].finalized, "not finalized");
        require(auctions[id].winner != address(0), "no winner");
        Terms storage terms = auctionTerms[id];
        uint256 winnerAmount = (amount / 10_000) * terms.winnerShareBps
            + ((amount % 10_000) * terms.winnerShareBps) / 10_000;
        uint256 protocolAmount = amount - winnerAmount;
        feeVaults[id].funded += winnerAmount;
        protocolFees[terms.protocolFeeRecipient] += protocolAmount;
        totalFeeLiability += amount;
        _receiveExact(feeToken, amount);
        emit FeeDeposited(id, amount, winnerAmount, protocolAmount);
    }
    function claimFee(uint256 id) external nonReentrant {
        require(msg.sender == auctions[id].winner, "only winner");
        _claim(id);
    }
    /// @notice Gas may be sponsored; the reward can only reach the recorded winner.
    function claimFor(uint256 id) external nonReentrant { _claim(id); }
    function _claim(uint256 id) internal {
        FeeVault storage vault = feeVaults[id];
        uint256 amount = vault.funded - vault.claimed;
        require(amount > 0, "nothing to claim");
        vault.claimed += amount;
        totalFeeLiability -= amount;
        address winner = auctions[id].winner;
        require(feeToken.transfer(winner, amount), "claim failed");
        emit FeeClaimed(id, winner, amount);
    }
    function claimProtocolFees() external nonReentrant {
        uint256 amount = protocolFees[msg.sender];
        require(amount > 0, "nothing to claim");
        protocolFees[msg.sender] = 0;
        totalFeeLiability -= amount;
        require(feeToken.transfer(msg.sender, amount), "claim failed");
        emit ProtocolFeesClaimed(msg.sender, amount);
    }
    function _receiveExact(IERC20 token, uint256 amount) internal {
        uint256 beforeBalance = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        require(token.balanceOf(address(this)) == beforeBalance + amount, "inexact transfer");
    }
    function getFeeVault(uint256 id) external view returns (FeeVault memory) { return feeVaults[id]; }
    function getAuction(uint256 id) external view returns (Auction memory) { return auctions[id]; }
    function getPosition(uint256 id, address who) external view returns (uint256) { return positions[id][who].amount; }
    function participantCount(uint256 id) external view returns (uint256) { return participants[id].length; }
    function getParticipants(uint256 id) external view returns (address[] memory addrs, uint256[] memory amounts) {
        addrs = participants[id];
        amounts = new uint256[](addrs.length);
        for (uint256 i; i < addrs.length; ++i) amounts[i] = positions[id][addrs[i]].amount;
    }
    function timeRemaining() external view returns (uint256) {
        uint256 end = auctions[currentAuctionId].expiresAt;
        return block.timestamp < end ? end - block.timestamp : 0;
    }
    function scheduleTerms(Terms calldata terms) external onlyOwner {
        _validateTerms(terms);
        nextTerms = terms;
        emit TermsScheduled(terms.warpDeposit, terms.protocolFeeRecipient, terms.winnerShareBps, terms.policyHash);
    }
    function setPaused(bool paused) external onlyOwner {
        if (!paused && !hasLaunched) {
            hasLaunched = true;
            Auction storage first = auctions[1];
            first.startAt = block.timestamp;
            first.expiresAt = block.timestamp + AUCTION_DURATION;
            emit AuctionStarted(1, first.startAt, first.expiresAt);
        }
        isPaused = paused;
        emit ContractPaused(paused);
    }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        pendingOwner = newOwner;
        ownershipReadyAt = block.timestamp + OWNERSHIP_DELAY;
        emit OwnershipTransferStarted(owner, newOwner, ownershipReadyAt);
    }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner && block.timestamp >= ownershipReadyAt, "ownership not ready");
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        ownershipReadyAt = 0;
        emit OwnershipTransferred(previous, owner);
    }
    /// @notice Recovery can never consume refundable bids or funded fee liabilities.
    function recoverSurplus(IERC20 token, address recipient, uint256 amount) external onlyOwner nonReentrant {
        require(recipient != address(0) && amount > 0, "invalid recovery");
        uint256 reserved;
        if (address(token) == address(auctionToken)) reserved += totalEscrowed;
        if (address(token) == address(feeToken)) reserved += totalFeeLiability;
        uint256 balance = token.balanceOf(address(this));
        require(balance >= reserved && amount <= balance - reserved, "reserved funds");
        require(token.transfer(recipient, amount), "recovery failed");
        emit SurplusRecovered(address(token), recipient, amount);
    }
}
