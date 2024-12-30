// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract LiquidityMiningAuction {
    uint256 private constant AUCTION_DURATION = 42 hours;
    
    struct BidderInfo {
        string name;
        string network;
        address tokenAddress;
        address bidderAddress;
    }
    
    struct Auction {
        uint256 startAt;
        uint256 expiresAt;
        uint256 winningBid;
        address winner;
        BidderInfo winnerInfo;
        bool fundsSentToMine;
    }

    struct FeeVault {
        uint256 amount;
        bool claimed;
    }
    
    IERC20 public immutable auctionToken;
    IERC20 public immutable feeToken;
    uint256 public immutable startingPrice;
    uint256 public immutable discountRate;
    
    address public owner;
    address public miningDeposit;
    
    uint256 public currentAuctionId;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => FeeVault) public feeVaults;
    
    bool public isPaused;
    
    event AuctionStarted(uint256 indexed auctionId, uint256 startAt, uint256 expiresAt);
    event AuctionWon(
        uint256 indexed auctionId, 
        address winner, 
        uint256 amount, 
        string name,
        string network,
        address tokenAddress,
        address bidderAddress
    );
    event FundsSentToMine(uint256 indexed auctionId, uint256 amount);
    event MiningDepositUpdated(address newDeposit);
    event EmergencyWithdraw(address token, uint256 amount);
    event FeeDeposited(uint256 indexed auctionId, uint256 amount);
    event FeeClaimed(uint256 indexed auctionId, address winner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ContractPaused(bool isPaused);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }
    
    modifier notPaused() {
        require(!isPaused, "contract is paused");
        _;
    }

    constructor(
        uint256 _startingPrice,
        uint256 _discountRate,
        address _auctionToken,
        address _feeToken,
        address _miningDeposit
    ) {
        require(_auctionToken != address(0), "auction token cannot be zero address");
        require(_feeToken != address(0), "fee token cannot be zero address");
        require(_miningDeposit != address(0), "mining deposit cannot be zero address");
        
        owner = msg.sender;
        startingPrice = _startingPrice;
        discountRate = _discountRate;
        miningDeposit = _miningDeposit;
        
        require(
            startingPrice >= discountRate * AUCTION_DURATION,
            "starting price < minimum"
        );

        auctionToken = IERC20(_auctionToken);
        feeToken = IERC20(_feeToken);
        
        // Start first auction
        _startNewAuction();
    }
    
    function _startNewAuction() internal {
        currentAuctionId++;
        uint256 startAt = block.timestamp;
        uint256 expiresAt = startAt + AUCTION_DURATION;
        
        auctions[currentAuctionId] = Auction({
            startAt: startAt,
            expiresAt: expiresAt,
            winningBid: 0,
            winner: address(0),
            winnerInfo: BidderInfo("", "", address(0), address(0)),
            fundsSentToMine: false
        });
        
        emit AuctionStarted(currentAuctionId, startAt, expiresAt);
    }

    function getPrice() public view returns (uint256) {
        Auction storage auction = auctions[currentAuctionId];
        require(block.timestamp < auction.expiresAt, "auction expired");
        
        uint256 timeElapsed = block.timestamp - auction.startAt;
        uint256 discount = discountRate * timeElapsed;
        return startingPrice - discount;
    }

    function bid(string memory name, string memory network, address tokenAddress, address bidderAddress) external notPaused {
        require(bytes(name).length > 0, "name cannot be empty");
        require(bytes(network).length > 0, "network cannot be empty");
        require(tokenAddress != address(0), "invalid token address");
        require(bidderAddress != address(0), "invalid bidder address");
        
        Auction storage auction = auctions[currentAuctionId];
        require(block.timestamp < auction.expiresAt, "auction expired");
        require(auction.winner == address(0), "auction already won");
        
        uint256 price = getPrice();
        
        // Update state before external call
        auction.winner = msg.sender;
        auction.winningBid = price;
        auction.winnerInfo = BidderInfo(name, network, tokenAddress, bidderAddress);
        
        // External call after state updates
        require(
            auctionToken.transferFrom(msg.sender, address(this), price),
            "auction token transfer failed"
        );
        
        emit AuctionWon(
            currentAuctionId, 
            msg.sender, 
            price, 
            name, 
            network, 
            tokenAddress,
            bidderAddress
        );
        
        // Start next auction
        _startNewAuction();
    }

    function depositFee(uint256 amount) external {
        require(amount > 0, "amount must be greater than 0");
        require(currentAuctionId > 1, "no completed auctions");
        
        uint256 lastAuctionId = currentAuctionId - 1;
        require(auctions[lastAuctionId].winner != address(0), "auction not completed");
        require(!feeVaults[lastAuctionId].claimed, "fees already claimed for this auction");
        
        // Update state before external call
        feeVaults[lastAuctionId].amount += amount;
        
        // External call after state updates
        require(
            feeToken.transferFrom(msg.sender, address(this), amount),
            "fee token transfer failed"
        );
        
        emit FeeDeposited(lastAuctionId, amount);
    }

    function claimFee(uint256 auctionId) external {
        Auction storage auction = auctions[auctionId];
        FeeVault storage vault = feeVaults[auctionId];
        
        require(auction.winner == msg.sender, "only winner can claim fees");
        require(auction.winner != address(0), "auction not completed");
        require(!vault.claimed, "fees already claimed");
        require(vault.amount > 0, "no fees to claim");

        uint256 claimAmount = vault.amount;
        
        // Update state before external call
        vault.claimed = true;
        
        // External call after state updates
        require(
            feeToken.transfer(msg.sender, claimAmount),
            "fee transfer failed"
        );

        emit FeeClaimed(auctionId, msg.sender, claimAmount);
    }
    
    function sendToMine(uint256 auctionId) external {
        Auction storage auction = auctions[auctionId];
        require(auction.winner != address(0), "no winner yet");
        require(!auction.fundsSentToMine, "funds already sent to mine");
        require(miningDeposit != address(0), "mining deposit not set");
        
        uint256 amount = auction.winningBid;
        
        // Update state before external call
        auction.fundsSentToMine = true;
        
        // External call after state updates
        require(
            auctionToken.transfer(miningDeposit, amount),
            "transfer to mining deposit failed"
        );
        
        emit FundsSentToMine(auctionId, amount);
    }
    
    function setMiningDeposit(address _miningDeposit) external onlyOwner {
        require(_miningDeposit != address(0), "invalid address");
        miningDeposit = _miningDeposit;
        emit MiningDepositUpdated(_miningDeposit);
    }
    
    function emergencyWithdraw(IERC20 token) external onlyOwner {
        require(address(token) != address(0), "invalid token address");
        
        isPaused = true;
        emit ContractPaused(true);
        
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "no balance to withdraw");
        
        require(
            token.transfer(owner, balance),
            "emergency withdraw failed"
        );
        
        emit EmergencyWithdraw(address(token), balance);
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "invalid address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    
    function togglePause() external onlyOwner {
        isPaused = !isPaused;
        emit ContractPaused(isPaused);
    }

    // View functions
    function getWinnerInfo(uint256 auctionId) external view returns (BidderInfo memory) {
        return auctions[auctionId].winnerInfo;
    }

    function getFeeVaultInfo(uint256 auctionId) external view returns (FeeVault memory) {
        return feeVaults[auctionId];
    }
}