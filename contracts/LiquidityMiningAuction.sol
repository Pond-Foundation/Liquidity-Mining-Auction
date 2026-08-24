// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title LiquidityMiningAuction — recurring 7-day English auction
/// @notice Participants deposit PNDC to enter the current auction; the highest
///         standing deposit at settlement wins. Deposits can be topped up
///         (`deposit`) or withdrawn (`exit`) while the auction is open. When it
///         closes, `finalize()` records the winner and opens the next auction;
///         losers reclaim their PNDC with `exit`, and the winning PNDC is
///         released to the WARP pipeline (`sendToWarp`) which wraps → deBridge →
///         Solana single-side wPOND pool (driven by keepers on solana-vrf-avs).
/// @dev    The UI reads `getAuction` + `getParticipants` and calls
///         `deposit` / `exit`. No per-bid token proposal: the output is always
///         the wPOND single-side pool.
contract LiquidityMiningAuction {
    uint256 public constant AUCTION_DURATION = 7 days;
    // 1 trillion PNDC minimum to participate. PNDC has 18 decimals, so
    // 1e12 tokens * 1e18 = 1e30 raw. (`ether` == 1e18.)
    uint256 public constant MIN_BID = 1_000_000_000_000 ether;
    // Deposits round down to whole billions of PNDC — no odd fractional amounts.
    // 1e9 tokens * 1e18 = 1e27 raw.
    uint256 public constant ONE_BILLION = 1_000_000_000 ether;

    struct Auction {
        uint256 startAt;
        uint256 expiresAt;
        bool finalized;
        address winner;
        uint256 winningBid;
        bool sentToWarp;
    }

    struct Position {
        uint256 amount;   // total PNDC escrowed by this participant
        uint256 index;    // index into participants[auctionId]
        bool active;
    }

    // Fee reward share from POW mining: fees accrued while the winner's token is
    // mined are deposited into that auction's vault and claimed by the winner.
    struct FeeVault {
        uint256 amount;
        bool claimed;
    }

    IERC20 public immutable auctionToken; // PNDC (bids)
    IERC20 public immutable feeToken;     // POW-mining fee reward token
    address public owner;
    address public warpDeposit;           // keeper-controlled sink that wraps + bridges the winning PNDC

    uint256 public currentAuctionId;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => Position)) public positions;
    mapping(uint256 => address[]) private participants;
    mapping(uint256 => FeeVault) public feeVaults;

    bool public isPaused;
    uint256 private _entered;

    event AuctionStarted(uint256 indexed auctionId, uint256 startAt, uint256 expiresAt);
    event Deposited(uint256 indexed auctionId, address indexed participant, uint256 amount, uint256 total);
    event Exited(uint256 indexed auctionId, address indexed participant, uint256 amount);
    event AuctionFinalized(uint256 indexed auctionId, address indexed winner, uint256 winningBid);
    event SentToWarp(uint256 indexed auctionId, uint256 amount, address warpDeposit);
    event FeeDeposited(uint256 indexed auctionId, uint256 amount);
    event FeeClaimed(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event WarpDepositUpdated(address newDeposit);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ContractPaused(bool isPaused);
    event EmergencyWithdraw(address token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }
    modifier notPaused() {
        require(!isPaused, "paused");
        _;
    }
    modifier nonReentrant() {
        require(_entered == 0, "reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address _auctionToken, address _feeToken, address _warpDeposit) {
        require(_auctionToken != address(0), "auction token zero");
        require(_feeToken != address(0), "fee token zero");
        require(_warpDeposit != address(0), "warp deposit zero");
        owner = msg.sender;
        auctionToken = IERC20(_auctionToken);
        feeToken = IERC20(_feeToken);
        warpDeposit = _warpDeposit;
        _startNewAuction();
    }

    function _startNewAuction() internal {
        currentAuctionId++;
        uint256 startAt = block.timestamp;
        uint256 expiresAt = startAt + AUCTION_DURATION;
        auctions[currentAuctionId] = Auction({
            startAt: startAt,
            expiresAt: expiresAt,
            finalized: false,
            winner: address(0),
            winningBid: 0,
            sentToWarp: false
        });
        emit AuctionStarted(currentAuctionId, startAt, expiresAt);
    }

    /// @notice Deposit PNDC into the current auction (tops up an existing position).
    ///         Total position must reach the 1T minimum to be active.
    function deposit(uint256 amount) external notPaused nonReentrant {
        // round down to whole billions — no odd fractional deposits
        amount = amount - (amount % ONE_BILLION);
        require(amount > 0, "amount zero");
        uint256 id = currentAuctionId;
        Auction storage a = auctions[id];
        require(block.timestamp < a.expiresAt, "auction ended");

        Position storage p = positions[id][msg.sender];
        uint256 newTotal = p.amount + amount;
        require(newTotal >= MIN_BID, "below 1T minimum");

        // effects
        p.amount = newTotal;
        if (!p.active) {
            p.active = true;
            p.index = participants[id].length;
            participants[id].push(msg.sender);
        }

        // interaction
        require(auctionToken.transferFrom(msg.sender, address(this), amount), "transfer failed");

        emit Deposited(id, msg.sender, amount, newTotal);
    }

    /// @notice Withdraw your entire position from the current auction.
    function exit() external nonReentrant {
        _exit(currentAuctionId);
    }

    /// @notice Withdraw your position from a specific auction (e.g. after it
    ///         finalized and you did not win).
    function exitAuction(uint256 auctionId) external nonReentrant {
        _exit(auctionId);
    }

    function _exit(uint256 auctionId) internal {
        Position storage p = positions[auctionId][msg.sender];
        require(p.active && p.amount > 0, "no position");

        Auction storage a = auctions[auctionId];
        // once finalized, the winner's stake is locked for the WARP pipeline
        if (a.finalized) {
            require(msg.sender != a.winner, "winner locked");
        }

        uint256 amount = p.amount;

        // effects
        p.amount = 0;
        p.active = false;
        _removeParticipant(auctionId, msg.sender, p.index);

        // interaction
        require(auctionToken.transfer(msg.sender, amount), "refund failed");

        emit Exited(auctionId, msg.sender, amount);
    }

    function _removeParticipant(uint256 auctionId, address who, uint256 idx) internal {
        address[] storage arr = participants[auctionId];
        uint256 last = arr.length - 1;
        if (idx != last) {
            address moved = arr[last];
            arr[idx] = moved;
            positions[auctionId][moved].index = idx;
        }
        arr.pop();
        // silence unused-var warnings in some compilers
        who;
    }

    /// @notice Settle the current auction after it expires: the highest standing
    ///         deposit wins, and the next auction opens. Permissionless.
    function finalize() external nonReentrant {
        uint256 id = currentAuctionId;
        Auction storage a = auctions[id];
        require(block.timestamp >= a.expiresAt, "not ended");
        require(!a.finalized, "already finalized");

        a.finalized = true;

        address[] storage arr = participants[id];
        address win;
        uint256 best;
        for (uint256 i = 0; i < arr.length; i++) {
            uint256 amt = positions[id][arr[i]].amount;
            if (amt > best) {
                best = amt;
                win = arr[i];
            }
        }
        a.winner = win;
        a.winningBid = best;

        emit AuctionFinalized(id, win, best);
        _startNewAuction();
    }

    /// @notice Release the winning PNDC to the WARP pipeline. Permissionless
    ///         (funds can only go to the configured `warpDeposit`).
    function sendToWarp(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.finalized, "not finalized");
        require(a.winner != address(0), "no winner");
        require(!a.sentToWarp, "already sent");
        require(warpDeposit != address(0), "no warp deposit");

        uint256 amount = positions[auctionId][a.winner].amount;
        require(amount > 0, "nothing to send");

        // effects
        positions[auctionId][a.winner].amount = 0;
        a.sentToWarp = true;

        // interaction
        require(auctionToken.transfer(warpDeposit, amount), "warp transfer failed");

        emit SentToWarp(auctionId, amount, warpDeposit);
    }

    // ------------------------------------------------ fee reward share (POW)

    /// @notice Deposit POW-mining fee rewards into a finalized auction's vault.
    ///         Claimable by that auction's winner. Permissionless (keepers push
    ///         fees here as they accrue from mining the winner's token).
    function depositFee(uint256 auctionId, uint256 amount) external nonReentrant {
        require(amount > 0, "amount zero");
        Auction storage a = auctions[auctionId];
        require(a.finalized, "not finalized");
        require(a.winner != address(0), "no winner");
        require(!feeVaults[auctionId].claimed, "already claimed");

        feeVaults[auctionId].amount += amount;
        require(feeToken.transferFrom(msg.sender, address(this), amount), "fee transfer failed");
        emit FeeDeposited(auctionId, amount);
    }

    /// @notice Winner claims the accrued fee reward share for an auction.
    function claimFee(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        FeeVault storage v = feeVaults[auctionId];
        require(msg.sender == a.winner, "only winner");
        require(!v.claimed, "already claimed");
        require(v.amount > 0, "nothing to claim");

        uint256 amount = v.amount;
        v.claimed = true;
        require(feeToken.transfer(msg.sender, amount), "claim failed");
        emit FeeClaimed(auctionId, msg.sender, amount);
    }

    function getFeeVault(uint256 auctionId) external view returns (FeeVault memory) {
        return feeVaults[auctionId];
    }

    // ------------------------------------------------------------------ views

    function timeRemaining() external view returns (uint256) {
        Auction storage a = auctions[currentAuctionId];
        if (block.timestamp >= a.expiresAt) return 0;
        return a.expiresAt - block.timestamp;
    }

    function participantCount(uint256 auctionId) external view returns (uint256) {
        return participants[auctionId].length;
    }

    /// @notice All active participants of an auction with their deposit amounts.
    ///         The UI sorts these to render the leaderboard (top depositors).
    function getParticipants(uint256 auctionId)
        external
        view
        returns (address[] memory addrs, uint256[] memory amounts)
    {
        address[] storage arr = participants[auctionId];
        addrs = new address[](arr.length);
        amounts = new uint256[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            addrs[i] = arr[i];
            amounts[i] = positions[auctionId][arr[i]].amount;
        }
    }

    function getPosition(uint256 auctionId, address who) external view returns (uint256) {
        return positions[auctionId][who].amount;
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    // -------------------------------------------------------------- ownership

    function setWarpDeposit(address _warpDeposit) external onlyOwner {
        require(_warpDeposit != address(0), "zero");
        warpDeposit = _warpDeposit;
        emit WarpDepositUpdated(_warpDeposit);
    }

    function togglePause() external onlyOwner {
        isPaused = !isPaused;
        emit ContractPaused(isPaused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /// @notice Owner escape hatch: pauses and sweeps a token to the owner.
    ///         Only intended for emergencies; open auctions should be settled
    ///         normally so participants can `exit`.
    function emergencyWithdraw(IERC20 token) external onlyOwner {
        require(address(token) != address(0), "zero");
        isPaused = true;
        emit ContractPaused(true);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "no balance");
        require(token.transfer(owner, balance), "withdraw failed");
        emit EmergencyWithdraw(address(token), balance);
    }
}
